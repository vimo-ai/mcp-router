# MCP Router - stdio 类型 Server 支持实施文档

## 一、概述

### 1.1 目标
为 MCP Router 添加 stdio 类型 MCP Server 支持,使其能够:
- 启动和管理 stdio 子进程
- 通过 stdin/stdout 与子进程通信
- 支持 Workspace 级别的进程隔离
- 自动重启崩溃的进程

### 1.2 适用场景
- **chrome-devtools**: 浏览器自动化工具
- **filesystem**: 文件系统访问
- **puppeteer**: 浏览器控制
- 其他基于 Node.js/Python 的 MCP Server

## 二、技术方案

### 2.1 stdio vs HTTP 对比

| 特性 | HTTP 类型 | stdio 类型 |
|------|----------|-----------|
| 通信方式 | HTTP 请求/响应 | stdin/stdout |
| 进程管理 | Server 独立运行 | **我们管理子进程** |
| 连接状态 | 无状态 | 有状态(进程持续运行) |
| 并发处理 | 简单(每次新请求) | 复杂(需要匹配 id) |
| Workspace隔离 | 共享实例(通过Token) | **独立进程实例** |
| 实现复杂度 | 简单 | 复杂 |

### 2.2 核心挑战

#### 挑战 1: 进程生命周期管理
```swift
// 需要实现:
class ProcessManager {
    func start() throws              // 启动进程
    func stop() async                // 优雅关闭
    func restart() async throws      // 重启
    func isAlive() -> Bool          // 健康检查
}
```

#### 挑战 2: 双向异步通信
```
应用 ─────stdin────→ 子进程
     ←────stdout──── (JSON-RPC 响应)
     ←────stderr──── (日志/错误)
```

特点:
- stdin: 写入 JSON-RPC 请求
- stdout: 读取 JSON-RPC 响应(需要异步处理)
- stderr: 错误日志(需要单独读取)

#### 挑战 3: 请求/响应匹配
HTTP 是同步的:
```swift
let response = await send(request)  // 立即得到响应
```

stdio 是异步的:
```swift
// 发送请求
send(request)  // 写入 stdin

// 稍后从 stdout 读到响应
// 需要根据 id 匹配到原始请求
```

#### 挑战 4: Workspace 进程隔离
- chrome-devtools 有状态(浏览器 tabs)
- 不同 Workspace 需要独立进程
- 需要进程池管理

## 三、架构设计

### 3.1 类结构

```
StdioMCPClient (新增)
├── ProcessManager          # 进程管理
│   ├── start()
│   ├── stop()
│   └── restart()
│
├── StdioTransport          # 通信层
│   ├── writeRequest()     # 写入 stdin
│   ├── readResponse()     # 读取 stdout
│   └── readError()        # 读取 stderr
│
└── RequestMatcher          # 请求匹配
    ├── sendRequest()      # 发送并等待响应
    └── handleResponse()   # 处理接收到的响应

WorkspaceProcessPool (新增)
├── getOrCreateProcess()   # 获取或创建 Workspace 的进程
├── releaseProcess()       # 释放进程
└── cleanupAll()           # 清理所有进程
```

### 3.2 数据流

```
Client (Claude Code)
    │
    │ HTTP Request (tools/call)
    ↓
HTTPServer
    │
    │ 路由到 Workspace
    ↓
MCPRouter
    │
    │ 查找 Server 类型
    ↓
StdioMCPClient
    │
    │ 1. 获取或创建进程
    ↓
WorkspaceProcessPool
    │
    │ 2. 发送请求
    ↓
ProcessManager (子进程)
    │
    │ stdin: {"jsonrpc":"2.0","id":1,"method":"tools/call",...}
    ↓
MCP Server (chrome-devtools)
    │
    │ stdout: {"jsonrpc":"2.0","id":1,"result":{...}}
    ↓
StdioTransport
    │
    │ 3. 匹配响应
    ↓
RequestMatcher
    │
    │ 4. 返回结果
    ↓
Client
```

## 四、核心实现

### 4.1 ProcessManager - 进程管理

