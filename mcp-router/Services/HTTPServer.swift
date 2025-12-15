//
//  HTTPServer.swift
//  mcp-router
//
//  基于 Network.framework 的 HTTP 服务器
//  支持 HTTP/1.1 持久连接和并发请求处理
//
//  ⚡️ NIO 迁移指南：
//  ==================
//  当前实现适用于中小规模场景（<100 并发连接）
//  如果需要更高性能（>1000 并发连接），建议迁移到 SwiftNIO
//
//  性能对比（参考值）：
//  - Network.framework:  ~100-500 并发连接
//  - SwiftNIO:          ~10,000+ 并发连接
//
//  NIO 主要优势：
//  1. 事件驱动架构（EventLoop）- 更高效的 I/O 调度
//  2. 零拷贝 ByteBuffer - 减少内存分配和拷贝
//  3. Channel Pipeline - 模块化的协议处理
//  4. 背压控制 - 自动限流避免 OOM
//
//  迁移步骤：
//  1. 添加依赖：.package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0")
//  2. 替换 NWListener → ServerBootstrap
//  3. 替换 NWConnection → Channel
//  4. 实现 ChannelInboundHandler 处理 HTTP
//  5. 参考示例：https://github.com/apple/swift-nio-examples/tree/main/NIOHTTP1Server
//
//  关键 NIO 代码示例见各函数的 ⚡️ 注释
//

import Foundation
import Network

