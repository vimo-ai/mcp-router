//
//  WorkspaceProcessPool.swift
//  mcp-router
//
//  Workspace 进程池管理
//

import Foundation

actor WorkspaceProcessPool {
    // workspace.token -> StdioMCPClient
    private var processes: [String: StdioMCPClient] = [:]

    /// 获取或创建 Workspace 的进程
    func getOrCreateClient(
        workspaceToken: String,
        config: ServerConfig
    ) async throws -> StdioMCPClient {
        // 生成唯一 key: workspaceToken + serverName
        let key = "\(workspaceToken):\(config.name)"

        if let existing = processes[key] {
            // 检查进程是否存活
            if await existing.isHealthy() {
                return existing
            } else {
                // 进程已死,移除并重新创建
                print("⚠️ 检测到进程已死,重新创建: \(config.name)")
                await existing.stop()
                processes.removeValue(forKey: key)
            }
        }

        // 创建新进程
        let client = StdioMCPClient(config: config)
        try await client.start()

        processes[key] = client
        print("✅ 为 Workspace \(workspaceToken) 创建进程: \(config.name)")

        return client
    }

    /// 释放 Workspace 的进程
    func releaseClient(workspaceToken: String, serverName: String) async {
        let key = "\(workspaceToken):\(serverName)"

        guard let client = processes.removeValue(forKey: key) else {
            return
        }

        await client.stop()
        print("🛑 释放 Workspace \(workspaceToken) 的进程: \(serverName)")
    }

    /// 清理所有进程
    func cleanup() async {
        for (key, client) in processes {
            await client.stop()
            print("🛑 清理进程: \(key)")
        }
        processes.removeAll()
    }

    /// 获取当前进程数量
    func count() -> Int {
        return processes.count
    }
}