```swift
// mcp-router/Services/ProcessManager.swift (新建)
import Foundation

actor ProcessManager {
    let config: ServerConfig
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var isRunning = false

    init(config: ServerConfig) {
        self.config = config
    }

    // 启动进程
    func start() throws {
        guard !isRunning else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        // 解析命令
        // config.command = "npx"
        // config.args = ["-y", "chrome-devtools-mcp@latest"]
        process.arguments = [config.command ?? "npx"] + config.args

        // 设置环境变量
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in config.env {
            environment[key] = value
        }
        process.environment = environment

        // 设置管道
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.process = process

        // 监听进程退出
        process.terminationHandler = { [weak self] proc in
            Task { await self?.handleTermination(exitCode: proc.terminationStatus) }
        }

        try process.run()
        isRunning = true

        print("✅ 启动 stdio 进程: \(config.name) (PID: \(process.processIdentifier))")
    }

    // 停止进程
    func stop() async {
        guard isRunning, let process = process else { return }

        // 1. 发送 graceful shutdown 请求
        do {
            let shutdownRequest = """
            {"jsonrpc":"2.0","method":"shutdown","id":9999}

            """
            try await write(shutdownRequest)

            // 等待 2 秒
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
            print("⚠️ Shutdown 请求失败: \(error)")
        }

        // 2. 终止进程
        if process.isRunning {
            process.terminate()
            print("🛑 终止进程: \(config.name)")
        }

        isRunning = false
    }

    // 重启进程
    func restart() async throws {
        await stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try start()
    }

    // 检查进程是否存活
    func isAlive() -> Bool {
        return isRunning && (process?.isRunning ?? false)
    }

    // 写入 stdin
    func write(_ data: String) async throws {
        guard let inputPipe = inputPipe else {
            throw MCPError.processNotRunning
        }

        let dataWithNewline = data.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let utf8Data = dataWithNewline.data(using: .utf8) else {
            throw MCPError.encodingError
        }

        try inputPipe.fileHandleForWriting.write(contentsOf: utf8Data)
    }

    // 读取 stdout (阻塞)
    func readLine() async throws -> String? {
        guard let outputPipe = outputPipe else {
            throw MCPError.processNotRunning
        }

        // 使用 FileHandle.bytes 异步读取
        let handle = outputPipe.fileHandleForReading
        var buffer = Data()

        for try await byte in handle.bytes {
            if byte == UInt8(ascii: "\n") {
                // 读到换行符
                if let line = String(data: buffer, encoding: .utf8) {
                    return line
                }
                buffer.removeAll()
            } else {
                buffer.append(byte)
            }
        }

        // 进程已关闭
        return nil
    }

    // 读取 stderr (非阻塞)
    func readError() -> String? {
        guard let errorPipe = errorPipe else { return nil }

        let data = errorPipe.fileHandleForReading.availableData
        return data.isEmpty ? nil : String(data: data, encoding: .utf8)
    }

    private func handleTermination(exitCode: Int32) {
        isRunning = false
        print("⚠️ 进程退出: \(config.name) (exit code: \(exitCode))")

        // TODO: 如果是异常退出,考虑自动重启
        if exitCode != 0 {
            print("❌ 进程异常退出,可能需要重启")
        }
    }
}
```

### 4.2 RequestMatcher - 请求/响应匹配

```swift
// mcp-router/Services/RequestMatcher.swift (新建)
import Foundation

actor RequestMatcher {
    private var pendingRequests: [Int: CheckedContinuation<AnyCodable, Error>] = [:]
    private var nextRequestID: Int = 1

    // 发送请求并等待响应
    func sendRequest(
        processManager: ProcessManager,
        method: String,
        params: [String: AnyCodable]?
    ) async throws -> AnyCodable {
        let requestID = nextRequestID
        nextRequestID += 1

        // 构造 JSON-RPC 请求
        let request = JSONRPCRequest(id: requestID, method: method, params: params)
        let requestData = try JSONEncoder().encode(request)
        guard let requestString = String(data: requestData, encoding: .utf8) else {
            throw MCPError.encodingError
        }

        // 写入 stdin
        try await processManager.write(requestString)

        // 等待响应
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation

            // 设置超时(30秒)
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let pending = pendingRequests.removeValue(forKey: requestID) {
                    pending.resume(throwing: MCPError.timeout)
                }
            }
        }
    }

    // 处理接收到的响应
    func handleResponse(_ response: JSONRPCResponse) {
        guard let id = response.id else {
            print("⚠️ 收到没有 id 的响应(可能是通知)")
            return
        }

        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            print("⚠️ 收到未匹配的响应 id: \(id)")
            return
        }

        if let error = response.error {
            continuation.resume(throwing: MCPError.rpcError(error.code, error.message))
        } else if let result = response.result {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: MCPError.invalidResponse)
        }
    }

    // 清理所有待处理请求
    func cancelAll() {
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPError.cancelled)
        }
        pendingRequests.removeAll()
    }
}
```