/// HTTP 服务器
///
/// 架构特点：
/// - 使用 Actor 隔离保证线程安全
/// - 每个连接独立 Task 处理，支持多客户端并发
/// - 单个连接内使用 TaskGroup 并发处理多个请求
/// - 支持 HTTP/1.1 持久连接（keep-alive）
///
/// ⚡️ NIO 优化点：
/// Actor 模型适合业务逻辑隔离，但对于高并发 I/O 场景不如 NIO 的 EventLoop
/// NIO 的 EventLoop 是单线程非阻塞模型，减少了线程切换和锁竞争：
/// ```swift
/// let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
/// let bootstrap = ServerBootstrap(group: group)
///     .serverChannelOption(ChannelOptions.backlog, value: 256)
///     .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
/// ```
actor HTTPServer {
    let port: UInt16
    let router: MCPRouter
    private var listener: NWListener?

    // Session 管理：存储每个连接的会话 ID
    private var sessions: [String: Date] = [:]  // sessionId -> 创建时间

    init(port: UInt16 = 3000, router: MCPRouter) {
        self.port = port
        self.router = router
    }

    /// 生成新的会话 ID
    private func generateSessionId() -> String {
        return UUID().uuidString
    }

    /// 验证会话 ID 是否有效
    private func validateSession(_ sessionId: String?) -> Bool {
        guard let sessionId = sessionId else { return false }
        return sessions[sessionId] != nil
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

    // MARK: - 连接处理（支持持久连接和并发请求）

    /// 处理单个 TCP 连接，支持 HTTP/1.1 持久连接
    ///
    /// ⚡️ NIO 优化点：
    /// 当前使用 AsyncStream + TaskGroup 实现并发请求处理
    /// 如需更高性能，可迁移到 NIO 的 ChannelPipeline：
    /// ```swift
    /// bootstrap.childChannelInitializer { channel in
    ///     channel.pipeline.addHandlers([
    ///         HTTPRequestDecoder(),
    ///         HTTPResponseEncoder(),
    ///         MCPRequestHandler()  // 自定义 ChannelInboundHandler
    ///     ])
    /// }
    /// ```
    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .main)

        // ✅ 使用 AsyncStream 将回调式 API 转换为异步序列
        let dataStream = connection.dataStream()

        // ✅ 使用 TaskGroup 并发处理同一连接上的多个请求
        // 这样可以避免某个慢请求阻塞后续请求
        await withTaskGroup(of: Void.self) { group in
            for await data in dataStream {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    await self.processRequest(data: data, connection: connection)
                }
            }
        }

        connection.cancel()
    }

    // MARK: - 请求处理

    /// 处理单个 HTTP 请求
    ///
    /// ⚡️ NIO 优化点：
    /// 当前手动解析 HTTP 协议（字符串分割），效率较低且容易出错
    /// 使用 NIO 可以：
    /// ```swift
    /// // 使用内置的 HTTPRequestDecoder 自动解析
    /// channel.pipeline.addHandler(HTTPRequestDecoder())
    /// // 在 ChannelInboundHandler 中接收已解析的 HTTPServerRequestPart
    /// func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    ///     let reqPart = unwrapInboundIn(data)
    ///     switch reqPart {
    ///     case .head(let header):  // 已解析的请求头
    ///     case .body(let buffer):  // 已解析的请求体
    ///     }
    /// }
    /// ```
    /// 好处：零拷贝解析、自动处理分块传输、流式处理大文件
    private func processRequest(data: Data, connection: NWConnection) async {
        print("📦 收到数据: \(data.count) 字节")

        // 解析 HTTP 请求
        guard let requestString = String(data: data, encoding: .utf8) else {
            print("❌ 无法解码请求数据")
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        // 🔍 调试：打印原始请求内容（前 200 字符）
        let preview = String(requestString.prefix(200))
        print("📄 请求内容预览: \(preview)")
        if requestString.count > 200 {
            print("   ... (还有 \(requestString.count - 200) 字符)")
        }

        // 分离 Header 和 Body
        let components = requestString.components(separatedBy: "\r\n\r\n")
        guard components.count >= 1 else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        // 提取请求行（第一行）
        let headerLines = components[0].components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        // 解析 HTTP 方法（GET/POST/DELETE）
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        let httpMethod = String(requestParts[0])
        let path = String(requestParts[1])

        print("🔹 HTTP 方法: \(httpMethod), 路径: \(path)")

        // 提取 Headers（规范化 key 为小写，便于查找）
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {  // 跳过第一行(请求行)
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // 根据 HTTP 方法分发处理
        switch httpMethod {
        case "POST":
            await handlePostRequest(components: components, headers: headers, connection: connection)

        case "GET":
            await handleGetRequest(path: path, headers: headers, connection: connection)

        case "DELETE":
            await handleDeleteRequest(headers: headers, connection: connection)

        default:
            print("❌ 不支持的 HTTP 方法: \(httpMethod)")
            sendResponse(connection: connection, statusCode: 405, body: "Method Not Allowed")
        }
    }

    // MARK: - POST 请求处理（JSON-RPC）

    private func handlePostRequest(components: [String], headers: [String: String], connection: NWConnection) async {
        // 提取 Body
        guard components.count > 1 else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request: No body")
            return
        }

        let bodyString = components[1]
        guard let bodyData = bodyString.data(using: .utf8) else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request: Invalid body encoding")
            return
        }

        // 处理 JSON-RPC 请求
        // 尝试提取请求 id（用于错误响应）
        let requestId: Int? = {
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let id = json["id"] as? Int {
                return id
            }
            return nil
        }()

        do {
            let jsonRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: bodyData)

            // 检查是否为通知(notification): id 为 nil 或 method 以 "notifications/" 开头
            let isNotification = jsonRequest.id == nil || jsonRequest.method.hasPrefix("notifications/")

            if isNotification {
                // 通知不需要响应,直接处理并返回 202 Accepted
                print("📬 处理通知: \(jsonRequest.method)")

                let sessionId = headers["mcp-session-id"]
                _ = try? await handleJSONRPC(request: jsonRequest, headers: headers, sessionId: sessionId)

                sendResponse(
                    connection: connection,
                    statusCode: 202,  // ✅ 规范要求返回 202 Accepted
                    body: "",
                    contentType: "application/json"
                )
                print("✅ 通知响应已发送 (202)")
            } else {
                // 普通请求需要返回响应
                print("📬 处理请求: \(jsonRequest.method)")

                let sessionId = headers["mcp-session-id"]
                let (result, newSessionId) = try await handleJSONRPC(request: jsonRequest, headers: headers, sessionId: sessionId)

                let response = JSONRPCResponse(id: jsonRequest.id, result: result)
                let responseData = try JSONEncoder().encode(response)
                let responseString = String(data: responseData, encoding: .utf8)!

                sendResponse(
                    connection: connection,
                    statusCode: 200,
                    body: responseString,
                    contentType: "application/json",
                    sessionId: newSessionId  // ✅ 在 initialize 响应中返回 Session ID
                )
                print("✅ 请求响应已发送 (200)")
            }
        } catch {
            // ✅ 使用请求的 id，而不是 nil（符合 JSON-RPC 2.0 规范）
            // 如果无法解析请求，id 才使用 nil
            let errorResponse = JSONRPCResponse(
                id: requestId,
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

    // MARK: - GET 请求处理（SSE 流）

    /// 处理 GET 请求，建立 SSE 流用于服务器推送
    ///
    /// ⚡️ NIO 优化点：
    /// 当前实现返回空的 SSE 流（服务器不主动推送）
    /// 完整实现需要：
    /// ```swift
    /// // 1. 保持连接不关闭
    /// // 2. 当有事件时，发送 SSE 格式的数据：
    /// data: {"jsonrpc":"2.0","method":"notifications/...","params":{...}}\n\n
    /// // 3. 使用 NIO 的 EventLoop 调度事件推送
    /// ```
    private func handleGetRequest(path: String, headers: [String: String], connection: NWConnection) async {
        let sessionId = headers["mcp-session-id"]

        print("📡 GET 请求: 路径=\(path), Session=\(sessionId ?? "无")")

        // 验证 Session ID
        if let sessionId = sessionId, validateSession(sessionId) {
            print("✅ SSE 流请求，Session 有效")

            // 返回 SSE 流响应头
            // 注意：这里我们返回空流，因为当前不需要服务器主动推送
            // 如果将来需要推送，需要保持连接并定期发送事件
            sendResponse(
                connection: connection,
                statusCode: 200,
                body: "",  // SSE 流可以为空
                contentType: "text/event-stream",
                keepAlive: false,  // 暂时关闭，因为我们不推送事件
                sessionId: sessionId
            )
        } else {
            print("⚠️ SSE 流请求，但 Session 无效或不存在")
            // 返回 404 表示会话不存在，客户端需要重新初始化
            sendResponse(connection: connection, statusCode: 404, body: "Session not found")
        }
    }

    // MARK: - DELETE 请求处理（关闭会话）

    /// 处理 DELETE 请求，关闭会话
    private func handleDeleteRequest(headers: [String: String], connection: NWConnection) async {
        let sessionId = headers["mcp-session-id"]

        print("🗑️  DELETE 请求: Session=\(sessionId ?? "无")")

        if let sessionId = sessionId, sessions[sessionId] != nil {
            // 删除会话
            sessions.removeValue(forKey: sessionId)
            print("✅ 会话已删除: \(sessionId)")

            sendResponse(
                connection: connection,
                statusCode: 200,
                body: "",
                keepAlive: false  // 关闭连接
            )
        } else {
            print("⚠️ 尝试删除不存在的会话")
            // 即使会话不存在也返回 200（幂等性）
            sendResponse(
                connection: connection,
                statusCode: 200,
                body: "",
                keepAlive: false
            )
        }
    }

    private func handleJSONRPC(
        request: JSONRPCRequest,
        headers: [String: String],
        sessionId: String?
    ) async throws -> (result: AnyCodable, sessionId: String?) {
        // 提取 Workspace Token
        let token = headers["x-workspace-token"]

        await MainActor.run {
            print("📨 收到请求: \(request.method)")
            if let token = token {
                print("🔑 Workspace Token: \(token)")
            }
            if let sessionId = sessionId {
                print("🔑 Session ID: \(sessionId)")
            }
        }

        // 查找对应的 Workspace
        let workspace = await router.findWorkspace(byToken: token)

        switch request.method {
        case "initialize":
            // ✅ 生成新的 Session ID
            let newSessionId = generateSessionId()
            sessions[newSessionId] = Date()
            print("🆕 创建新会话: \(newSessionId)")

            let result = AnyCodable([
                "protocolVersion": "2024-11-05",
                "serverInfo": [
                    "name": "mcp-router",
                    "version": "0.1.0"
                ],
                "capabilities": [
                    "tools": [:]
                ]
            ] as [String: Any])

            return (result, newSessionId)

        case "notifications/initialized":
            // ✅ 验证 Session ID
            if let sessionId = sessionId, validateSession(sessionId) {
                print("✅ 会话已初始化: \(sessionId)")
            } else {
                print("⚠️ 无效的会话 ID")
            }
            // 不需要返回
            return (AnyCodable([:]), nil)

        case "tools/list":
            // 根据 Workspace 返回对应的工具列表
            let routerTools = await router.generateRouterTools(for: workspace)

            // 获取平铺的 tools
            let flattenedTools = await router.getFlattenedTools(for: workspace)

            // 合并：meta tools + 平铺 tools
            let allTools = routerTools + flattenedTools

            await MainActor.run {
                if let ws = workspace {
                    print("📋 返回 Workspace '\(ws.name)' 的 \(routerTools.count) 个元工具 + \(flattenedTools.count) 个平铺工具")
                } else {
                    print("📋 返回默认的 \(routerTools.count) 个元工具 + \(flattenedTools.count) 个平铺工具")
                }
            }

            // 转换为字典数组
            let toolDicts = allTools.map { tool -> [String: Any] in
                var dict: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description
                ]
                if let schema = tool.inputSchema {
                    dict["inputSchema"] = schema.mapValues { $0.value }
                }
                return dict
            }
            return (AnyCodable(["tools": toolDicts]), nil)

        case "tools/call":
            guard let params = request.params,
                  let toolName = params["name"]?.value as? String else {
                throw MCPError.toolNotFound("Missing tool name")
            }

            let arguments = (params["arguments"]?.value as? [String: Any])?.mapValues { AnyCodable($0) } ?? [:]

            // Router 自身的元工具直接调用；其他工具统一走 mcp_router__call 以使用安全名映射
            if toolName.hasPrefix("mcp_router__") {
                let result = try await router.handleToolCall(name: toolName, arguments: arguments, workspace: workspace)
                return (result, nil)
            }

            let callArgs: [String: AnyCodable] = [
                "tool": AnyCodable(toolName),
                "arguments": AnyCodable(arguments.mapValues { $0.value })
            ]
            let result = try await router.handleToolCall(name: "mcp_router__call", arguments: callArgs, workspace: workspace)
            return (result, nil)


        default:
            throw MCPError.rpcError(-32601, "Method not found: \(request.method)")
        }
    }

    // MARK: - HTTP 响应发送

    /// 发送 HTTP 响应
    ///
    /// ⚡️ NIO 优化点：
    /// 当前使用字符串拼接构建 HTTP 响应，会产生额外的内存拷贝
    /// 使用 NIO 可以：
    /// ```swift
    /// var buffer = channel.allocator.buffer(capacity: 1024)
    /// buffer.writeString("HTTP/1.1 200 OK\r\n")
    /// buffer.writeString("Content-Length: \(body.count)\r\n")
    /// channel.writeAndFlush(HTTPServerResponsePart.head(responseHead))
    /// channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
    /// ```
    /// 避免了 String → Data 的转换开销
    private func sendResponse(
        connection: NWConnection,
        statusCode: Int,
        body: String,
        contentType: String = "text/plain",
        keepAlive: Bool = true,  // ✅ 默认启用持久连接
        sessionId: String? = nil  // ✅ 可选的 Session ID（用于 initialize 响应）
    ) {
        let connectionHeader = keepAlive ? "keep-alive" : "close"

        // ✅ 构建响应头，如果有 Session ID 则添加 Mcp-Session-Id 头
        var headerLines = [
            "HTTP/1.1 \(statusCode) OK",
            "Content-Type: \(contentType); charset=utf-8",
            "Content-Length: \(body.utf8.count)",
            "Connection: \(connectionHeader)"
        ]

        if let sessionId = sessionId {
            headerLines.append("Mcp-Session-Id: \(sessionId)")
            print("📤 返回 Session ID: \(sessionId)")
        }

        let responseString = headerLines.joined(separator: "\r\n") + "\r\n\r\n" + body

        if let responseData = responseString.data(using: .utf8) {
            connection.send(content: responseData, completion: .contentProcessed { error in
                if let error = error {
                    print("⚠️ 发送响应失败: \(error)")
                }
                // ✅ 只有在 keep-alive = false 时才关闭连接
                if !keepAlive {
                    connection.cancel()
                }
            })
        }
    }
}

