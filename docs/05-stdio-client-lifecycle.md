# MCP Router - Stdio Client 生命周期管理重构

## 一、背景

### 1.1 问题描述

当前 stdio 类型 MCP Server 的客户端生命周期管理存在以下问题：

| 问题 | 严重程度 | 位置 |
|------|---------|------|
| `call_tool` 不会自动启动 stdio 进程 | **P0 Bug** | `router/mod.rs:386-403` |
| `list_server_tools` 和 `call_tool` 并发调用可能重复 spawn 进程 | P1 | `router/mod.rs:331-354` |
| `remove_server` 的 key 不匹配，无法删除 stdio client | P1 Bug | `router/mod.rs:100` |
| `remove_server` 不调用 `stop()`，子进程泄漏 | P1 | `router/mod.rs:96-102` |
| server 变更后 `flattened_tool_maps` 缓存不清理 | P2 | `router/mod.rs` |
| 进程崩溃后 `peer` 仍存在，无法自动重连 | P2 | `client/stdio.rs:305-307` |

### 1.2 根因分析

**核心问题**：`list_server_tools` 和 `call_tool` 对 stdio client 的获取逻辑不一致。

```
list_server_tools (Stdio 分支):
  get(&key) → None → new() → start() → insert() → list_tools()
                                                    ✅ 自动启动

call_tool (Stdio 分支):
  get(&key) → None → Err("Stdio client not found")
                      ❌ 直接报错
```

**并发问题**：`start().await` 耗时数秒（spawn + MCP handshake），期间无锁保护。

```
线程A: get(&key) → None → new() → start().await [数秒] → insert()
线程B: get(&key) → None → new() → start().await [数秒] → insert()
                    ↑ 窗口期内 B 也看到 None，重复 spawn
```

## 二、方案设计

### 2.1 整体思路

两层防护保证单实例启动：

1. **DashMap `entry` API**（同步原子）— 保证同一个 key 只创建一个 `StdioMcpClient` 实例
2. **`tokio::sync::Mutex` 启动锁**（异步互斥）— 保证 `start()` 只执行一次

```
get_or_start_stdio_client(config, workspace):
  │
  ├─ DashMap::entry(key).or_insert_with(|| new())  ← 同步，只创建一个实例
  │
  └─ client.ensure_started()                        ← 异步，内部有 Mutex
       │
       ├─ 快速路径: is_running() → return Ok(())
       │
       └─ 慢路径: lock → double-check → start()
```

### 2.2 涉及文件

| 文件 | 改动类型 |
|------|---------|
| `core/src/client/stdio.rs` | 新增 `start_lock` 字段 + `ensure_started()` 方法 |
| `core/src/router/mod.rs` | 新增 `get_or_start_stdio_client`，重构 `list_server_tools` / `call_tool` / `remove_server` |

## 三、详细改动

### 3.1 StdioMcpClient — 启动锁

**文件**: `core/src/client/stdio.rs`

#### 3.1.1 新增字段

```rust
pub struct StdioMcpClient {
    config: ServerConfig,
    peer: RwLock<Option<Arc<Peer<RoleClient>>>>,
    tools_cache: RwLock<Option<Vec<McpTool>>>,
    start_lock: tokio::sync::Mutex<()>,  // 新增：防止并发启动
}
```

#### 3.1.2 新增 `ensure_started()` 方法

```rust
/// Ensure the client is started (thread-safe, idempotent)
///
/// Uses double-check locking:
/// 1. Fast path: already running → return immediately
/// 2. Slow path: acquire lock → check again → start if needed
pub async fn ensure_started(&self) -> Result<(), ClientError> {
    // Fast path: no lock needed
    if self.is_running() {
        return Ok(());
    }

    // Slow path: acquire start lock
    let _guard = self.start_lock.lock().await;

    // Double-check after acquiring lock
    if self.is_running() {
        return Ok(());
    }

    self.start().await
}
```

#### 3.1.3 `start()` 可见性调整

```rust
// 从 pub 改为 pub(crate)，防止外部绕过 ensure_started
pub(crate) async fn start(&self) -> Result<(), ClientError> {
    // 保留内部 is_some() 检查作为最后防线
    if self.peer.read().is_some() {
        return Ok(());
    }
    // ... 其余不变
}
```

### 3.2 McpRouter — 统一获取方法

**文件**: `core/src/router/mod.rs`

#### 3.2.1 新增 `get_or_start_stdio_client`

