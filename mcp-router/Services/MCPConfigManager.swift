//
//  MCPConfigManager.swift
//  mcp-router
//
//  处理 .mcp.json 文件的读写和合并
//

import Foundation

struct MCPConfigManager {
    /// 检查项目目录下是否存在 .mcp.json
    static func configFileExists(at projectPath: URL) -> Bool {
        let configPath = projectPath.appendingPathComponent(".mcp.json")
        return FileManager.default.fileExists(atPath: configPath.path)
    }

    /// 读取 .mcp.json 配置
    static func readConfig(at projectPath: URL) throws -> [String: Any] {
        let configPath = projectPath.appendingPathComponent(".mcp.json")

        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return [:]
        }

        let data = try Data(contentsOf: configPath)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalidFormat
        }

        return json
    }

    /// 检查是否已有 mcp-router 配置
    static func hasRouterConfig(at projectPath: URL) throws -> (exists: Bool, token: String?) {
        let config = try readConfig(at: projectPath)

        guard let servers = config["mcpServers"] as? [String: Any],
              let routerConfig = servers["mcp-router"] as? [String: Any] else {
            return (false, nil)
        }

        // 提取 Token
        if let headers = routerConfig["headers"] as? [String: String],
           let token = headers["X-Workspace-Token"] {
            return (true, token)
        }

        return (true, nil)
    }

    /// 合并并写入 mcp-router 配置
    static func mergeRouterConfig(
        at projectPath: URL,
        token: String,
        routerURL: String = "http://localhost:3000"
    ) throws {
        let configPath = projectPath.appendingPathComponent(".mcp.json")

        // 读取现有配置
        var config = try readConfig(at: projectPath)

        // 合并 mcpServers
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["mcp-router"] = [
            "type": "http",
            "url": routerURL,
            "headers": [
                "X-Workspace-Token": token
            ]
        ]
        config["mcpServers"] = servers

        // 写回文件（格式化）
        let jsonData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )

        try jsonData.write(to: configPath)
    }

    /// 移除 mcp-router 配置
    static func removeRouterConfig(at projectPath: URL) throws {
        let configPath = projectPath.appendingPathComponent(".mcp.json")

        var config = try readConfig(at: projectPath)

        guard var servers = config["mcpServers"] as? [String: Any] else {
            return
        }

        servers.removeValue(forKey: "mcp-router")

        if servers.isEmpty {
            // 如果没有其他 server,删除整个文件
            try? FileManager.default.removeItem(at: configPath)
        } else {
            config["mcpServers"] = servers
            let jsonData = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys]
            )
            try jsonData.write(to: configPath)
        }
    }

    /// 生成配置示例文本（用于编辑页面预览）
    static func generateConfigPreview(token: String, routerURL: String = "http://localhost:19104") -> String {
        let config: [String: Any] = [
            "mcpServers": [
                "mcp-router": [
                    "type": "http",
                    "url": routerURL,
                    "headers": [
                        "X-Workspace-Token": token
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        ),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{}"
        }

        return jsonString
    }
}

// MARK: - Errors

enum ConfigError: LocalizedError {
    case invalidFormat
    case fileNotFound
    case writeError

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "配置文件格式无效"
        case .fileNotFound:
            return "配置文件不存在"
        case .writeError:
            return "写入配置文件失败"
        }
    }
}
