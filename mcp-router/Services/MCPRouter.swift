//
//  MCPRouter.swift
//  mcp-router
//
//  MCP Router 核心 - 管理多个 MCP Server 并提供统一接口
//

import Foundation
import Combine
import SwiftData

final class MCPRouter: ObservableObject {
    static let shared = MCPRouter()

    @Published private(set) var servers: [String: MCPClient] = [:]
    @Published private(set) var serverConfigs: [ServerConfig] = []

    // Workspace 相关
    private var workspaces: [String: Workspace] = [:]  // token -> Workspace
    private var defaultWorkspace: Workspace?

    private init() {}

    // MARK: - Workspace Management

    /// 加载所有 Workspace
    func loadWorkspaces(_ workspaceList: [Workspace]) {
        workspaces.removeAll()

        for workspace in workspaceList {
            workspaces[workspace.token] = workspace
            if workspace.isDefault {
                defaultWorkspace = workspace
            }
        }

        print("✅ 已加载 \(workspaces.count) 个 Workspaces")
        if let defaultWs = defaultWorkspace {
            print("📌 默认 Workspace: \(defaultWs.name)")
        }
    }

    /// 根据 Token 查找 Workspace
    func findWorkspace(byToken token: String?) -> Workspace? {
        if let token = token, let workspace = workspaces[token] {
            return workspace
        }
        // Token 为空或找不到,返回默认 Workspace
        return defaultWorkspace
    }

    /// 获取 Workspace 的有效 Server 配置
    func getEffectiveServers(for workspace: Workspace?) -> [ServerConfig] {
        guard let workspace = workspace else {
            // 无 Workspace,返回所有启用的 Server
            return serverConfigs
        }

        // 返回启用的 Servers
        return serverConfigs.filter { server in
            workspace.isServerEnabled(server.name, defaultWorkspace: defaultWorkspace)
        }
    }

    // MARK: - Lifecycle

    /// 加载并启动所有 Servers
    func loadServers(_ configs: [ServerConfig]) async {
        serverConfigs = configs

        for config in configs {
            let client = MCPClient(config: config)
            servers[config.name] = client
        }

        print("✅ 已加载 \(servers.count) 个 MCP Servers")
    }

    // MARK: - Router Tools (元工具)

