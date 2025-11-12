# MCP Router - Workspace 功能设计文档

## 一、概述

### 1.1 目标
为 MCP Router 添加 Workspace 管理功能，实现：
- 不同项目使用不同的 MCP Server 组合
- 自动化配置，零学习成本
- 基于 Token 的自动路由

### 1.2 核心价值
- **智能路由**：根据请求 Token 自动返回对应项目的 MCP Server 列表
- **一键配置**：拖入项目文件夹，自动生成并注入配置
- **配置继承**：新项目默认继承全局配置，也可自定义

## 二、技术方案

### 2.1 Token 映射机制

#### 工作原理
```
项目 A 的 .mcp.json:
{
  "mcpServers": {
    "mcp-router": {
      "type": "http",
      "url": "http://localhost:3000",
      "headers": {
        "X-Workspace-Token": "abc123"
      }
    }
  }
}

项目 B 的 .mcp.json:
{
  "mcpServers": {
    "mcp-router": {
      "type": "http",
      "url": "http://localhost:3000",
      "headers": {
        "X-Workspace-Token": "def456"
      }
    }
  }
}

MCP Router 处理流程:
1. 接收 HTTP 请求
2. 读取 Header: X-Workspace-Token
3. 根据 Token 查找对应的 Workspace
4. 返回该 Workspace 启用的 MCP Servers
```

#### 优势
- ✅ 单端口支持多项目
- ✅ 自动识别，无需手动切换
- ✅ 支持并发（多个项目同时使用）

### 2.2 数据模型

```swift
// MCP Server 定义（全局池）
@Model final class MCPServer {
    @Attribute(.unique) var id: UUID
    var name: String              // "context7"
    var serverDescription: String // "AI 代码搜索"
    var type: ServerType          // .http / .stdio

    // HTTP Server
    var url: String?
    var headers: [String: String]

    // Stdio Server
    var command: String?
    var args: [String]
    var env: [String: String]

    var createdAt: Date

    // 关联关系
    @Relationship(inverse: \Workspace.servers)
    var workspaces: [Workspace]
}

// Workspace 配置
@Model final class Workspace {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var token: String  // "abc123" - 关键字段
    var name: String                        // "project-a"
    var projectPath: String?                // "/Users/.../project-a"
    var isDefault: Bool                     // 默认 Workspace
    var inheritFromDefault: Bool            // 是否继承默认配置
    var createdAt: Date

    // 启用的 Servers（多对多关系）
    @Relationship var servers: [MCPServer]
}
```

### 2.3 请求处理流程

```swift
// HTTPServer.swift
private func handleJSONRPC(request: JSONRPCRequest, headers: [String: String]) async throws -> AnyCodable {
    // 1. 提取 Workspace Token
    let token = headers["X-Workspace-Token"]

    // 2. 查找对应的 Workspace
    let workspace = await router.findWorkspace(byToken: token)
    // token 为空或找不到 → 使用 Default Workspace

    switch request.method {
    case "tools/list":
        // 3. 返回该 Workspace 启用的工具
        let routerTools = await router.generateRouterTools()
        return AnyCodable(["tools": routerTools])

    case "tools/call":
        // 4. 根据 Workspace 路由到对应的 Server
        return try await router.handleToolCall(
            name: toolName,
            arguments: arguments,
            workspace: workspace
        )
    }
}
```

## 三、用户体验设计

### 3.1 拖入文件夹自动配置

#### 交互流程
```
1. 用户拖入项目文件夹到 MCP Router 窗口
   📁 /Users/higuaifan/Desktop/project-a

2. 系统自动处理：
   ├─ 生成唯一 Token: "a1b2c3d4"
   ├─ 检测 project-a/.mcp.json
   │   ├─ 不存在 → 创建新文件
   │   └─ 已存在 → 读取并合并
   ├─ 注入 mcp-router 配置（带 Token）
   └─ 创建 Workspace 记录

3. 弹出配置对话框：
   ├─ 选择继承 Default 或自定义
   ├─ 选择启用的 MCP Servers
   └─ 保存配置
```