### 4.3 StdioMCPClient - 完整客户端

```swift
// mcp-router/Services/StdioMCPClient.swift (新建)
import Foundation

actor StdioMCPClient {
    let config: ServerConfig
    private let processManager: ProcessManager
    private let requestMatcher: RequestMatcher
    private var outputReaderTask: Task<Void, Never>?
    private var toolsCache: [MCPTool]?

    init(config: ServerConfig) {
        self.config = config
        self.processManager = ProcessManager(config: config)
        self.requestMatcher = RequestMatcher()
    }

    // 启动客户端
    func start() async throws {
        // 启动进程
        try await processManager.start()

        // 启动 stdout 读取任务
        startOutputReader()

        // 等待进程准备好(可选)
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    // 停止客户端
    func stop() async {
        outputReaderTask?.cancel()
        await requestMatcher.cancelAll()
        await processManager.stop()
    }

    // 获取工具列表
    func listTools() async throws -> [MCPTool] {
        if let cached = toolsCache {
            return cached
        }

        let result = try await requestMatcher.sendRequest(
            processManager: processManager,
            method: "tools/list",
            params: nil
        )

        let toolsData = try JSONSerialization.data(withJSONObject: result.value)
        let toolsResult = try JSONDecoder().decode(MCPToolsListResult.self, from: toolsData)

        toolsCache = toolsResult.tools
        print("✅ \(config.name): 成功加载 \(toolsResult.tools.count) 个工具")
        return toolsResult.tools
    }

    // 调用工具
    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> AnyCodable {
        let params: [String: AnyCodable] = [
            "name": AnyCodable(name),
            "arguments": AnyCodable(arguments.mapValues { $0.value })
        ]

        return try await requestMatcher.sendRequest(
            processManager: processManager,
            method: "tools/call",
            params: params
        )
    }

    // 启动 stdout 读取任务
    private func startOutputReader() {
        outputReaderTask = Task {
            while !Task.isCancelled {
                do {
                    // 读取一行
                    guard let line = try await processManager.readLine() else {
                        // 进程已关闭
                        break
                    }

                    // 解析 JSON-RPC 响应
                    if let data = line.data(using: .utf8) {
                        do {
                            let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
                            await requestMatcher.handleResponse(response)
                        } catch {
                            print("⚠️ 解析响应失败: \(line)")
                        }
                    }
                } catch {
                    print("❌ 读取 stdout 失败: \(error)")
                    break
                }
            }

            print("📤 stdout 读取任务已停止: \(config.name)")
        }
    }
}
```

### 4.4 WorkspaceProcessPool - Workspace 进程池

```swift
// mcp-router/Services/WorkspaceProcessPool.swift (新建)
import Foundation

actor WorkspaceProcessPool {
    // workspace.token -> StdioMCPClient
    private var processes: [String: StdioMCPClient] = [:]

    // 获取或创建 Workspace 的进程
    func getOrCreateClient(
        workspaceToken: String,
        config: ServerConfig
    ) async throws -> StdioMCPClient {
        if let existing = processes[workspaceToken] {
            return existing
        }

        // 创建新进程
        let client = StdioMCPClient(config: config)
        try await client.start()

        processes[workspaceToken] = client
        print("✅ 为 Workspace \(workspaceToken) 创建进程: \(config.name)")

        return client
    }

    // 释放 Workspace 的进程
    func releaseClient(workspaceToken: String) async {
        guard let client = processes.removeValue(forKey: workspaceToken) else {
            return
        }

        await client.stop()
        print("🛑 释放 Workspace \(workspaceToken) 的进程")
    }

    // 清理所有进程
    func cleanup() async {
        for (token, client) in processes {
            await client.stop()
            print("🛑 清理进程: \(token)")
        }
        processes.removeAll()
    }
}
```

### 4.5 集成到 MCPRouter

