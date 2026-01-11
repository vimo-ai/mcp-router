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

    // 是否启用平铺模式（直接暴露 tools 给 AI）
    // 使用可选类型以支持从旧版本迁移
    private var _flattenMode: Bool?

    /// 是否启用平铺模式
    var flattenMode: Bool {
        get { _flattenMode ?? false }
        set { _flattenMode = newValue }
    }

    // HTTP 类型配置
    var url: String?
    var headers: [String: String]

    // stdio 类型配置
    var command: String?
    var args: [String]
    var env: [String: String]

    // stdio 协议类型（使用可选类型以支持从旧版本迁移）
    private var _stdioProtocol: StdioProtocol?

    /// stdio 通信协议
    var stdioProtocol: StdioProtocol {
        get { _stdioProtocol ?? .line }
        set { _stdioProtocol = newValue }
    }

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
        isEnabled: Bool = true,
        flattenMode: Bool = false,
        stdioProtocol: StdioProtocol = .line
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
        self._flattenMode = flattenMode
        self._stdioProtocol = stdioProtocol
    }
}

enum ServerType: String, Codable {
    case http
    case stdio
}

/// stdio 服务器的通信协议
enum StdioProtocol: String, Codable {
    /// 按行分隔的 JSON (JSON\n) - 默认，兼容大多数 MCP server
    case line
    /// Content-Length header 格式 (Content-Length: N\r\n\r\nJSON) - 标准 MCP/LSP 协议
    case contentLength
}
