//
//  ClaudeConfigManager.swift
//  mcp-router
//
//  处理 ~/.claude.json 的全局配置修改
//  使用正则表达式增量修改，避免解析整个大文件
//

import Foundation

struct ClaudeConfigManager {
    static let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json")

    static let backupPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json.backup")

    // MARK: - 检查安装状态

    /// 检查是否已安装到全局配置
    static func isInstalledToGlobal() throws -> Bool {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return false
        }

        let content = try String(contentsOf: configPath, encoding: .utf8)

        // 查找最后一个 "mcpServers" 块（根配置）
        guard let rootMcpServersRange = findRootMcpServers(in: content) else {
            return false
        }

        // 在根配置的 mcpServers 中查找 "mcp-router"
        let mcpServersSection = String(content[rootMcpServersRange])
        return mcpServersSection.range(of: #""mcp-router"\s*:"#, options: .regularExpression) != nil
    }

    // MARK: - 安装和卸载

    /// 安装到全局配置
    static func installToGlobal(token: String, port: Int) throws {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw ClaudeConfigError.fileNotFound
        }

        // 1. 读取原始内容
        let content = try String(contentsOf: configPath, encoding: .utf8)

        // 2. 备份
        try content.write(to: backupPath, atomically: true, encoding: .utf8)

        do {
            // 3. 查找根配置的 mcpServers
            guard let rootMcpServersRange = findRootMcpServers(in: content) else {
                throw ClaudeConfigError.invalidFormat("找不到根配置的 mcpServers 字段")
            }

            // 4. 构建 mcp-router 配置
            let routerConfig = buildRouterConfig(token: token, port: port)

            // 5. 插入或替换配置
            let modified = try insertOrReplaceRouterConfig(
                in: content,
                mcpServersRange: rootMcpServersRange,
                routerConfig: routerConfig
            )

            // 6. 验证 JSON 有效性
            guard isValidJSON(modified) else {
                throw ClaudeConfigError.invalidFormat("修改后的 JSON 格式无效")
            }

            // 7. 写回文件
            try modified.write(to: configPath, atomically: true, encoding: .utf8)

            // 8. 删除备份
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

        // 1. 读取原始内容
        let content = try String(contentsOf: configPath, encoding: .utf8)

        // 2. 备份
        try content.write(to: backupPath, atomically: true, encoding: .utf8)

        do {
            // 3. 查找根配置的 mcpServers
            guard let rootMcpServersRange = findRootMcpServers(in: content) else {
                // 没有找到，说明本来就没安装
                try? FileManager.default.removeItem(at: backupPath)
                return
            }

            // 4. 移除 mcp-router 配置
            let modified = try removeRouterConfig(in: content, mcpServersRange: rootMcpServersRange)

            // 5. 验证 JSON 有效性
            guard isValidJSON(modified) else {
                throw ClaudeConfigError.invalidFormat("修改后的 JSON 格式无效")
            }

            // 6. 写回文件
            try modified.write(to: configPath, atomically: true, encoding: .utf8)

            // 7. 删除备份
            try? FileManager.default.removeItem(at: backupPath)

        } catch {
            // 恢复备份
            try? restoreBackup()
            throw error
        }
    }

    // MARK: - 辅助方法