#### .mcp.json 智能合并

**场景 1: 文件不存在**
```json
// 自动创建
{
  "mcpServers": {
    "mcp-router": {
      "type": "http",
      "url": "http://localhost:3000",
      "headers": {
        "X-Workspace-Token": "a1b2c3d4"
      }
    }
  }
}
```

**场景 2: 文件已存在**
```json
// 原有配置
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem"]
    }
  }
}

// 合并后（保留原有配置）
{
  "mcpServers": {
    "mcp-router": {              // 新增
      "type": "http",
      "url": "http://localhost:3000",
      "headers": {
        "X-Workspace-Token": "a1b2c3d4"
      }
    },
    "filesystem": {              // 保留
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem"]
    }
  }
}
```

**场景 3: 已有 mcp-router 配置**
```
提示用户选择：
┌────────────────────────────────────┐
│ ⚠️  此项目已配置 mcp-router        │
├────────────────────────────────────┤
│ 检测到 Token: xyz789               │
│                                    │
│ ○ 导入现有配置                     │
│   (在 UI 中创建对应的 Workspace)   │
│                                    │
│ ○ 覆盖为新配置                     │
│   (生成新 Token 并替换)            │
│                                    │
│ ○ 取消                             │
└────────────────────────────────────┘
```

### 3.2 UI 界面设计

#### 主窗口
```
┌────────────────────────────────────────────┐
│  MCP Router                    [Settings] ▢│
├────────────────────────────────────────────┤
│                                            │
│  ┌──────────────────────────────────────┐ │
│  │  📁 拖入项目文件夹以添加 Workspace   │ │
│  │     或点击 [Browse...] 选择          │ │
│  └──────────────────────────────────────┘ │
│                                            │
│  Active Workspaces:                        │
│  ┌──────────────────────────────────────┐ │
│  │ ✓ Default (全局默认)                 │ │
│  │   Token: (none)                      │ │
│  │   Servers: context7, janghood        │ │
│  │   [Edit]                             │ │
│  ├──────────────────────────────────────┤ │
│  │ 📁 mcp-router                        │ │
│  │   Token: abc123                   📋 │ │
│  │   Path: ~/Desktop/hi/小工具/...      │ │
│  │   Servers: 继承 Default              │ │
│  │   [Edit] [Remove]                    │ │
│  ├──────────────────────────────────────┤ │
│  │ 📁 project-a                         │ │
│  │   Token: def456                   📋 │ │
│  │   Path: ~/Desktop/project-a          │ │
│  │   Servers: context7, chrome-devtools │ │
│  │   [Edit] [Remove]                    │ │
│  └──────────────────────────────────────┘ │
│                                            │
│  Server Pool (全局可用):                   │
│  • context7 (HTTP)                         │
│  • janghood (HTTP)                         │
│  • chrome-devtools (HTTP)                  │
│  [+ Add Server]                            │
└────────────────────────────────────────────┘
```

#### Workspace 配置对话框
```
┌─────────────────────────────────────────┐
│ Configure Workspace: project-a          │
├─────────────────────────────────────────┤
│ Name: project-a                         │
│ Path: /Users/higuaifan/Desktop/project-a│
│ Token: def456                        📋 │
│                                         │
│ Server Configuration:                   │
│ ┌─────────────────────────────────────┐ │
│ │ ○ 继承 Default Workspace            │ │
│ │   (context7, janghood)              │ │
│ │                                     │ │
│ │ ● 自定义选择                        │ │
│ │   ☑ context7                        │ │
│ │   ☐ janghood                        │ │
│ │   ☑ chrome-devtools                 │ │
│ └─────────────────────────────────────┘ │
│                                         │
│ .mcp.json Status:                       │
│ ✓ 文件已更新                            │
│ ✓ mcp-router 配置已添加                 │
│                                         │
│ 配置预览:                                │
│ ┌─────────────────────────────────────┐ │
│ │{                                    │ │
│ │  "mcpServers": {                    │ │
│ │    "mcp-router": {                  │ │
│ │      "type": "http",                │ │
│ │      "url": "http://localhost:3000",│ │
│ │      "headers": {                   │ │
│ │        "X-Workspace-Token": "def456"│ │
│ │      }                               │ │
│ │    }                                 │ │
│ │  }                                   │ │
│ │}                                     │ │
│ └─────────────────────────────────────┘ │
│                          [Copy] 📋      │
│                                         │
│           [Cancel]  [Save & Apply]      │
└─────────────────────────────────────────┘
```