// MARK: - NWConnection AsyncStream 扩展

/// 为 NWConnection 提供 AsyncStream 支持，将回调式 API 转换为异步序列
///
/// ⚡️ NIO 优化点：
/// NIO 原生支持异步序列，不需要手动封装：
/// ```swift
/// for try await inbound in channel.inboundStream {
///     // 直接处理入站数据
/// }
/// ```
extension NWConnection {
    /// 创建一个异步数据流，持续接收数据直到连接关闭
    ///
    /// - Returns: 异步数据流
    func dataStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            // 递归调度接收函数
            // 注意：这里的递归是在闭包内部，不会造成调用栈累积
            func scheduleReceive() {
                self.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    data, _, isComplete, error in

                    // 发生错误，终止流
                    if let error = error {
                        print("📡 连接错误: \(error)")
                        continuation.finish()
                        return
                    }

                    // 收到数据，yield 给消费者
                    if let data = data, !data.isEmpty {
                        continuation.yield(data)
                    }

                    // ⚠️ 重要：isComplete 只表示"本次读取完成"，不代表连接关闭
                    // 只有在没有数据且 isComplete = true 时，才可能是 FIN 包（连接关闭）
                    if isComplete && (data == nil || data!.isEmpty) {
                        print("📡 客户端关闭连接 (收到 FIN)")
                        continuation.finish()
                    } else {
                        // 继续接收下一批数据
                        scheduleReceive()
                    }
                }
            }

            scheduleReceive()

            // 当 AsyncStream 被取消时的清理逻辑
            continuation.onTermination = { @Sendable termination in
                switch termination {
                case .cancelled:
                    print("📡 数据流被取消")
                case .finished:
                    print("📡 数据流正常结束")
                @unknown default:
                    break
                }
            }
        }
    }
}
