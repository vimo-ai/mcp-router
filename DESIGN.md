# MCP Router 设计文档

## 项目概述

**MCP Router** - 一个轻量级的 MCP Server 管理工具

### 核心价值
- 统一管理多个 MCP Server
- 不同项目使用不同的 Server 组合(Workspace)
- 原生 macOS 应用,轻量高效

### 对比 MCP Router (Electron 版本)
- ✅ 借鉴: HTTP 反向代理 + Process 管理
- ❌ 舍弃: Token 认证(自己用,不需要)
- ❌ 舍弃: 工具聚合(浪费 token)
- ❌ 舍弃: 审计日志(无意义)
- ✅ 保留: Workspace 概念

## 核心功能

### 1. Server 管理
- 启动/停止 MCP Server 进程
- 支持 stdio 通信
- 每个 Workspace 独立实例(避免状态混乱)

### 2. Workspace 切换
- 不同项目需要不同的 Server 组合
- 例如:
  - Web 项目: chrome, github, database
  - iOS 项目: xcode, github, simulator

### 3. Smart Router
- 按需加载 tools(不是一次性返回所有)
- 动态路由请求到对应的 Server
- 节省 token

### 4. HTTP API
- 暴露统一的 HTTP 端点
- 客户端(Claude Code/Cursor)只需连接一个地址
- 支持通过 Header 切换 Workspace

## 技术架构

### 技术栈
- **语言**: Swift
- **UI**: SwiftUI
- **存储**: SwiftData
- **HTTP Server**: Vapor
- **平台**: macOS 14+

### 模块设计

```
MCPRouter/
├── Models/              # 数据模型 (SwiftData)
│   ├── ServerConfig
│   └── Workspace
│
├── Core/                # 核心逻辑
│   ├── ProcessManager   # 进程管理
│   ├── MCPClient        # MCP 协议通信
│   └── SmartRouter      # 智能路由
│
├── Server/              # HTTP 服务
│   └── VaporApp         # Vapor API
│
└── Views/               # SwiftUI 界面
    ├── ServerListView
    └── WorkspaceView
```

## 数据模型

### ServerConfig
```swift
@Model
class ServerConfig {
    var id: UUID
    var name: String           // "chrome-devtools"
    var command: String        // "npx"
    var args: [String]         // ["-y", "@mcp/chrome-devtools"]
    var env: [String: String]  // 环境变量
}
```

### Workspace
```swift
@Model
class Workspace {
    var id: UUID
    var name: String                    // "Web Project A"
    var servers: [ServerConfig]         // 启用的 servers
}
```

## 核心流程

### 1. 启动流程
```
用户启动 App
  ↓
加载 SwiftData 数据
  ↓
启动 Vapor HTTP Server (localhost:3000)
  ↓
等待客户端连接
```

### 2. 切换 Workspace
```
用户选择 Workspace "Web Project A"
  ↓
停止当前运行的 Servers
  ↓
启动 "Web Project A" 的 Servers
  - chrome-devtools
  - github
  - database
  ↓
更新 Router 的 tool 映射
```

### 3. 处理请求
```
Claude Code 发送请求:
POST http://localhost:3000/mcp
{ method: "tools/call", params: { name: "search_repositories" }}
  ↓
Router 查找 "search_repositories" 属于哪个 Server
  ↓
转发到 github-server (通过 stdin/stdout)
  ↓
返回结果给客户端
```

## 关键设计决策

### 1. 为什么每个 Workspace 独立 Server 实例?

**问题**: Chrome 等有状态的 Server 如果共享会导致:
- 多个项目的 tabs 混在一起
- tools/list 返回无关的 tabs,浪费 token
- 状态混乱,互相干扰

**决策**: 每个 Workspace 独立启动 Servers

### 2. 为什么不用 Token 认证?

**原因**:
- 只有自己使用
- 多客户端(Claude Code + Cursor)但都是自己
- 不需要审计日志
- 简化设计

**决策**: 无认证,或者简单的 API Key(可选)

### 3. Smart Router vs 工具聚合

**MCP Router 的问题**:
```
返回所有 tools (10 个 servers × 20 tools = 200 tools)
→ 每次对话消耗 40,000+ tokens
```

**我们的方案**:
```
方案 1: 懒加载
  - tools/list 只返回名称列表
  - tools/get 按需获取完整 schema

方案 2: 按需路由
  - 根据 tool name 直接路由
  - 不需要提前加载所有 tools
```

### 4. 存储方案

**配置数据**: SwiftData
- 用户通过 GUI 管理
- 类型安全
- SwiftUI 自动绑定

**运行时状态**: 内存(Actor)
- 哪些 Server 在运行
- 不需要持久化

## MVP 功能范围

### Phase 1: 核心功能
- [ ] SwiftData 模型
- [ ] ProcessManager (启动/停止 Server)
- [ ] MCPClient (stdio 通信)
- [ ] 基础 HTTP Server
- [ ] 简单 Router (直接转发)

### Phase 2: UI
- [ ] Server 列表页面
- [ ] Workspace 管理页面
- [ ] 启动/停止控制

### Phase 3: 优化
- [ ] Smart Router (按需加载)
- [ ] 日志查看
- [ ] 错误处理

## 开发估算

### 代码量
- Models: ~200 行
- Core: ~1,200 行
- Server: ~400 行
- Views: ~600 行
- **总计**: ~2,400 行

### 工作量
- **MVP**: 2-3 天
- **完整版**: 4-5 天

### Token 消耗
- **MVP**: ~180K tokens ($1)
- **完整版**: ~350K tokens ($2-3)

## 客户端配置示例

### Claude Code 配置
```json
{
  "mcpServers": {
    "mcp-router": {
      "type": "http",
      "url": "http://localhost:3000/mcp",
      "headers": {
        "X-Workspace": "web-project"
      }
    }
  }
}
```

### 通过不同 Workspace 使用
```json
{
  "mcpServers": {
    "router-web": {
      "type": "http",
      "url": "http://localhost:3000/mcp",
      "headers": { "X-Workspace": "web-project" }
    },
    "router-ios": {
      "type": "http",
      "url": "http://localhost:3000/mcp",
      "headers": { "X-Workspace": "ios-project" }
    }
  }
}
```

## 非功能需求

### 性能
- 启动时间 < 2 秒
- 请求延迟 < 100ms
- 内存占用 < 100MB (不含 MCP Servers)

### 稳定性
- Server 崩溃自动重启
- 请求失败重试机制
- 完整的错误日志

### 用户体验
- 一键启动/停止 Workspace
- 实时显示 Server 状态
- 清晰的错误提示

## 后续扩展(可选)

### 远期功能
- 配置导入/导出
- Server 模板市场
- 远程 Workspace (团队共享)
- 性能监控面板

### 不做的功能
- ❌ 多用户/权限管理
- ❌ 云同步
- ❌ 复杂的审计日志
- ❌ 工具市场

## 参考资源

- MCP 协议文档: https://modelcontextprotocol.io
- MCP SDK: https://github.com/modelcontextprotocol/sdk
- Vapor 文档: https://docs.vapor.codes
- SwiftData 文档: https://developer.apple.com/documentation/swiftdata

---

**版本**: v0.1
**创建日期**: 2025-01-10
**最后更新**: 2025-01-10
