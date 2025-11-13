//
//  GlobalConfigProvider.swift
//  mcp-router
//
//  定义通用的全局配置 Provider 协议
//

import Foundation

protocol GlobalConfigProvider: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var descriptionText: String { get }
    var configPath: URL { get }

    func isInstalled() throws -> Bool
    func install(port: Int) throws
    func uninstall() throws
}

enum GlobalConfigProviders {
    static let all: [any GlobalConfigProvider] = [
        ClaudeGlobalConfigProvider(),
        CodexGlobalConfigProvider()
    ]
}