    /// 查找根配置的 mcpServers 字段范围
    /// 策略：找到最后一个 "mcpServers" 关键字，然后向后匹配完整的 JSON 对象
    private static func findRootMcpServers(in content: String) -> Range<String.Index>? {
        // 1. 找到所有 "mcpServers": 的位置
        let keyPattern = #""mcpServers"\s*:\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: keyPattern) else {
            return nil
        }

        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, range: nsRange)

        // 2. 取最后一个匹配（根配置）
        guard let lastMatch = matches.last,
              let keyRange = Range(lastMatch.range, in: content) else {
            return nil
        }

        // 3. 从 { 开始，找到匹配的 }
        let startBrace = content.index(before: keyRange.upperBound)
        guard let endBrace = findMatchingBrace(in: content, startingAt: startBrace) else {
            return nil
        }

        // 4. 返回完整的 "mcpServers": { ... } 范围
        return keyRange.lowerBound..<content.index(after: endBrace)
    }

    /// 找到匹配的右花括号
    /// 参数 start: { 的位置
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
    private static func buildRouterConfig(token: String, port: Int) -> String {
        return """
        "mcp-router": {
              "type": "http",
              "url": "http://localhost:\(port)",
              "headers": {
                "X-Workspace-Token": "\(token)"
              }
            }
        """
    }

    /// 插入或替换 mcp-router 配置
    /// 策略：解析 mcpServers JSON 对象，修改后重新序列化
    private static func insertOrReplaceRouterConfig(
        in content: String,
        mcpServersRange: Range<String.Index>,
        routerConfig: String
    ) throws -> String {
        // 1. 提取 mcpServers 部分的 JSON
        let mcpServersSection = String(content[mcpServersRange])

        // 2. 找到 { ... } 的部分（不包含 "mcpServers": 前缀）
        guard let colonRange = mcpServersSection.range(of: ":") else {
            throw ClaudeConfigError.invalidFormat("mcpServers 格式错误")
        }

        let jsonPart = String(mcpServersSection[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. 解析为字典
        guard let jsonData = jsonPart.data(using: .utf8),
              var serversDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ClaudeConfigError.invalidFormat("无法解析 mcpServers JSON")
        }

        // 4. 解析 routerConfig 字符串为对象
        let routerConfigWithBraces = "{\(routerConfig)}"
        guard let routerData = routerConfigWithBraces.data(using: .utf8),
              let routerDict = try? JSONSerialization.jsonObject(with: routerData) as? [String: Any],
              let routerValue = routerDict["mcp-router"] else {
            throw ClaudeConfigError.invalidFormat("无法解析 router 配置")
        }

        // 5. 添加或替换 mcp-router
        serversDict["mcp-router"] = routerValue

        // 6. 序列化回 JSON（保持一定格式）
        let newJsonData = try JSONSerialization.data(withJSONObject: serversDict, options: [.prettyPrinted, .sortedKeys])
        guard var newJsonString = String(data: newJsonData, encoding: .utf8) else {
            throw ClaudeConfigError.invalidFormat("无法序列化 JSON")
        }

        // 7. 调整缩进（JSONSerialization 默认 2 空格，我们需要匹配原文件的缩进）
        newJsonString = adjustIndentation(newJsonString, level: 1)

        // 8. 构建完整的 "mcpServers": { ... }
        let newMcpServersSection = #""mcpServers": "#  + newJsonString

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
                return String(line) // 第一行不缩进（已有 "mcpServers": ）
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
            throw ClaudeConfigError.invalidFormat("mcpServers 格式错误")
        }

        let jsonPart = String(mcpServersSection[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. 解析为字典
        guard let jsonData = jsonPart.data(using: .utf8),
              var serversDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ClaudeConfigError.invalidFormat("无法解析 mcpServers JSON")
        }

        // 4. 移除 mcp-router
        serversDict.removeValue(forKey: "mcp-router")

        // 5. 序列化回 JSON
        let newJsonData = try JSONSerialization.data(withJSONObject: serversDict, options: [.prettyPrinted, .sortedKeys])
        guard var newJsonString = String(data: newJsonData, encoding: .utf8) else {
            throw ClaudeConfigError.invalidFormat("无法序列化 JSON")
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

    /// 验证 JSON 有效性（不完全解析，只检查语法）
    private static func isValidJSON(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return true
        } catch {
            print("❌ JSON 验证失败: \(error)")
            return false
        }
    }

    /// 恢复备份
    private static func restoreBackup() throws {
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            throw ClaudeConfigError.backupNotFound
        }

        try FileManager.default.removeItem(at: configPath)
        try FileManager.default.copyItem(at: backupPath, to: configPath)
        try FileManager.default.removeItem(at: backupPath)
    }
}

// MARK: - 错误定义

enum ClaudeConfigError: LocalizedError {
    case fileNotFound
    case invalidFormat(String)
    case backupNotFound

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "找不到 ~/.claude.json 文件"
        case .invalidFormat(let detail):
            return "配置文件格式无效: \(detail)"
        case .backupNotFound:
            return "找不到备份文件"
        }
    }
}