### 3.3 菜单栏快捷菜单

```
┌──────────────────────────┐
│ ⚡️ MCP Router            │
├──────────────────────────┤
│ ● Running (port 3000)    │
├──────────────────────────┤
│ Active Workspaces: 3     │
│   • Default              │
│   • mcp-router           │
│   • project-a            │
├──────────────────────────┤
│ ⚙️  Open Settings         │
│ 📋 Copy Default URL      │
│ 🔄 Restart Server        │
├──────────────────────────┤
│ ☑ Launch at Login        │
├──────────────────────────┤
│ Quit MCP Router          │
└──────────────────────────┘
```

## 四、实现路线图

### Phase 1: 基础架构（已完成 ✅）
- [x] HTTP Server 基础实现
- [x] 三个元工具（list, describe, call）
- [x] Token 消耗优化验证

### Phase 2: 菜单栏应用改造
- [ ] AppDelegate 改造（accessory 模式）
  - `NSApp.setActivationPolicy(.accessory)` - 不在 Dock 显示
  - 菜单栏图标 + 快捷菜单
- [ ] 状态监控
  - 服务运行状态
  - 当前激活的 Workspace 数量
- [ ] 快捷操作
  - 打开设置窗口
  - 重启服务
  - 复制配置

### Phase 3: Workspace 数据模型
- [ ] 扩展 SwiftData 模型
  - Workspace 模型（增加 token 字段）
  - MCPServer <-> Workspace 多对多关系
- [ ] 迁移现有配置
  - 创建 Default Workspace
  - 导入硬编码的 Server 配置
- [ ] Token 管理
  - Token 生成策略（UUID 前 8 位）
  - 唯一性校验
  - Token 查找优化（索引）

### Phase 4: 文件夹拖放功能
- [ ] 拖放区域 UI
  - `.onDrop` 实现
  - 拖放视觉反馈
- [ ] .mcp.json 处理
  - 文件检测
  - JSON 解析/合并
  - 写回文件
- [ ] 自动配置流程
  - Token 生成
  - Workspace 创建
  - 配置对话框展示

### Phase 5: Workspace 管理界面
- [ ] Workspace 列表视图
  - 展示所有 Workspace
  - Token 显示与复制
  - 继承状态指示
- [ ] Workspace 编辑
  - Server 选择（继承/自定义）
  - 配置预览
  - 保存/取消
- [ ] Workspace 删除
  - 确认对话框
  - 可选：同时删除 .mcp.json 配置

### Phase 6: Server 管理界面
- [ ] Server Pool 管理
  - 添加/编辑/删除 Server
  - HTTP/stdio 配置表单
  - Server 测试功能（连接测试）
- [ ] Server 引用追踪
  - 显示哪些 Workspace 使用了该 Server
  - 删除前警告

### Phase 7: 高级功能
- [ ] 开机自启动
  - `SMAppService` 集成
  - 设置界面 Toggle
- [ ] 文件监控（可选）
  - 监控 .mcp.json 变化
  - 自动同步到 UI
- [ ] 导入/导出
  - 导出全局配置
  - 导入配置到其他机器
- [ ] 日志查看
  - 请求日志
  - Token 映射日志
  - 错误日志

## 五、待解决问题

### 5.1 文件监控
**问题**：是否监控 .mcp.json 文件变化并同步到 UI？

**方案**：
- A. 不监控（简单，用户需手动刷新）
- B. 使用 FSEvents 监控（复杂，自动同步）

