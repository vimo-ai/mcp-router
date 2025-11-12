//
//  AppRoute.swift
//  mcp-router
//
//  应用路由定义
//

import Foundation

enum AppRoute: Hashable {
    case workspace(Workspace)
    case servers
    case settings
}
