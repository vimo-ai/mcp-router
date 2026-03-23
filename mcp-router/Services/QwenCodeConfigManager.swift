//
//  QwenCodeConfigManager.swift
//  mcp-router
//
//  处理 ~/.qwen/settings.json 的全局配置修改
//  使用正则表达式增量修改，避免解析整个大文件
//

import Foundation

struct QwenCodeConfigManager {
    private static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".qwen")

    static let configPath = configDirectory.appendingPathComponent("settings.json")
    static let backupPath = configDirectory.appendingPathComponent("settings.json.backup")

    // MARK: - 状态查询

    /// 检查是否已安装到全局配置
    static func isInstalledToGlobal() throws -> Bool {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return false
        }

        let content = try String(contentsOf: configPath, encoding: .utf8)

        // 查找 "mcpServers" 块
        guard let mcpServersRange = findMcpServersRange(in: content) else {
            return false
        }

        // 在 mcpServers 中查找 "qwen-code" 或 "mcp-router"
        let mcpServersSection = String(content[mcpServersRange])
        let hasQwenCode = mcpServersSection.range(of: #""qwen-code"\s*:"#, options: .regularExpression) != nil
        let hasMcpRouter = mcpServersSection.range(of: #""mcp-router"\s*:"#, options: .regularExpression) != nil
        
        return hasQwenCode || hasMcpRouter
    }

    // MARK: - 安装和卸载

    /// 安装到全局配置
    static func installToGlobal(port: Int) throws {
        // 如果文件不存在，创建初始配置
        if !FileManager.default.fileExists(atPath: configPath.path) {
            try createInitialConfig(port: port)
            return
        }

        let content = try String(contentsOf: configPath, encoding: .utf8)

        // 备份
        try content.write(to: backupPath, atomically: true, encoding: .utf8)

        do {
            // 查找 mcpServers
            guard let mcpServersRange = findMcpServersRange(in: content) else {
                throw QwenCodeConfigError.invalidFormat("找不到 mcpServers 字段")
            }

            // 构建配置
            let routerConfig = buildRouterConfig(port: port)

            // 插入或替换配置
            let modified = try insertOrReplaceRouterConfig(
                in: content,
                mcpServersRange: mcpServersRange,
                routerConfig: routerConfig
            )

            // 验证 JSON 有效性
            guard isValidJSON(modified) else {
                throw QwenCodeConfigError.invalidFormat("修改后的 JSON 格式无效")
            }

            // 写回文件
            try modified.write(to: configPath, atomically: true, encoding: .utf8)

            // 删除备份
            try? FileManager.default.removeItem(at: backupPath)

        } catch {
            // 恢复备份
            try? restoreBackup()
            throw error
        }
    }

    /// 从全局配置卸载
    static func uninstallFromGlobal() throws {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return
        }

        let content = try String(contentsOf: configPath, encoding: .utf8)

        // 备份
        try content.write(to: backupPath, atomically: true, encoding: .utf8)

        do {
            // 查找 mcpServers
            guard let mcpServersRange = findMcpServersRange(in: content) else {
                // 没有找到，说明本来就没安装
                try? FileManager.default.removeItem(at: backupPath)
                return
            }

            // 移除配置（同时支持 qwen-code 和 mcp-router 两种名称）
            let modified = try removeRouterConfig(in: content, mcpServersRange: mcpServersRange)

            // 验证 JSON 有效性
            guard isValidJSON(modified) else {
                throw QwenCodeConfigError.invalidFormat("修改后的 JSON 格式无效")
            }

            // 写回文件
            try modified.write(to: configPath, atomically: true, encoding: .utf8)

            // 删除备份
            try? FileManager.default.removeItem(at: backupPath)

        } catch {
            // 恢复备份
            try? restoreBackup()
            throw error
        }
    }

    // MARK: - 辅助方法

    /// 查找 mcpServers 字段范围
    private static func findMcpServersRange(in content: String) -> Range<String.Index>? {
        let keyPattern = #""mcpServers"\s*:\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: keyPattern) else {
            return nil
        }

        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, range: nsRange)

        // 取第一个匹配
        guard let firstMatch = matches.first,
              let keyRange = Range(firstMatch.range, in: content) else {
            return nil
        }

        // 从 { 开始，找到匹配的 }
        let startBrace = content.index(before: keyRange.upperBound)
        guard let endBrace = findMatchingBrace(in: content, startingAt: startBrace) else {
            return nil
        }

        // 返回完整的 "mcpServers": { ... } 范围
        return keyRange.lowerBound..<content.index(after: endBrace)
    }

    /// 找到匹配的右花括号
    private static func findMatchingBrace(in content: String, startingAt start: String.Index) -> String.Index? {
        var depth = 0
        var current = start

        while current < content.endIndex {
            let char = content[current]
            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return current
                }
            }
            current = content.index(after: current)
        }

        return nil
    }

    /// 构建 mcp-router 配置字符串
    private static func buildRouterConfig(port: Int) -> String {
        return """
        "mcp-router": {
              "type": "http",
              "url": "http://localhost:\(port)"
            }
        """
    }

    /// 插入或替换 mcp-router 配置
    private static func insertOrReplaceRouterConfig(
        in content: String,
        mcpServersRange: Range<String.Index>,
        routerConfig: String
    ) throws -> String {
        // 1. 提取 mcpServers 部分的 JSON
        let mcpServersSection = String(content[mcpServersRange])

        // 2. 找到 { ... } 的部分
        guard let colonRange = mcpServersSection.range(of: ":") else {
            throw QwenCodeConfigError.invalidFormat("mcpServers 格式错误")
        }

        let jsonPart = String(mcpServersSection[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. 解析为字典
        guard let jsonData = jsonPart.data(using: .utf8),
              var serversDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw QwenCodeConfigError.invalidFormat("无法解析 mcpServers JSON")
        }

        // 4. 解析 routerConfig 字符串为对象
        let routerConfigWithBraces = "{\(routerConfig)}"
        guard let routerData = routerConfigWithBraces.data(using: .utf8),
              let routerDict = try? JSONSerialization.jsonObject(with: routerData) as? [String: Any],
              let routerValue = routerDict["mcp-router"] else {
            throw QwenCodeConfigError.invalidFormat("无法解析 router 配置")
        }

        // 5. 添加或替换 mcp-router（同时支持 qwen-code 名称）
        serversDict["mcp-router"] = routerValue

        // 6. 序列化回 JSON
        let newJsonData = try JSONSerialization.data(withJSONObject: serversDict, options: [.prettyPrinted, .sortedKeys])
        guard var newJsonString = String(data: newJsonData, encoding: .utf8) else {
            throw QwenCodeConfigError.invalidFormat("无法序列化 JSON")
        }

        // 7. 调整缩进
        newJsonString = adjustIndentation(newJsonString, level: 1)

        // 8. 构建完整的 "mcpServers": { ... }
        let newMcpServersSection = #""mcpServers": "# + newJsonString

        // 9. 替换原内容
        var modified = content
        modified.replaceSubrange(mcpServersRange, with: newMcpServersSection)

        return modified
    }

    /// 调整 JSON 字符串的缩进
    private static func adjustIndentation(_ json: String, level: Int) -> String {
        let indent = String(repeating: "  ", count: level)
        let lines = json.split(separator: "\n", omittingEmptySubsequences: false)

        return lines.enumerated().map { index, line in
            if index == 0 {
                return String(line)
            } else {
                return indent + line
            }
        }.joined(separator: "\n")
    }

    /// 移除 mcp-router 配置
    private static func removeRouterConfig(
        in content: String,
        mcpServersRange: Range<String.Index>
    ) throws -> String {
        // 1. 提取 mcpServers 部分的 JSON
        let mcpServersSection = String(content[mcpServersRange])

        // 2. 找到 { ... } 的部分
        guard let colonRange = mcpServersSection.range(of: ":") else {
            throw QwenCodeConfigError.invalidFormat("mcpServers 格式错误")
        }

        let jsonPart = String(mcpServersSection[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. 解析为字典
        guard let jsonData = jsonPart.data(using: .utf8),
              var serversDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw QwenCodeConfigError.invalidFormat("无法解析 mcpServers JSON")
        }

        // 4. 移除 mcp-router 和 qwen-code
        serversDict.removeValue(forKey: "mcp-router")
        serversDict.removeValue(forKey: "qwen-code")

        // 5. 序列化回 JSON
        let newJsonData = try JSONSerialization.data(withJSONObject: serversDict, options: [.prettyPrinted, .sortedKeys])
        guard var newJsonString = String(data: newJsonData, encoding: .utf8) else {
            throw QwenCodeConfigError.invalidFormat("无法序列化 JSON")
        }

        // 6. 调整缩进
        newJsonString = adjustIndentation(newJsonString, level: 1)

        // 7. 构建完整的 "mcpServers": { ... }
        let newMcpServersSection = #""mcpServers": "# + newJsonString

        // 8. 替换原内容
        var modified = content
        modified.replaceSubrange(mcpServersRange, with: newMcpServersSection)

        return modified
    }

    /// 验证 JSON 有效性
    private static func isValidJSON(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return true
        } catch {
            print("❌ JSON 验证失败：\(error)")
            return false
        }
    }

    /// 创建初始配置
    private static func createInitialConfig(port: Int) throws {
        // 确保目录存在
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let config: [String: Any] = [
            "mcpServers": [
                "mcp-router": [
                    "type": "http",
                    "url": "http://localhost:\(port)"
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        guard let content = String(data: data, encoding: .utf8) else {
            throw QwenCodeConfigError.invalidFormat("无法序列化 JSON")
        }

        try content.write(to: configPath, atomically: true, encoding: .utf8)
    }

    /// 恢复备份
    private static func restoreBackup() throws {
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            throw QwenCodeConfigError.backupNotFound
        }

        try FileManager.default.removeItem(at: configPath)
        try FileManager.default.copyItem(at: backupPath, to: configPath)
        try FileManager.default.removeItem(at: backupPath)
    }
}

// MARK: - 错误定义

enum QwenCodeConfigError: LocalizedError {
    case invalidFormat(String)
    case backupNotFound

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail):
            return "配置文件格式无效：\(detail)"
        case .backupNotFound:
            return "找不到备份文件"
        }
    }
}

// MARK: - Provider

struct QwenCodeGlobalConfigProvider: GlobalConfigProvider {
    let id = "qwen-code"
    let displayName = "Qwen Code"
    let descriptionText = "将 mcp-router 安装到 ~/.qwen/settings.json，所有 Qwen Code workspace 均可直接访问。"
    var configPath: URL {
        QwenCodeConfigManager.configPath
    }

    func isInstalled() throws -> Bool {
        try QwenCodeConfigManager.isInstalledToGlobal()
    }

    func install(port: Int) throws {
        try QwenCodeConfigManager.installToGlobal(port: port)
    }

    func uninstall() throws {
        try QwenCodeConfigManager.uninstallFromGlobal()
    }
}