**建议**：Phase 1 不实现，Phase 7 可选增强

### 5.2 Token 冲突处理
**问题**：用户手动修改 .mcp.json 中的 Token 导致冲突

**方案**：
- A. 启动时扫描所有 Workspace 的 .mcp.json，检测冲突
- B. 提供"重新同步"按钮，手动修复
- C. 只在添加/编辑时校验

**建议**：实现 C，提供手动同步功能

### 5.3 删除 Workspace 行为
**问题**：删除 Workspace 时是否删除 .mcp.json 中的 mcp-router 配置？

**方案**：
- A. 只删除 SwiftData 记录，保留 .mcp.json
- B. 询问用户是否同时删除文件配置
- C. 自动删除文件配置

**建议**：实现 B，给用户选择权

### 5.4 Token 格式
**问题**：Token 应该用什么格式？

**选项**：
- A. UUID 全长：`123e4567-e89b-12d3-a456-426614174000`（安全但冗长）
- B. UUID 前 8 位：`123e4567`（简洁，冲突概率低）
- C. 自定义短码：`abc-def-123`（易读，需要冲突检测）
- D. 用户自定义（需唯一性校验）

**建议**：默认 B（UUID 前 8 位），支持 D（手动编辑）

## 六、技术细节

### 6.1 Token 生成与校验

```swift
extension Workspace {
    static func generateToken() -> String {
        return UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
    }

    static func validateTokenUnique(_ token: String, context: ModelContext) throws {
        let descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.token == token }
        )
        let existing = try context.fetch(descriptor)
        if !existing.isEmpty {
            throw WorkspaceError.duplicateToken
        }
    }
}
```

### 6.2 .mcp.json 合并逻辑

```swift
func mergeMCPConfig(projectPath: URL, token: String) throws {
    let configPath = projectPath.appendingPathComponent(".mcp.json")

    // 读取现有配置
    var config: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: configPath.path) {
        let data = try Data(contentsOf: configPath)
        config = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // 合并 mcpServers
    var servers = config["mcpServers"] as? [String: Any] ?? [:]
    servers["mcp-router"] = [
        "type": "http",
        "url": "http://localhost:3000",
        "headers": [
            "X-Workspace-Token": token
        ]
    ]
    config["mcpServers"] = servers

    // 写回文件（格式化）
    let jsonData = try JSONSerialization.data(
        withJSONObject: config,
        options: [.prettyPrinted, .sortedKeys]
    )
    try jsonData.write(to: configPath)
}
```

### 6.3 菜单栏应用配置

```swift
// mcp_routerApp.swift
@main
struct mcp_routerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 设置窗口（可隐藏）
        WindowGroup(id: "settings") {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不在 Dock 显示
        NSApp.setActivationPolicy(.accessory)

        // 创建菜单栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "MCP Router")

        // 创建菜单
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Running (port 3000)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
```

## 七、未来扩展

### 7.1 云端同步（可选）
- iCloud 同步配置
- 多设备共享 Workspace 配置

### 7.2 协作功能（可选）
- 导出 Workspace 配置给团队成员
- 配置模板（预设常用组合）

### 7.3 统计分析（可选）
- Workspace 使用频率
- Server 调用统计
- 性能监控

## 八、总结

### 核心创新点
1. **Token 映射机制** - 单端口支持多项目自动路由
2. **拖放自动配置** - 零配置门槛，极致用户体验
3. **配置继承** - 全局默认 + 项目自定义

### 实施优先级
- 🔥 高优先级：Phase 2-4（菜单栏 + 基础 Workspace）
- 🟡 中优先级：Phase 5-6（管理界面）
- 🟢 低优先级：Phase 7（高级功能）

### 开发时间估算
- Phase 2: 2-3 天
- Phase 3: 1-2 天
- Phase 4: 2-3 天
- Phase 5: 3-4 天
- Phase 6: 2-3 天
- Phase 7: 按需实现

**总计**：约 10-15 天完整实现
