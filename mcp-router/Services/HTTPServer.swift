//
//  HTTPServer.swift
//  mcp-router
//
//  基于 URLSession 的简单 HTTP 服务器（用于测试）
//  生产环境建议使用 Vapor
//

import Foundation
import Network

actor HTTPServer {
    let port: UInt16
    let router: MCPRouter
    private var listener: NWListener?

    init(port: UInt16 = 3000, router: MCPRouter) {
        self.port = port
        self.router = router
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))

        self.listener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("🚀 MCP Router HTTP 服务运行在 http://localhost:\(self.port)")
            case .failed(let error):
                print("❌ HTTP 服务启动失败: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleConnection(connection)
            }
        }

        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .main)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }

            Task {
                await self.processRequest(data: data, connection: connection)
            }
        }
    }

    private func processRequest(data: Data, connection: NWConnection) async {
        // 解析 HTTP 请求
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        // 分离 Header 和 Body
        let components = requestString.components(separatedBy: "\r\n\r\n")
        guard components.count > 1 else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        // 提取 Headers
        let headerLines = components[0].components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {  // 跳过第一行(请求行)
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // 提取 Body
        let bodyString = components[1]
        guard let bodyData = bodyString.data(using: .utf8) else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        // 处理 JSON-RPC 请求
        do {
            let jsonRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: bodyData)

            // 检查是否为通知(notification): id 为 nil 或 method 以 "notifications/" 开头
            let isNotification = jsonRequest.id == nil || jsonRequest.method.hasPrefix("notifications/")

            if isNotification {
                // 通知不需要响应,直接处理并返回 204 No Content
                _ = try? await handleJSONRPC(request: jsonRequest, headers: headers)
                sendResponse(
                    connection: connection,
                    statusCode: 204,
                    body: "",
                    contentType: "application/json"
                )
            } else {
                // 普通请求需要返回响应
                let result = try await handleJSONRPC(request: jsonRequest, headers: headers)
                let response = JSONRPCResponse(id: jsonRequest.id, result: result)
                let responseData = try JSONEncoder().encode(response)
                let responseString = String(data: responseData, encoding: .utf8)!

                sendResponse(
                    connection: connection,
                    statusCode: 200,
                    body: responseString,
                    contentType: "application/json"
                )
            }
        } catch {
            let errorResponse = JSONRPCResponse(
                id: nil,
                error: JSONRPCError(code: -32603, message: error.localizedDescription)
            )

            if let responseData = try? JSONEncoder().encode(errorResponse),
               let responseString = String(data: responseData, encoding: .utf8) {
                sendResponse(
                    connection: connection,
                    statusCode: 200,
                    body: responseString,
                    contentType: "application/json"
                )
            } else {
                sendResponse(connection: connection, statusCode: 500, body: "Internal Server Error")
            }
        }
    }

    private func handleJSONRPC(request: JSONRPCRequest, headers: [String: String]) async throws -> AnyCodable {
        // 提取 Workspace Token
        let token = headers["X-Workspace-Token"]

        await MainActor.run {
            print("📨 收到请求: \(request.method)")
            if let token = token {
                print("🔑 Workspace Token: \(token)")
            }
        }

        // 查找对应的 Workspace
        let workspace = await router.findWorkspace(byToken: token)

        switch request.method {
        case "initialize":
            return AnyCodable([
                "protocolVersion": "2024-11-05",
                "serverInfo": [
                    "name": "mcp-router",
                    "version": "0.1.0"
                ],
                "capabilities": [
                    "tools": [:]
                ]
            ] as [String: Any])

        case "notifications/initialized":
            // 不需要返回
            return AnyCodable([:])

        case "tools/list":
            // 根据 Workspace 返回对应的工具列表
            let routerTools = await router.generateRouterTools(for: workspace)

            await MainActor.run {
                if let ws = workspace {
                    print("📋 返回 Workspace '\(ws.name)' 的 \(routerTools.count) 个元工具")
                } else {
                    print("📋 返回默认的 \(routerTools.count) 个元工具")
                }
            }

            // 转换为字典数组
            let toolDicts = routerTools.map { tool -> [String: Any] in
                var dict: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description
                ]
                if let schema = tool.inputSchema {
                    dict["inputSchema"] = schema.mapValues { $0.value }
                }
                return dict
            }
            return AnyCodable(["tools": toolDicts])

        case "tools/call":
            guard let params = request.params,
                  let toolName = params["name"]?.value as? String else {
                throw MCPError.toolNotFound("Missing tool name")
            }

            let arguments = (params["arguments"]?.value as? [String: Any])?.mapValues { AnyCodable($0) } ?? [:]

            return try await router.handleToolCall(name: toolName, arguments: arguments, workspace: workspace)

        default:
            throw MCPError.rpcError(-32601, "Method not found: \(request.method)")
        }
    }

    private func sendResponse(
        connection: NWConnection,
        statusCode: Int,
        body: String,
        contentType: String = "text/plain"
    ) {
        let responseString = """
        HTTP/1.1 \(statusCode) OK\r
        Content-Type: \(contentType); charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        if let responseData = responseString.data(using: .utf8) {
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