```rust
/// Get or create+start a stdio client for the given server config and workspace.
///
/// Concurrency safety:
/// - DashMap entry API ensures only one client instance per key
/// - StdioMcpClient internal Mutex ensures start() runs only once
async fn get_or_start_stdio_client(
    &self,
    config: &ServerConfig,
    workspace: Option<&Workspace>,
) -> Result<Arc<StdioMcpClient>, ClientError> {
    let token = workspace.map(|w| w.token.as_str()).unwrap_or("default");
    let key = format!("{}::{}", token, config.name);

    // entry API is synchronous — guarantees only one instance created
    let client = self.stdio_clients
        .entry(key)
        .or_insert_with(|| Arc::new(StdioMcpClient::new(config.clone())))
        .value()
        .clone();

    // ensure_started has its own Mutex — safe for concurrent callers
    client.ensure_started().await?;
    Ok(client)
}
```

#### 3.2.2 重构 `list_server_tools`

```rust
async fn list_server_tools(
    &self,
    config: &ServerConfig,
    workspace: Option<&Workspace>,
) -> Result<Vec<McpTool>, String> {
    match config.server_type {
        ServerType::Http => { /* 不变 */ }
        ServerType::Stdio => {
            let client = self.get_or_start_stdio_client(config, workspace)
                .await
                .map_err(|e| format!("Failed to start stdio client: {}", e))?;
            client.list_tools().await.map_err(|e| format!("{}", e))
        }
    }
}
```

#### 3.2.3 重构 `call_tool`

```rust
ServerType::Stdio => {
    let client = self.get_or_start_stdio_client(config, workspace)
        .await
        .map_err(|e| JsonRpcError::internal_error(&e.to_string()))?;
    client
        .call_tool(tool_name, arguments)
        .await
        .map_err(|e| JsonRpcError::internal_error(&e.to_string()))
}
```

### 3.3 修复 `remove_server`

**文件**: `core/src/router/mod.rs`

#### 问题

```rust
// 当前代码：key 是 "token::name"，但用 name 去删，永远匹配不到
self.stdio_clients.remove(name);
```

#### 修复

```rust
pub fn remove_server(&mut self, name: &str) -> bool {
    let before_len = self.server_configs.len();
    self.server_configs.retain(|c| c.name != name);
    self.http_clients.remove(name);

    // Fix: stdio_clients key format is "token::name", match by server name part
    let keys_to_remove: Vec<String> = self.stdio_clients
        .iter()
        .filter(|entry| {
            entry.key().split_once("::").map(|(_, n)| n == name).unwrap_or(false)
        })
        .map(|entry| entry.key().clone())
        .collect();

    for key in &keys_to_remove {
        if let Some((_, client)) = self.stdio_clients.remove(key) {
            // Stop the child process to prevent leaks
            get_runtime().block_on(client.stop());
        }
    }

    // Invalidate flattened tool maps cache
    self.flattened_tool_maps.clear();

    before_len != self.server_configs.len()
}
```

### 3.4 缓存失效

**文件**: `core/src/router/mod.rs`

在以下方法末尾添加 `self.flattened_tool_maps.clear()`：

- `add_server()`
- `remove_server()` (已包含在 3.3)
- `set_server_enabled()`
- `set_server_flatten_mode()`

## 四、不在本次范围的已知局限

| 项目 | 说明 | 影响 | 后续方案 |
|------|------|------|---------|
| 进程崩溃后被动重连 | `is_running()` 只检查 `peer.is_some()`，进程崩溃后 peer 仍存在 | `call_tool` 报错但不会自动重启 | 检测 RPC 错误后清理 peer + 重试 |
| `service_handle` 未保存 | `start()` 中 spawn 的 task handle 丢弃 | 无法主动检测进程退出 | 保存 handle，监听 `waiting()` |
| Supervisor actor | 每个 workspace+server 一个 actor 管理生命周期 | 当前靠 DashMap + Mutex 管理 | 架构级重构 |
| `tools_cache` 崩溃不清理 | 进程重启后可能返回过期工具列表 | 低概率，工具列表一般不变 | 在 `start()` 中清理缓存 |

## 五、改动总结

```
core/src/client/stdio.rs
  ├─ StdioMcpClient 新增 start_lock 字段
  ├─ 新增 ensure_started() 方法
  └─ start() 改为 pub(crate)

core/src/router/mod.rs
  ├─ 新增 get_or_start_stdio_client() 方法
  ├─ list_server_tools() Stdio 分支改用 get_or_start_stdio_client
  ├─ call_tool() Stdio 分支改用 get_or_start_stdio_client
  ├─ remove_server() 修复 key 匹配 + 调用 stop() + 清理缓存
  ├─ add_server() 末尾清理 flattened_tool_maps
  ├─ set_server_enabled() 末尾清理 flattened_tool_maps
  └─ set_server_flatten_mode() 末尾清理 flattened_tool_maps
```

---

**文档版本**: v1.0
**创建日期**: 2025-02-07
**审查**: Claude Opus + OpenAI Codex (gpt-5.2-codex)
