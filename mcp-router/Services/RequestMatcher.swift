//
//  RequestMatcher.swift
//  mcp-router
//
//  stdio MCP Server 请求/响应匹配器
//

import Foundation

actor RequestMatcher {
    private var pendingRequests: [Int: CheckedContinuation<AnyCodable, Error>] = [:]
    private var nextRequestID: Int = 1

    /// 发送请求并等待响应
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

        print("📤 发送请求 [id:\(requestID)] \(method)")

        // 写入 stdin
        try await processManager.write(requestString)

        // 等待响应
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation

            // 设置超时(30秒)
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let pending = pendingRequests.removeValue(forKey: requestID) {
                    print("⏰ 请求超时 [id:\(requestID)] \(method)")
                    pending.resume(throwing: MCPError.timeout)
                }
            }
        }
    }

    /// 处理接收到的响应
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
            print("❌ RPC 错误 [id:\(id)] \(error.code): \(error.message)")
            continuation.resume(throwing: MCPError.rpcError(error.code, error.message))
        } else if let result = response.result {
            print("✅ 收到响应 [id:\(id)]")
            continuation.resume(returning: result)
        } else {
            print("❌ 无效响应 [id:\(id)]")
            continuation.resume(throwing: MCPError.invalidResponse)
        }
    }

    /// 清理所有待处理请求
    func cancelAll() {
        for (id, continuation) in pendingRequests {
            print("🚫 取消请求 [id:\(id)]")
            continuation.resume(throwing: MCPError.cancelled)
        }
        pendingRequests.removeAll()
    }
}
