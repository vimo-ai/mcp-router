//
//  CodexConfigManager.swift
//  mcp-router
//
//  负责修改 ~/.codex/config.toml 以实现 Codex 的全局配置
//

import Foundation

struct CodexConfigManager {
    private static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex")

    static let configPath = configDirectory.appendingPathComponent("config.toml")
    static let backupPath = configDirectory.appendingPathComponent("config.toml.backup")

    // MARK: - 状态查询

    static func isInstalledToGlobal() throws -> Bool {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return false
        }

        let content = try String(contentsOf: configPath, encoding: .utf8)
        return findRouterSectionRange(in: content) != nil
    }

    // MARK: - 安装 & 卸载

    static func installToGlobal(port: Int) throws {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw CodexConfigError.fileNotFound
        }

        let content = try String(contentsOf: configPath, encoding: .utf8)
        try content.write(to: backupPath, atomically: true, encoding: .utf8)

        do {
            let routerBlock = buildRouterBlock(port: port)
            let modified = insertOrReplaceRouterBlock(in: content, routerBlock: routerBlock)
            try modified.write(to: configPath, atomically: true, encoding: .utf8)
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
            let modified = removeRouterBlock(in: content)
            try modified.write(to: configPath, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: backupPath)
        } catch {
            try? restoreBackup()
            throw error
        }
    }

    // MARK: - 文本处理

    private static func buildRouterBlock(port: Int) -> String {
        return """
        [mcp_servers.mcp-router]
        type = \"http\"
        url = \"http://localhost:\(port)\"
        
        """
    }

    private static func insertOrReplaceRouterBlock(in content: String, routerBlock: String) -> String {
        let normalizedBlock = routerBlock.hasSuffix("\n") ? routerBlock : routerBlock + "\n"

        if let range = findRouterSectionRange(in: content) {
            var modified = content
            modified.replaceSubrange(range, with: normalizedBlock)
            return modified
        } else {
            var modified = content
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                modified = normalizedBlock
            } else {
                if !modified.hasSuffix("\n") {
                    modified.append("\n")
                }
                modified.append("\n")
                modified.append(normalizedBlock)
            }
            return modified
        }
    }

    private static func removeRouterBlock(in content: String) -> String {
        guard let range = findRouterSectionRange(in: content) else {
            return content
        }

        var modified = content
        modified.removeSubrange(range)

        if modified.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }

        if !modified.hasSuffix("\n") {
            modified.append("\n")
        }

        return modified
    }

    private static func findRouterSectionRange(in content: String) -> Range<String.Index>? {
        return sectionRanges(in: content).first(where: { $0.name == "mcp_servers.mcp-router" })?.range
    }

    private static func sectionRanges(in content: String) -> [TomlSection] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\[([^\]]+)\]\s*$"#) else {
            return []
        }

        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, range: nsRange)

        return matches.enumerated().compactMap { index, match in
            guard let headerRange = Range(match.range(at: 0), in: content),
                  let nameRange = Range(match.range(at: 1), in: content) else {
                return nil
            }

            let start = headerRange.lowerBound
            let end: String.Index
            if index + 1 < matches.count,
               let nextHeaderRange = Range(matches[index + 1].range(at: 0), in: content) {
                end = nextHeaderRange.lowerBound
            } else {
                end = content.endIndex
            }

            return TomlSection(name: String(content[nameRange]), range: start..<end)
        }
    }

    private static func restoreBackup() throws {
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            throw CodexConfigError.backupNotFound
        }

        try FileManager.default.removeItem(at: configPath)
        try FileManager.default.copyItem(at: backupPath, to: configPath)
        try FileManager.default.removeItem(at: backupPath)
    }

    private struct TomlSection {
        let name: String
        let range: Range<String.Index>
    }
}

enum CodexConfigError: LocalizedError {
    case fileNotFound
    case backupNotFound

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "找不到 ~/.codex/config.toml 文件"
        case .backupNotFound:
            return "找不到备份文件"
        }
    }
}

struct CodexGlobalConfigProvider: GlobalConfigProvider {
    let id = "codex"
    let displayName = "Codex"
    let descriptionText = "写入 ~/.codex/config.toml，令所有 Codex workspace 共享 mcp-router。"
    var configPath: URL {
        CodexConfigManager.configPath
    }

    func isInstalled() throws -> Bool {
        try CodexConfigManager.isInstalledToGlobal()
    }

    func install(port: Int) throws {
        try CodexConfigManager.installToGlobal(port: port)
    }

    func uninstall() throws {
        try CodexConfigManager.uninstallFromGlobal()
    }
}