    /// 生成 Router 自身的工具列表(根据 Workspace 过滤)
    func generateRouterTools(for workspace: Workspace? = nil) -> [MCPTool] {
        let effectiveServers = getEffectiveServers(for: workspace)
        let serverSummary = effectiveServers.map { config in
            "• \(config.name): \(config.serverDescription)"
        }.joined(separator: "\n")

        return [
            MCPTool(
                name: "mcp_router/list",
                description: """
                📋 列出所有可用的 MCP Servers 和工具

                已加载的 Servers:
                \(serverSummary)

                调用此工具查看每个 Server 的具体工具列表。
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "server": [
                            "type": "string",
                            "description": "可选：只列出指定 Server 的工具"
                        ] as [String: Any]
                    ])
                ]
            ),
            MCPTool(
                name: "mcp_router/describe",
                description: """
                📖 获取指定工具的详细参数说明

                参数: { "tool": "server_name/tool_name" }
                示例: { "tool": "context7/resolve-library-id" }
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "tool": [
                            "type": "string",
                            "description": "工具路径，格式: server_name/tool_name"
                        ] as [String: Any]
                    ]),
                    "required": AnyCodable(["tool"])
                ]
            ),
            MCPTool(
                name: "mcp_router/call",
                description: """
                🚀 调用后端 MCP 工具的统一入口

                ⚠️ 重要：调用前必须先用 mcp_router/describe 查看工具的参数 schema！

                正确使用流程:
                1. mcp_router/list → 查看有哪些 server 和工具
                2. mcp_router/describe → 查看目标工具的参数定义
                3. mcp_router/call → 根据 schema 传入正确的参数

                参数格式:
                {
                  "tool": "server_name/tool_name",
                  "arguments": { ...根据 describe 返回的 schema 填写... }
                }

                示例:
                {
                  "tool": "context7/resolve-library-id",
                  "arguments": { ...先 describe 查看需要什么参数... }
                }
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "tool": [
                            "type": "string",
                            "description": "工具路径，格式: server_name/tool_name"
                        ] as [String: Any],
                        "arguments": [
                            "type": "object",
                            "description": "传递给工具的参数（必须先用 mcp_router/describe 查看该工具的参数定义）"
                        ] as [String: Any]
                    ] as [String: [String: Any]]),
                    "required": AnyCodable(["tool", "arguments"])
                ]
            )
        ]
    }

    // MARK: - Tool Handlers

    /// 处理 mcp_router/list
    func handleList(filterServer: String?, workspace: Workspace?) async throws -> AnyCodable {
        var servers: [[String: Any]] = []

        // 获取 Workspace 的有效 Server 列表
        let effectiveServers = getEffectiveServers(for: workspace)
        let effectiveServerNames = Set(effectiveServers.map { $0.name })

        for (name, client) in self.servers {
            // 只返回 Workspace 启用的 Server
            guard effectiveServerNames.contains(name) else {
                continue
            }

            if let filter = filterServer, name != filter {
                continue
            }

            let tools = try await client.listTools()
            let config = serverConfigs.first { $0.name == name }!

            servers.append([
                "name": name,
                "description": config.serverDescription,
                "tools": tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description
                    ]
                }
            ])
        }

        return AnyCodable([
            "servers": servers
        ])
    }

    /// 处理 mcp_router/describe
    func handleDescribe(toolPath: String) async throws -> String {
        let parts = toolPath.split(separator: "/")
        guard parts.count == 2 else {
            throw MCPError.toolNotFound("Invalid tool path format")
        }

        let serverName = String(parts[0])
        let toolName = String(parts[1])

        guard let client = servers[serverName] else {
            throw MCPError.toolNotFound("Server '\(serverName)' not found")
        }

        let tools = try await client.listTools()
        guard let tool = tools.first(where: { $0.name == toolName }) else {
            throw MCPError.toolNotFound("Tool '\(toolName)' not found in server '\(serverName)'")
        }

        return formatToolDetail(serverName: serverName, tool: tool)
    }

    /// 处理实际的工具调用
    func handleToolCall(name: String, arguments: [String: AnyCodable], workspace: Workspace?) async throws -> AnyCodable {
        // Router 自身的工具
        if name == "mcp_router/list" {
            let filterServer = arguments["server"]?.value as? String
            let result = try await handleList(filterServer: filterServer, workspace: workspace)

            // 返回结构化数据 + 可读文本
            let serversData = result.value as? [String: Any]
            let formattedText = formatListResult(serversData ?? [:])

            // 标准 MCP 格式
            return AnyCodable([
                "content": [
                    [
                        "type": "text",
                        "text": formattedText
                    ] as [String: Any]
                ] as [[String: Any]]
            ] as [String: Any])
        } else if name == "mcp_router/describe" {
            guard let toolPath = arguments["tool"]?.value as? String else {
                throw MCPError.toolNotFound("Missing 'tool' parameter")
            }
            let result = try await handleDescribe(toolPath: toolPath)
            return AnyCodable([
                "content": [
                    [
                        "type": "text",
                        "text": result
                    ] as [String: Any]
                ] as [[String: Any]]
            ] as [String: Any])
        } else if name == "mcp_router/call" {
            // 统一的工具调用入口
            guard let toolPath = arguments["tool"]?.value as? String else {
                throw MCPError.toolNotFound("Missing 'tool' parameter")
            }

            let toolArgs = arguments["arguments"]?.value as? [String: Any] ?? [:]
            let convertedArgs = toolArgs.mapValues { AnyCodable($0) }

            // 解析 tool path
            let parts = toolPath.split(separator: "/")
            guard parts.count == 2 else {
                throw MCPError.toolNotFound("Invalid tool path format: \(toolPath)")
            }

            let serverName = String(parts[0])
            let toolName = String(parts[1])

            guard let client = servers[serverName] else {
                throw MCPError.toolNotFound("Server '\(serverName)' not found")
            }

            // 转发到后端 Server
            return try await client.callTool(name: toolName, arguments: convertedArgs)
        }

        // 不应该走到这里（所有工具都应该通过 mcp_router/call）
        throw MCPError.toolNotFound("Unknown tool: \(name). Please use mcp_router/call to invoke backend tools.")
    }

    // MARK: - Formatters

    private func formatListResult(_ result: [String: Any]) -> String {
        var lines = ["📋 可用的 MCP Servers 和工具:\n"]

        guard let serversList = result["servers"] as? [[String: Any]] else {
            return "无可用 Servers"
        }

        for serverData in serversList {
            guard let name = serverData["name"] as? String,
                  let description = serverData["description"] as? String,
                  let tools = serverData["tools"] as? [[String: Any]] else {
                continue
            }

            lines.append("📦 **\(name)**: \(description)")

            let toolNames = tools.compactMap { $0["name"] as? String }
            lines.append("   工具 (\(tools.count)): \(toolNames.joined(separator: ", "))\n")

            // 列出每个工具的简短描述
            for tool in tools.prefix(5) {
                if let toolName = tool["name"] as? String,
                   let toolDesc = tool["description"] as? String {
                    let shortDesc = toolDesc.components(separatedBy: "\n").first ?? toolDesc
                    lines.append("     • \(toolName): \(shortDesc.prefix(60))...")
                }
            }
            if tools.count > 5 {
                lines.append("     ... 还有 \(tools.count - 5) 个工具")
            }
            lines.append("")
        }

        lines.append("\n💡 使用方式:")
        lines.append("  1. 调用 mcp_router/describe 查看工具参数")
        lines.append("  2. 直接调用 server_name/tool_name 使用工具")
        lines.append("  示例: 调用 context7/resolve-library-id 而非使用 npx 命令")
        return lines.joined(separator: "\n")
    }

    private func formatToolDetail(serverName: String, tool: MCPTool) -> String {
        var lines = ["📖 工具详情: \(serverName)/\(tool.name)\n"]
        lines.append("**描述**: \(tool.description)\n")

        if let schema = tool.inputSchema {
            lines.append("**参数 Schema**:")
            if let jsonData = try? JSONSerialization.data(withJSONObject: schema.mapValues { $0.value }),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                lines.append("```json")
                lines.append(jsonString)
                lines.append("```")
            }
        }

        lines.append("\n💡 **如何调用这个工具**:")
        lines.append("   直接使用工具名称: **\(serverName)/\(tool.name)**")
        lines.append("")
        lines.append("   示例:")
        lines.append("   调用工具: \(serverName)/\(tool.name)")
        lines.append("   传入参数: { \"参数名\": \"参数值\" }")
        return lines.joined(separator: "\n")
    }
}
