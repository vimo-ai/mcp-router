//
//  StdioMCPClient.swift
//  mcp-router
//
//  stdio MCP Server 客户端
//

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

    // MARK: - Lifecycle

    /// 启动客户端
    func start() async throws {
        // 启动进程
        try await processManager.start()

        // 启动 stdout 读取任务
        startOutputReader()

        // 等待进程准备好
        try await Task.sleep(nanoseconds: 500_000_000)

        print("✅ StdioMCPClient 启动完成: \(config.name)")
    }

    /// 停止客户端
    func stop() async {
        print("🛑 停止 StdioMCPClient: \(config.name)")

        outputReaderTask?.cancel()
        await requestMatcher.cancelAll()
        await processManager.stop()
    }

    /// 检查客户端是否健康
    func isHealthy() async -> Bool {
        return await processManager.isAlive()
    }

    // MARK: - MCP Methods

    /// 获取工具列表
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

    /// 调用工具
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

    // MARK: - Private

    /// 启动 stdout 读取任务
    private func startOutputReader() {
        outputReaderTask = Task {
            while !Task.isCancelled {
                do {
                    // 读取一行
                    guard let line = try await processManager.readLine() else {
                        // 进程已关闭
                        print("📤 进程已关闭,停止读取: \(config.name)")
                        break
                    }

                    // 跳过空行
                    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedLine.isEmpty {
                        continue
                    }

                    print("📥 收到输出: \(trimmedLine.prefix(100))")

                    // 解析 JSON-RPC 响应
                    if let data = trimmedLine.data(using: .utf8) {
                        do {
                            let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
                            await requestMatcher.handleResponse(response)
                        } catch {
                            print("⚠️ 解析响应失败: \(error)")
                            print("   原始数据: \(trimmedLine)")
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        print("❌ 读取 stdout 失败: \(error)")
                    }
                    break
                }
            }

            print("📤 stdout 读取任务已停止: \(config.name)")
        }
    }
}
