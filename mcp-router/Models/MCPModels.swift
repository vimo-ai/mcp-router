//
//  MCPModels.swift
//  mcp-router
//
//  MCP 协议相关数据模型
//

import Foundation

// MARK: - JSON-RPC

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: Int?
    let method: String
    let params: [String: AnyCodable]?

    init(id: Int? = nil, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: Int?
    let result: AnyCodable?
    let error: JSONRPCError?

    init(id: Int?, result: AnyCodable) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: Int?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }

    // 自定义编码,确保 result 和 error 互斥
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)

        if let error = error {
            try container.encode(error, forKey: .error)
        } else if let result = result {
            try container.encode(result, forKey: .result)
        }
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
}

// MARK: - MCP Protocol

struct MCPTool: Codable {
    let name: String
    let description: String
    let inputSchema: [String: AnyCodable]?
}

struct MCPToolsListResult: Codable {
    let tools: [MCPTool]
}

struct MCPInitializeResult: Codable {
    let protocolVersion: String
    let serverInfo: ServerInfo
    let capabilities: Capabilities

    struct ServerInfo: Codable {
        let name: String
        let version: String
    }

    struct Capabilities: Codable {
        let tools: [String: AnyCodable]?

        init() {
            self.tools = [:]
        }
    }
}

struct MCPToolCallParams: Codable {
    let name: String
    let arguments: [String: AnyCodable]
}

// MARK: - AnyCodable (支持动态 JSON)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
