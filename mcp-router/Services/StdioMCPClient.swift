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

    /// 启动超时时间（秒）
    private static let startTimeoutSeconds: UInt64 = 10

    /// 启动客户端（带超时保护）
    func start() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.doStart()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.startTimeoutSeconds * 1_000_000_000)
                throw MCPError.timeout
            }
            // 第一个完成的 task 决定结果，取消另一个
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                // 如果是超时，停止已启动的进程
                if case MCPError.timeout = error {
                    print("⏰ 启动超时 (\(Self.startTimeoutSeconds)s): \(config.name)")
                    await processManager.stop()
                }
                throw error
            }
        }
    }

    /// 实际启动逻辑
    private func doStart() async throws {
        // 启动进程
        try await processManager.start()

        try Task.checkCancellation()

        // 启动 stdout 读取任务
        startOutputReader()

        // 给读取任务一点时间启动
        try await Task.sleep(nanoseconds: 100_000_000)

        try Task.checkCancellation()

        // 执行 MCP initialize 握手（sendRequest 内部有 30s 超时，但外层 start 整体 10s 限制更严）
        try await performInitialize()
    }

    /// 执行 MCP initialize 握手
    private func performInitialize() async throws {
        // 1. 发送 initialize 请求
        let initParams: [String: AnyCodable] = [
            "protocolVersion": AnyCodable("2024-11-05"),
            "capabilities": AnyCodable([:] as [String: Any]),
            "clientInfo": AnyCodable([
                "name": "mcp-router",
                "version": "1.0.0"
            ] as [String: Any])
        ]

        let result = try await requestMatcher.sendRequest(
            processManager: processManager,
            method: "initialize",
            params: initParams
        )

        // 2. 发送 initialized 通知
        let notification = """
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        """
        try await processManager.write(notification)
    }

    /// 停止客户端
    func stop() async {
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
                    // 根据协议类型读取消息
                    guard let message = try await processManager.readMessage() else {
                        // 进程已关闭
                        break
                    }

                    // 跳过空消息
                    let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedMessage.isEmpty {
                        continue
                    }

                    // 解析 JSON-RPC 响应
                    if let data = trimmedMessage.data(using: .utf8),
                       let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) {
                        Task { await self.requestMatcher.handleResponse(response) }
                    }
                } catch {
                    if !Task.isCancelled {
                        break
                    }
                }
            }
        }
    }
}
