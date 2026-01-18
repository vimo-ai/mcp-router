//
//  OpenCodeConfigManager.swift
//  mcp-router
//
//  处理 ~/.config/opencode/opencode.json 的全局配置修改
//  OpenCode 使用 mcp 字段（不是 mcpServers）和 type: "remote"
//

import Foundation

struct OpenCodeConfigManager {
    private static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config")
        .appendingPathComponent("opencode")

    static let configPath = configDirectory.appendingPathComponent("opencode.json")
    static let backupPath = configDirectory.appendingPathComponent("opencode.json.backup")

    // MARK: - 状态查询

    static func isInstalledToGlobal() throws -> Bool {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return false
        }

        let content = try String(contentsOf: configPath, encoding: .utf8)
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcp = json["mcp"] as? [String: Any] else {
            return false
        }

        return mcp["mcp-router"] != nil
    }

    // MARK: - 安装 & 卸载

    static func installToGlobal(port: Int) throws {
        // 如果文件不存在，创建初始配置
        if !FileManager.default.fileExists(atPath: configPath.path) {
            try createInitialConfig(port: port)
            return
        }

        let content = try String(contentsOf: configPath, encoding: .utf8)
        try content.write(to: backupPath, atomically: true, encoding: .utf8)

        do {
            guard let data = content.data(using: .utf8),
                  var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OpenCodeConfigError.invalidFormat("无法解析 JSON")
            }

            // OpenCode 使用 mcp 字段（不是 mcpServers）
            var mcp = json["mcp"] as? [String: Any] ?? [:]

            // OpenCode 使用 type: "remote"
            mcp["mcp-router"] = [
                "type": "remote",
                "url": "http://localhost:\(port)"
            ]

            json["mcp"] = mcp

            let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            guard let newContent = String(data: newData, encoding: .utf8) else {
                throw OpenCodeConfigError.invalidFormat("无法序列化 JSON")
            }

            try newContent.write(to: configPath, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: backupPath)
        } catch {
            try? restoreBackup()
            throw error
        }
    }

    static func uninstallFromGlobal() throws {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return
        }

        let content = try String(contentsOf: configPath, encoding: .utf8)
        try content.write(to: backupPath, atomically: true, encoding: .utf8)

        do {
            guard let data = content.data(using: .utf8),
                  var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OpenCodeConfigError.invalidFormat("无法解析 JSON")
            }

            if var mcp = json["mcp"] as? [String: Any] {
                mcp.removeValue(forKey: "mcp-router")
                json["mcp"] = mcp
            }

            let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            guard let newContent = String(data: newData, encoding: .utf8) else {
                throw OpenCodeConfigError.invalidFormat("无法序列化 JSON")
            }

            try newContent.write(to: configPath, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: backupPath)
        } catch {
            try? restoreBackup()
            throw error
        }
    }

    // MARK: - 辅助方法

    private static func createInitialConfig(port: Int) throws {
        // 确保目录存在
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let config: [String: Any] = [
            "mcp": [
                "mcp-router": [
                    "type": "remote",
                    "url": "http://localhost:\(port)"
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let content = String(data: data, encoding: .utf8) else {
            throw OpenCodeConfigError.invalidFormat("无法序列化 JSON")
        }

        try content.write(to: configPath, atomically: true, encoding: .utf8)
    }

    private static func restoreBackup() throws {
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            throw OpenCodeConfigError.backupNotFound
        }

        try FileManager.default.removeItem(at: configPath)
        try FileManager.default.copyItem(at: backupPath, to: configPath)
        try FileManager.default.removeItem(at: backupPath)
    }
}

enum OpenCodeConfigError: LocalizedError {
    case invalidFormat(String)
    case backupNotFound

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail):
            return "配置文件格式无效: \(detail)"
        case .backupNotFound:
            return "找不到备份文件"
        }
    }
}

struct OpenCodeGlobalConfigProvider: GlobalConfigProvider {
    let id = "opencode"
    let displayName = "OpenCode"
    let descriptionText = "写入 ~/.config/opencode/opencode.json，令所有 OpenCode workspace 共享 mcp-router。"
    var configPath: URL {
        OpenCodeConfigManager.configPath
    }

    func isInstalled() throws -> Bool {
        try OpenCodeConfigManager.isInstalledToGlobal()
    }

    func install(port: Int) throws {
        try OpenCodeConfigManager.installToGlobal(port: port)
    }

    func uninstall() throws {
        try OpenCodeConfigManager.uninstallFromGlobal()
    }
}
