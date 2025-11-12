//
//  Workspace.swift
//  mcp-router
//
//  Workspace 模型 - 管理不同项目的 MCP Server 组合
//

import Foundation
import SwiftData

@Model
final class Workspace {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var token: String  // 唯一标识,用于 HTTP Header 路由
    var name: String                        // Workspace 名称
    var projectPath: String?                // 项目路径(可选)
    var isDefault: Bool                     // 是否为默认 Workspace
    var createdAt: Date

    // Server 配置覆盖: serverName -> isEnabled
    // 只记录用户修改过的配置，未记录的跟随 Default Workspace
    var serverOverrides: [String: Bool]

    init(
        id: UUID = UUID(),
        token: String,
        name: String,
        projectPath: String? = nil,
        isDefault: Bool = false,
        serverOverrides: [String: Bool] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.token = token
        self.name = name
        self.projectPath = projectPath
        self.isDefault = isDefault
        self.serverOverrides = serverOverrides
        self.createdAt = createdAt
    }
}

// MARK: - Helpers

extension Workspace {
    /// 生成唯一 Token (UUID 前 8 位)
    static func generateToken() -> String {
        return UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
    }

    /// 校验 Token 唯一性
    static func validateTokenUnique(_ token: String, excluding workspaceId: UUID? = nil, context: ModelContext) throws -> Bool {
        var predicate: Predicate<Workspace>

        if let excludeId = workspaceId {
            predicate = #Predicate<Workspace> { workspace in
                workspace.token == token && workspace.id != excludeId
            }
        } else {
            predicate = #Predicate<Workspace> { workspace in
                workspace.token == token
            }
        }

        let descriptor = FetchDescriptor<Workspace>(predicate: predicate)
        let existing = try context.fetch(descriptor)

        if !existing.isEmpty {
            throw WorkspaceError.duplicateToken(token)
        }

        return true
    }

    /// 获取 Server 的有效状态
    func isServerEnabled(_ serverName: String, defaultWorkspace: Workspace?) -> Bool {
        // 如果有覆盖配置，使用覆盖值
        if let override = serverOverrides[serverName] {
            return override
        }

        // 否则跟随 Default Workspace
        if let defaultWs = defaultWorkspace {
            return defaultWs.serverOverrides[serverName] ?? true  // 默认启用
        }

        return true
    }

    /// 检查 Server 是否被用户修改过
    func isServerCustomized(_ serverName: String) -> Bool {
        return serverOverrides[serverName] != nil
    }

    /// 获取所有启用的 Server 名称列表
    func enabledServerNames(allServers: [ServerConfig], defaultWorkspace: Workspace?) -> [String] {
        return allServers.filter { server in
            isServerEnabled(server.name, defaultWorkspace: defaultWorkspace)
        }.map { $0.name }
    }
}

// MARK: - Errors

enum WorkspaceError: LocalizedError {
    case duplicateToken(String)
    case invalidToken
    case workspaceNotFound
    case defaultWorkspaceNotFound

    var errorDescription: String? {
        switch self {
        case .duplicateToken(let token):
            return "Token '\(token)' 已存在"
        case .invalidToken:
            return "无效的 Token 格式"
        case .workspaceNotFound:
            return "未找到 Workspace"
        case .defaultWorkspaceNotFound:
            return "未找到默认 Workspace"
        }
    }
}
