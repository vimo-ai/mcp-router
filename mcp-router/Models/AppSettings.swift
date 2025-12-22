//
//  AppSettings.swift
//  mcp-router
//
//  应用设置模型
//

import Foundation
import SwiftData
import SwiftUI

@Model
final class AppSettings {
    var serverPort: Int
    var allowPrereleaseUpdates: Bool = false // 是否接收预发布版本（beta/alpha/rc），默认 false
    var theme: String = AppTheme.auto.rawValue // 主题设置: auto/light/dark
    var exposeManagementTools: Bool = false // 是否暴露 add/remove/update 工具（默认 light 模式，不暴露）
    var createdAt: Date
    var updatedAt: Date

    init(
        serverPort: Int = 19104,
        allowPrereleaseUpdates: Bool = false, // 默认只接收正式版
        theme: String = AppTheme.auto.rawValue,
        exposeManagementTools: Bool = false, // 默认 light 模式
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.serverPort = serverPort
        self.allowPrereleaseUpdates = allowPrereleaseUpdates
        self.theme = theme
        self.exposeManagementTools = exposeManagementTools
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 获取主题枚举值
    var appTheme: AppTheme {
        get { AppTheme(rawValue: theme) ?? .auto }
        set { theme = newValue.rawValue }
    }

    /// 验证端口号是否合法
    static func validatePort(_ port: Int) -> Bool {
        return port >= 1024 && port <= 65535
    }
}

// MARK: - Helpers

extension AppSettings {
    /// 获取或创建默认设置
    static func getOrCreate(context: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()

        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        // 创建默认设置
        let settings = AppSettings()
        context.insert(settings)
        try? context.save()

        print("✅ 创建默认应用设置，端口: \(settings.serverPort)")
        return settings
    }
}
