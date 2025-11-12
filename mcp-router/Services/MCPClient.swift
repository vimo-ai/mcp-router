//
//  MCPClient.swift
//  mcp-router
//
//  MCP Client - 负责与单个 MCP Server 通信
//

import Foundation

actor MCPClient {
    let config: ServerConfig
    private var requestID: Int = 0
    private var toolsCache: [MCPTool]?

    init(config: ServerConfig) {
        self.config = config
    }

    // MARK: - Public Methods

    /// 获取工具列表（带缓存）
    func listTools() async throws -> [MCPTool] {
        if let cached = toolsCache {
            return cached
        }

        do {
            let result = try await sendRequest(method: "tools/list", params: nil)
            let toolsResult = try JSONDecoder().decode(
                MCPToolsListResult.self,
                from: JSONSerialization.data(withJSONObject: result.value)
            )

            toolsCache = toolsResult.tools
            print("✅ \(config.name): 成功加载 \(toolsResult.tools.count) 个工具")
            return toolsResult.tools
        } catch {
            print("❌ \(config.name): 加载工具失败 - \(error)")
            throw error
        }
    }

    /// 调用工具
    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> AnyCodable {
        let params: [String: AnyCodable] = [
            "name": AnyCodable(name),
            "arguments": AnyCodable(arguments.mapValues { $0.value })
        ]

        return try await sendRequest(method: "tools/call", params: params)
    }

    // MARK: - Private Methods

    private func sendRequest(method: String, params: [String: AnyCodable]?) async throws -> AnyCodable {
        switch config.type {
        case .http:
            return try await sendHTTPRequest(method: method, params: params)
        case .stdio:
            throw MCPError.unsupportedServerType("stdio not yet implemented")
        }
    }

    private func sendHTTPRequest(method: String, params: [String: AnyCodable]?) async throws -> AnyCodable {
        guard let urlString = config.url, let url = URL(string: urlString) else {
            throw MCPError.invalidURL
        }

        requestID += 1

        let request = JSONRPCRequest(id: requestID, method: method, params: params)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Context7 要求必须接受 SSE
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        // 添加自定义 headers
        for (key, value) in config.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("❌ HTTP Error: \(statusCode)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("Response: \(responseString)")
            }
            throw MCPError.httpError(statusCode)
        }

        // 调试：打印原始响应
        if let responseString = String(data: data, encoding: .utf8) {
            print("📥 \(config.name) 响应: \(responseString.prefix(500))")
        }

        let jsonResponse = try JSONDecoder().decode(JSONRPCResponse.self, from: data)

        if let error = jsonResponse.error {
            print("❌ RPC Error: \(error)")
            throw MCPError.rpcError(error.code, error.message)
        }

        guard let result = jsonResponse.result else {
            print("❌ Empty response")
            throw MCPError.emptyResponse
        }

        return result
    }
}

// MARK: - Errors

enum MCPError: LocalizedError {
    case invalidURL
    case unsupportedServerType(String)
    case httpError(Int)
    case rpcError(Int, String)
    case emptyResponse
    case toolNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .unsupportedServerType(let type):
            return "Unsupported server type: \(type)"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .rpcError(let code, let message):
            return "RPC error \(code): \(message)"
        case .emptyResponse:
            return "Empty response from server"
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        }
    }
}
