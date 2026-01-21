//
//  MCPModels.swift
//  mcp-router
//
//  MCP 协议相关数据模型
//

import Foundation

// MARK: - JSON-RPC

struct JSONRPCRequest: Codable, @unchecked Sendable {
    let jsonrpc: String
    let id: Int?
    let method: String
    let params: [String: AnyCodable]?

    nonisolated init(id: Int? = nil, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent([String: AnyCodable].self, forKey: .params)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }
}

struct JSONRPCResponse: Codable, @unchecked Sendable {
    let jsonrpc: String
    let id: Int?
    let result: AnyCodable?
    let error: JSONRPCError?

    nonisolated init(id: Int?, result: AnyCodable) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    nonisolated init(id: Int?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        result = try container.decodeIfPresent(AnyCodable.self, forKey: .result)
        error = try container.decodeIfPresent(JSONRPCError.self, forKey: .error)
    }

    // 自定义编码,确保 result 和 error 互斥
    nonisolated func encode(to encoder: Encoder) throws {
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

struct JSONRPCError: Codable, Sendable {
    let code: Int
    let message: String
}

// MARK: - MCP Protocol

struct MCPTool: Codable, @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: AnyCodable]?

    nonisolated init(name: String, description: String, inputSchema: [String: AnyCodable]? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        inputSchema = try container.decodeIfPresent([String: AnyCodable].self, forKey: .inputSchema)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(inputSchema, forKey: .inputSchema)
    }

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }
}

struct MCPToolsListResult: Codable, @unchecked Sendable {
    let tools: [MCPTool]

    nonisolated init(tools: [MCPTool]) {
        self.tools = tools
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tools = try container.decode([MCPTool].self, forKey: .tools)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tools, forKey: .tools)
    }

    enum CodingKeys: String, CodingKey {
        case tools
    }
}

struct MCPInitializeResult: Codable, @unchecked Sendable {
    let protocolVersion: String
    let serverInfo: ServerInfo
    let capabilities: Capabilities

    struct ServerInfo: Codable, Sendable {
        let name: String
        let version: String
    }

    struct Capabilities: Codable, @unchecked Sendable {
        let tools: [String: AnyCodable]?

        init() {
            self.tools = [:]
        }
    }
}

struct MCPToolCallParams: Codable, @unchecked Sendable {
    let name: String
    let arguments: [String: AnyCodable]
}

// MARK: - AnyCodable (支持动态 JSON)

struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    nonisolated init(_ value: Any) {
        self.value = value
    }

    nonisolated init(from decoder: Decoder) throws {
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

    nonisolated func encode(to encoder: Encoder) throws {
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
