//
//  ServerConfig.swift
//  mcp-router
//
//  MCP Server 配置模型
//

import Foundation
import SwiftData

@Model
final class ServerConfig {
    @Attribute(.unique) var id: UUID
    var name: String
    var type: ServerType
    var serverDescription: String
    var isEnabled: Bool  // 是否启用

    // HTTP 类型配置
    var url: String?
    var headers: [String: String]

    // stdio 类型配置 (暂不实现)
    var command: String?
    var args: [String]
    var env: [String: String]

    init(
        id: UUID = UUID(),
        name: String,
        type: ServerType,
        description: String = "",
        url: String? = nil,
        headers: [String: String] = [:],
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        isEnabled: Bool = true  // 默认启用
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.serverDescription = description
        self.url = url
        self.headers = headers
        self.command = command
        self.args = args
        self.env = env
        self.isEnabled = isEnabled
    }
}

enum ServerType: String, Codable {
    case http
    case stdio
}