```swift
// mcp-router/Services/MCPRouter.swift (修改)

final class MCPRouter: ObservableObject {
    // ... 现有代码 ...

    // 新增: stdio 进程池
    private var stdioProcessPool = WorkspaceProcessPool()

    // 修改: loadServers
    func loadServers(_ configs: [ServerConfig]) async {
        serverConfigs = configs

        for config in configs {
            if config.type == .http {
                // HTTP 类型
                let client = MCPClient(config: config)
                servers[config.name] = client
            }
            // stdio 类型在需要时动态创建
        }

        print("✅ 已加载 \(servers.count) 个 HTTP Servers")
    }

    // 修改: handleList
    func handleList(filterServer: String?, workspace: Workspace?) async throws -> AnyCodable {
        var servers: [[String: Any]] = []
        let effectiveServers = getEffectiveServers(for: workspace)
        let effectiveServerNames = Set(effectiveServers.map { $0.name })

        for config in effectiveServers where effectiveServerNames.contains(config.name) {
            if let filter = filterServer, config.name != filter {
                continue
            }

            let tools: [MCPTool]
            if config.type == .http {
                // HTTP
                guard let client = self.servers[config.name] else { continue }
                tools = try await client.listTools()
            } else {
                // stdio
                let workspaceToken = workspace?.token ?? "default"
                let stdioClient = try await stdioProcessPool.getOrCreateClient(
                    workspaceToken: workspaceToken,
                    config: config
                )
                tools = try await stdioClient.listTools()
            }

            servers.append([
                "name": config.name,
                "description": config.serverDescription,
                "tools": tools.map { tool in
                    ["name": tool.name, "description": tool.description]
                }
            ])
        }

        return AnyCodable(["servers": servers])
    }

    // 类似修改 handleToolCall...
}
```

### 4.6 错误类型扩展

```swift
// mcp-router/Models/MCPModels.swift (修改)

enum MCPError: Error, LocalizedError {
    // ... 现有错误 ...

    // 新增 stdio 相关错误
    case processNotRunning
    case encodingError
    case timeout
    case cancelled
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "进程未运行"
        case .encodingError:
            return "编码失败"
        case .timeout:
            return "请求超时"
        case .cancelled:
            return "请求已取消"
        case .invalidResponse:
            return "无效的响应"
        // ...
        }
    }
}
```

## 五、测试计划

### 5.1 单元测试

```swift
// Tests/ProcessManagerTests.swift
import XCTest

final class ProcessManagerTests: XCTestCase {
    func testStartStop() async throws {
        let config = ServerConfig(
            name: "test",
            type: .stdio,
            command: "node",
            args: ["test-server.js"]
        )
        let manager = ProcessManager(config: config)

        try await manager.start()
        XCTAssertTrue(await manager.isAlive())

        await manager.stop()
        XCTAssertFalse(await manager.isAlive())
    }

    func testRestart() async throws {
        // 测试重启逻辑
    }

    func testAutoRestart() async throws {
        // 测试崩溃自动重启
    }
}
```

### 5.2 集成测试

```swift
// Tests/StdioMCPClientTests.swift
import XCTest

final class StdioMCPClientTests: XCTestCase {
    func testListTools() async throws {
        let config = ServerConfig(
            name: "chrome-devtools",
            type: .stdio,
            command: "npx",
            args: ["-y", "chrome-devtools-mcp@latest"]
        )
        let client = StdioMCPClient(config: config)

        try await client.start()
        let tools = try await client.listTools()

        XCTAssertFalse(tools.isEmpty)
        await client.stop()
    }

    func testCallTool() async throws {
        // 测试工具调用
    }

    func testConcurrentRequests() async throws {
        // 测试并发请求
    }
}
```

### 5.3 手动测试清单

- [ ] 启动 chrome-devtools Server
- [ ] 通过 mcp_router/list 查看工具
- [ ] 调用 chrome-devtools 工具
- [ ] 测试多个 Workspace 使用同一个 stdio Server
- [ ] 测试进程崩溃后的恢复
- [ ] 测试优雅关闭
- [ ] 测试超时处理
- [ ] 测试内存泄漏

## 六、实施步骤

### Phase 1: 基础进程管理 (第 1 天)
- [ ] 创建 ProcessManager.swift
- [ ] 实现 start/stop/restart
- [ ] 实现进程健康检查
- [ ] 单元测试

### Phase 2: stdio 通信 (第 1-2 天)
- [ ] 实现 write/readLine
- [ ] 实现 stderr 读取
- [ ] 异步 stdout 读取
- [ ] 错误处理

