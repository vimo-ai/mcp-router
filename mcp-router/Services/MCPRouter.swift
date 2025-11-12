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

    // stdio 进程池
    private var stdioProcessPool = WorkspaceProcessPool()

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
            if config.type == .http {
                // HTTP 类型
                let client = MCPClient(config: config)
                servers[config.name] = client
            }
            // stdio 类型在需要时动态创建
        }

        print("✅ 已加载 \(servers.count) 个 HTTP Servers")
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
                name: "mcp_router/list_servers",
                description: """
                📋 列出所有可用的 MCP Servers

                已加载的 Servers:
                \(serverSummary)

                返回 Server 列表(不含工具详情,节省 tokens)。
                使用 mcp_router/list_tools 查看某个 Server 的工具列表。
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([:])
                ]
            ),
            MCPTool(
                name: "mcp_router/list_tools",
                description: """
                🔧 列出指定 Server 的所有工具

                参数:
                - server: Server 名称(必填)

                返回工具名称和描述列表。
                使用 mcp_router/describe 查看工具的详细参数。
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "server": [
                            "type": "string",
                            "description": "Server 名称"
                        ] as [String: Any]
                    ]),
                    "required": AnyCodable(["server"])
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

    /// 处理 mcp_router/list_servers - 只返回 Server 列表(不含工具)
    func handleListServers(workspace: Workspace?) async throws -> AnyCodable {
        var servers: [[String: Any]] = []

        // 获取 Workspace 的有效 Server 列表
        let effectiveServers = getEffectiveServers(for: workspace)

        for config in effectiveServers {
            servers.append([
                "name": config.name,
                "description": config.serverDescription,
                "type": config.type.rawValue
            ])
        }

        return AnyCodable([
            "servers": servers
        ])
    }

    /// 处理 mcp_router/list_tools - 返回指定 Server 的工具列表
    func handleListTools(serverName: String, workspace: Workspace?) async throws -> AnyCodable {
        // 查找 server 配置
        guard let config = serverConfigs.first(where: { $0.name == serverName }) else {
            throw MCPError.toolNotFound("Server '\(serverName)' not found")
        }

        let tools: [MCPTool]
        if config.type == .http {
            // HTTP 类型
            guard let client = servers[serverName] else {
                throw MCPError.toolNotFound("Server '\(serverName)' not found")
            }
            tools = try await client.listTools()
        } else {
            // stdio 类型
            let workspaceToken = workspace?.token ?? "default"
            let stdioClient = try await stdioProcessPool.getOrCreateClient(
                workspaceToken: workspaceToken,
                config: config
            )
            tools = try await stdioClient.listTools()
        }

        // 只返回工具名称和简短描述
        let toolsList = tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description
            ]
        }

        return AnyCodable([
            "server": serverName,
            "tools": toolsList
        ])
    }

    /// 处理 mcp_router/describe
    func handleDescribe(toolPath: String, workspace: Workspace?) async throws -> String {
        let parts = toolPath.split(separator: "/")
        guard parts.count == 2 else {
            throw MCPError.toolNotFound("Invalid tool path format")
        }

        let serverName = String(parts[0])
        let toolName = String(parts[1])

        // 查找 server 配置
        guard let config = serverConfigs.first(where: { $0.name == serverName }) else {
            throw MCPError.toolNotFound("Server '\(serverName)' not found")
        }

        let tools: [MCPTool]
        if config.type == .http {
            // HTTP 类型
            guard let client = servers[serverName] else {
                throw MCPError.toolNotFound("Server '\(serverName)' not found")
            }
            tools = try await client.listTools()
        } else {
            // stdio 类型
            let workspaceToken = workspace?.token ?? "default"
            let stdioClient = try await stdioProcessPool.getOrCreateClient(
                workspaceToken: workspaceToken,
                config: config
            )
            tools = try await stdioClient.listTools()
        }

        guard let tool = tools.first(where: { $0.name == toolName }) else {
            throw MCPError.toolNotFound("Tool '\(toolName)' not found in server '\(serverName)'")
        }

        return formatToolDetail(serverName: serverName, tool: tool)
    }

    /// 处理实际的工具调用
    func handleToolCall(name: String, arguments: [String: AnyCodable], workspace: Workspace?) async throws -> AnyCodable {
        // Router 自身的工具
        if name == "mcp_router/list_servers" {
            let result = try await handleListServers(workspace: workspace)
            let serversData = result.value as? [String: Any]
            let formattedText = formatListServersResult(serversData ?? [:])

            return AnyCodable([
                "content": [
                    [
                        "type": "text",
                        "text": formattedText
                    ] as [String: Any]
                ] as [[String: Any]]
            ] as [String: Any])
        } else if name == "mcp_router/list_tools" {
            guard let serverName = arguments["server"]?.value as? String else {
                throw MCPError.toolNotFound("Missing 'server' parameter")
            }
            let result = try await handleListTools(serverName: serverName, workspace: workspace)
            let toolsData = result.value as? [String: Any]
            let formattedText = formatListToolsResult(toolsData ?? [:])

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
            let result = try await handleDescribe(toolPath: toolPath, workspace: workspace)
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

            // 查找 server 配置
            guard let config = serverConfigs.first(where: { $0.name == serverName }) else {
                throw MCPError.toolNotFound("Server '\(serverName)' not found")
            }

            // 根据类型调用
            if config.type == .http {
                // HTTP 类型
                guard let client = servers[serverName] else {
                    throw MCPError.toolNotFound("Server '\(serverName)' not found")
                }
                return try await client.callTool(name: toolName, arguments: convertedArgs)
            } else {
                // stdio 类型
                let workspaceToken = workspace?.token ?? "default"
                let stdioClient = try await stdioProcessPool.getOrCreateClient(
                    workspaceToken: workspaceToken,
                    config: config
                )
                return try await stdioClient.callTool(name: toolName, arguments: convertedArgs)
            }
        }

        // 不应该走到这里（所有工具都应该通过 mcp_router/call）
        throw MCPError.toolNotFound("Unknown tool: \(name). Please use mcp_router/call to invoke backend tools.")
    }

    // MARK: - Formatters

    private func formatListServersResult(_ result: [String: Any]) -> String {
        var lines = ["📋 可用的 MCP Servers:\n"]

        guard let serversList = result["servers"] as? [[String: Any]] else {
            return "无可用 Servers"
        }

        for serverData in serversList {
            guard let name = serverData["name"] as? String,
                  let description = serverData["description"] as? String,
                  let type = serverData["type"] as? String else {
                continue
            }

            lines.append("📦 **\(name)** (\(type)): \(description)")
        }

        lines.append("\n💡 下一步:")
        lines.append("  使用 mcp_router/list_tools 查看某个 Server 的工具列表")
        lines.append("  示例: mcp_router/list_tools {\"server\": \"chrome-devtools\"}")
        return lines.joined(separator: "\n")
    }

    private func formatListToolsResult(_ result: [String: Any]) -> String {
        guard let serverName = result["server"] as? String,
              let tools = result["tools"] as? [[String: Any]] else {
            return "无工具数据"
        }

        var lines = ["🔧 Server: \(serverName) 的工具列表 (\(tools.count) 个):\n"]

        for tool in tools {
            if let name = tool["name"] as? String,
               let description = tool["description"] as? String {
                let shortDesc = description.components(separatedBy: "\n").first ?? description
                lines.append("• **\(name)**: \(shortDesc.prefix(80))")
            }
        }

        lines.append("\n💡 下一步:")
        lines.append("  使用 mcp_router/describe 查看工具的详细参数")
        lines.append("  示例: mcp_router/describe {\"tool\": \"\(serverName)/tool_name\"}")
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