### Phase 3: 请求匹配 (第 2 天)
- [ ] 创建 RequestMatcher.swift
- [ ] 实现 sendRequest/handleResponse
- [ ] 实现超时机制
- [ ] 并发测试

### Phase 4: StdioMCPClient (第 2-3 天)
- [ ] 创建 StdioMCPClient.swift
- [ ] 集成 ProcessManager + RequestMatcher
- [ ] 实现 listTools/callTool
- [ ] 集成测试

### Phase 5: Workspace 进程池 (第 3 天)
- [ ] 创建 WorkspaceProcessPool.swift
- [ ] 实现进程创建和复用
- [ ] 实现进程清理
- [ ] 多 Workspace 测试

### Phase 6: 集成到 MCPRouter (第 3 天)
- [ ] 修改 MCPRouter.loadServers
- [ ] 修改 handleList/handleToolCall
- [ ] 支持 stdio 类型路由
- [ ] 端到端测试

### Phase 7: 优化和完善 (第 3-4 天)
- [ ] 进程崩溃自动重启
- [ ] 性能优化
- [ ] 日志管理
- [ ] 文档更新

## 七、风险和挑战

### 7.1 技术风险
| 风险 | 可能性 | 影响 | 缓解措施 |
|------|--------|------|---------|
| 进程僵尸/泄漏 | 中 | 高 | 实现完善的清理机制 |
| 并发竞争条件 | 中 | 高 | 使用 Actor 隔离 |
| 响应解析失败 | 高 | 中 | 完善错误处理 |
| 内存泄漏 | 中 | 中 | Instruments 检测 |

### 7.2 实施挑战
- **调试困难**: stdio 通信不可见,需要详细日志
- **错误恢复**: 进程崩溃后的状态恢复复杂
- **性能开销**: 每个 Workspace 独立进程,内存占用较高

## 八、验收标准

### 8.1 功能验收
- [ ] 成功启动 chrome-devtools Server
- [ ] tools/list 返回完整工具列表
- [ ] tools/call 正确调用工具
- [ ] 多个 Workspace 可以同时使用 stdio Server
- [ ] 进程崩溃后能自动重启
- [ ] 优雅关闭不会留下僵尸进程

### 8.2 性能验收
- [ ] 进程启动时间 < 3 秒
- [ ] 请求响应时间 < 1 秒
- [ ] 内存占用合理(每进程 < 200MB)
- [ ] 无内存泄漏

### 8.3 稳定性验收
- [ ] 连续运行 1 小时无崩溃
- [ ] 并发 10 个请求无问题
- [ ] 模拟进程崩溃能恢复

## 九、后续优化(可选)

### 9.1 进程复用优化
- 共享无状态的 stdio Server (如 filesystem)
- 只为有状态的 Server (如 chrome-devtools) 隔离进程

### 9.2 性能监控
- 进程 CPU/内存监控
- 请求响应时间统计
- 崩溃率统计

### 9.3 高级功能
- 进程资源限制 (CPU/内存上限)
- 进程日志查看界面
- 进程手动重启按钮

---

## 十、开始实施 Prompt

```
我需要为 MCP Router 添加 stdio 类型 MCP Server 支持。

背景:
- 当前只支持 HTTP 类型的 MCP Server
- 需要支持 stdio 类型(通过 stdin/stdout 通信)
- 典型场景: chrome-devtools, filesystem 等基于进程的 Server

核心要求:
1. 进程管理: 启动、停止、重启、健康检查
2. stdio 通信: 通过 stdin/stdout 进行 JSON-RPC 通信
3. 请求匹配: 异步请求/响应的 id 匹配
4. Workspace 隔离: 每个 Workspace 独立进程实例
5. 错误恢复: 进程崩溃自动重启

技术栈:
- Swift/SwiftUI
- Foundation.Process
- Actor 并发模型

请按照 `/Users/higuaifan/Desktop/hi/小工具/mcp-router/docs/04-stdio-implementation.md` 文档中的设计,分步骤实施:

Phase 1: 基础进程管理
- 创建 ProcessManager.swift
- 实现 start/stop/restart 方法
- 实现健康检查

请先从 Phase 1 开始实现,实现完成后我们再进行下一个 Phase。
```

---

**文档版本**: v1.0
**创建日期**: 2025-01-12
**预计完成时间**: 3-4 天
