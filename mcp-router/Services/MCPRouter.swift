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

    // Workspace token -> safe tool name -> (serverName, toolName)
    private var flattenedToolMaps: [String: [String: (server: String, tool: String)]] = [:]

    // Workspace 相关
    private var workspaces: [String: Workspace] = [:]  // token -> Workspace
    private var defaultWorkspace: Workspace?

    // stdio 进程池
    private var stdioProcessPool = WorkspaceProcessPool()

    // SwiftData 数据库容器（用于动态管理 Server）
    private var modelContainer: ModelContainer?

    private init() {}

    // MARK: - ModelContainer 注入

    /// 设置 ModelContainer，启用动态 Server 管理功能
    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
        print("✅ MCPRouter 已启用动态 Server 管理")
    }

    // MARK: - Helpers

    private func workspaceToken(for workspace: Workspace?) -> String {
        return workspace?.token ?? defaultWorkspace?.token ?? "default"
    }

    /// 将 server/tool 转换为符合 OpenAI 约束的安全名称，避免 `/`
    private func makeSafeToolName(serverName: String, toolName: String, existing: Set<String>) -> String {
        let raw = "\(serverName)__\(toolName)"
        let sanitized = raw.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )

        // 防止碰撞: 如果已有同名，追加序号
        var candidate = sanitized
        var index = 2
        while existing.contains(candidate) {
            candidate = "\(sanitized)_\(index)"
            index += 1
        }
        return candidate
    }

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

    /// 获取指定 Workspace 下所有需要平铺的 tools
    /// - Parameter workspace: 目标 Workspace，nil 使用默认 Workspace
    /// - Returns: 平铺的 MCPTool 数组，tool name 使用安全格式 {server_name}__{tool_name}
    func getFlattenedTools(for workspace: Workspace?) async -> [MCPTool] {
        let effectiveServers = getEffectiveServers(for: workspace)
        var flattenedTools: [MCPTool] = []
        var mapping: [String: (server: String, tool: String)] = [:]
        var usedNames = Set<String>()

        for server in effectiveServers {
            // 检查该 server 是否启用了平铺模式
            let isFlattenEnabled = workspace?.isFlattenEnabled(
                server.name,
                serverConfig: server,
                defaultWorkspace: defaultWorkspace
            ) ?? server.flattenMode

            guard isFlattenEnabled else {
                continue
            }

            // 获取该 server 的 tools
            do {
                let tools: [MCPTool]
                if server.type == .http {
                    // HTTP 类型
                    guard let client = servers[server.name] else {
                        print("⚠️ 跳过平铺: Server '\(server.name)' 未找到")
                        continue
                    }
                    tools = try await client.listTools()
                } else {
                    // stdio 类型
                    let workspaceToken = workspace?.token ?? "default"
                    let stdioClient = try await stdioProcessPool.getOrCreateClient(
                        workspaceToken: workspaceToken,
                        config: server
                    )
                    tools = try await stdioClient.listTools()
                }

                // 生成安全的工具名，格式 {server_name}__{tool_name}
                let prefixedTools = tools.map { tool -> MCPTool in
                    let safeName = makeSafeToolName(
                        serverName: server.name,
                        toolName: tool.name,
                        existing: usedNames
                    )
                    usedNames.insert(safeName)
                    mapping[safeName] = (server: server.name, tool: tool.name)
                    return MCPTool(
                        name: safeName,
                        description: tool.description,
                        inputSchema: tool.inputSchema
                    )
                }

                flattenedTools.append(contentsOf: prefixedTools)
                print("✅ 平铺 Server '\(server.name)' 的 \(prefixedTools.count) 个工具 (安全名)")
            } catch {
                print("⚠️ 获取 Server '\(server.name)' 的工具失败: \(error.localizedDescription)")
            }
        }

        // 保存映射，供调用/describe 使用
        let token = workspaceToken(for: workspace)
        flattenedToolMaps[token] = mapping

        print("📋 总共平铺了 \(flattenedTools.count) 个工具 (Workspace: \(token))")
        return flattenedTools
    }

    /// 将 toolPath 解析为 (server, tool)，支持安全名(server__tool)和旧格式(server/tool)
    private func resolveToolPath(_ toolPath: String, workspace: Workspace?) async throws -> (server: String, tool: String) {
        let token = workspaceToken(for: workspace)

        // 先查已缓存的安全名映射
        if let mapping = flattenedToolMaps[token],
           let entry = mapping[toolPath] {
            return entry
        }

        // 兼容旧格式 server/tool
        if toolPath.contains("/") {
            let parts = toolPath.split(separator: "/")
            guard parts.count == 2 else {
                throw MCPError.toolNotFound("Invalid tool path format: \(toolPath)")
            }
            return (server: String(parts[0]), tool: String(parts[1]))
        }

        // 尝试解析 server__tool 格式（即使映射中没有缓存，也能直接解析）
        if toolPath.contains("__") {
            let parts = toolPath.split(separator: "__", maxSplits: 1)
            if parts.count == 2 {
                return (server: String(parts[0]), tool: String(parts[1]))
            }
        }

        // 尝试刷新平铺列表后再查一次
        _ = await getFlattenedTools(for: workspace)
        if let mapping = flattenedToolMaps[token],
           let entry = mapping[toolPath] {
            return entry
        }

        throw MCPError.toolNotFound("Tool '\(toolPath)' not found")
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
    func generateRouterTools(for workspace: Workspace? = nil, exposeManagementTools: Bool = false) -> [MCPTool] {
        let effectiveServers = getEffectiveServers(for: workspace)
        let serverSummary = effectiveServers.map { config in
            "• \(config.name): \(config.serverDescription)"
        }.joined(separator: "\n")

        var tools: [MCPTool] = [
            MCPTool(
                name: "mcp_router__list_servers",
                description: """
                📋 List all available MCP Servers

                Loaded servers:
                \(serverSummary)

                Returns server list (without tool details to save tokens).
                Use mcp_router__list_tools to view tools for a specific server.
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([:])
                ]
            ),
            MCPTool(
                name: "mcp_router__list_tools",
                description: """
                🔧 List all tools for a specific server

                Parameters:
                - server: Server name (required)

                Returns tool names and descriptions.
                Use mcp_router__describe to view detailed parameters.
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "server": [
                            "type": "string",
                            "description": "Server name"
                        ] as [String: Any]
                    ]),
                    "required": AnyCodable(["server"])
                ]
            ),
            MCPTool(
                name: "mcp_router__describe",
                description: """
                📖 Get detailed parameter description for a tool

                Parameters: { "tool": "server_name__tool_name" }
                Example: { "tool": "context7__resolve-library-id" }
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "tool": [
                            "type": "string",
                            "description": "Tool name, format: server_name__tool_name"
                        ] as [String: Any]
                    ]),
                    "required": AnyCodable(["tool"])
                ]
            ),
            MCPTool(
                name: "mcp_router__call",
                description: """
                🚀 Unified entry point for calling backend MCP tools

                ⚠️ IMPORTANT: Always use mcp_router__describe to check the parameter schema before calling!

                Correct workflow:
                1. mcp_router__list → See available servers and tools
                2. mcp_router__describe → Check parameter definition for target tool
                3. mcp_router__call → Call with correct parameters based on schema

                Parameter format:
                {
                  "tool": "server_name__tool_name",
                  "arguments": { ...fill based on schema from describe... }
                }

                Example:
                {
                  "tool": "context7__resolve-library-id",
                  "arguments": { ...first use describe to check required parameters... }
                }
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "tool": [
                            "type": "string",
                            "description": "Tool name, format: server_name__tool_name"
                        ] as [String: Any],
                        "arguments": [
                            "type": "object",
                            "description": "Arguments to pass to the tool (must check parameter definition with mcp_router__describe first)",
                            "additionalProperties": true
                        ] as [String: Any]
                    ] as [String: [String: Any]]),
                    "required": AnyCodable(["tool", "arguments"])
                ]
            )
        ]

        // 只在 Full 模式下暴露管理工具
        if exposeManagementTools {
            tools.append(contentsOf: [
                // MARK: - Server 管理工具

                MCPTool(
                name: "mcp_router__add_server",
                description: """
                ➕ Add a new MCP Server configuration

                Supports two types:
                • stdio: Local process (npx, uvx, node, python, etc.)
                • http: Remote HTTP server

                Parameters:
                - name: Unique server name (required)
                - type: "stdio" or "http" (required)
                - description: Server description (optional)
                - command: Command to run, for stdio type (required for stdio)
                - args: Command arguments array, for stdio type (optional)
                - env: Environment variables object, for stdio type (optional)
                - url: Server URL, for http type (required for http)
                - headers: HTTP headers object, for http type (optional)
                - flattenMode: Whether to flatten tools (default: false)

                Example (stdio):
                {
                  "name": "filesystem",
                  "type": "stdio",
                  "description": "File system access",
                  "command": "npx",
                  "args": ["-y", "@anthropic/mcp-server-filesystem", "/path/to/dir"]
                }

                Example (http):
                {
                  "name": "my-api",
                  "type": "http",
                  "url": "http://localhost:8080/mcp",
                  "description": "My custom MCP server"
                }
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "name": [
                            "type": "string",
                            "description": "Unique server name"
                        ] as [String: Any],
                        "type": [
                            "type": "string",
                            "enum": ["stdio", "http"],
                            "description": "Server type: stdio or http"
                        ] as [String: Any],
                        "description": [
                            "type": "string",
                            "description": "Server description"
                        ] as [String: Any],
                        "command": [
                            "type": "string",
                            "description": "Command to run (for stdio type)"
                        ] as [String: Any],
                        "args": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Command arguments (for stdio type)"
                        ] as [String: Any],
                        "env": [
                            "type": "object",
                            "additionalProperties": ["type": "string"],
                            "description": "Environment variables (for stdio type)"
                        ] as [String: Any],
                        "url": [
                            "type": "string",
                            "description": "Server URL (for http type)"
                        ] as [String: Any],
                        "headers": [
                            "type": "object",
                            "additionalProperties": ["type": "string"],
                            "description": "HTTP headers (for http type)"
                        ] as [String: Any],
                        "flattenMode": [
                            "type": "boolean",
                            "description": "Whether to flatten tools directly to AI"
                        ] as [String: Any]
                    ] as [String: [String: Any]]),
                    "required": AnyCodable(["name", "type"])
                ]
            ),
            MCPTool(
                name: "mcp_router__remove_server",
                description: """
                ➖ Remove an MCP Server configuration

                Parameters:
                - name: Server name to remove (required)

                ⚠️ This will permanently delete the server configuration.
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "name": [
                            "type": "string",
                            "description": "Server name to remove"
                        ] as [String: Any]
                    ] as [String: [String: Any]]),
                    "required": AnyCodable(["name"])
                ]
            ),
            MCPTool(
                name: "mcp_router__update_server",
                description: """
                ✏️ Update an existing MCP Server configuration

                Parameters:
                - name: Server name to update (required)
                - description: New description (optional)
                - enabled: Enable/disable server (optional)
                - flattenMode: Enable/disable flatten mode (optional)
                - command: New command, for stdio type (optional)
                - args: New arguments, for stdio type (optional)
                - env: New environment variables, for stdio type (optional)
                - url: New URL, for http type (optional)
                - headers: New headers, for http type (optional)

                Only provided fields will be updated.
                """,
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "name": [
                            "type": "string",
                            "description": "Server name to update"
                        ] as [String: Any],
                        "description": [
                            "type": "string",
                            "description": "New server description"
                        ] as [String: Any],
                        "enabled": [
                            "type": "boolean",
                            "description": "Enable or disable the server"
                        ] as [String: Any],
                        "flattenMode": [
                            "type": "boolean",
                            "description": "Enable or disable flatten mode"
                        ] as [String: Any],
                        "command": [
                            "type": "string",
                            "description": "New command (for stdio type)"
                        ] as [String: Any],
                        "args": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "New arguments (for stdio type)"
                        ] as [String: Any],
                        "env": [
                            "type": "object",
                            "additionalProperties": ["type": "string"],
                            "description": "New environment variables (for stdio type)"
                        ] as [String: Any],
                        "url": [
                            "type": "string",
                            "description": "New URL (for http type)"
                        ] as [String: Any],
                        "headers": [
                            "type": "object",
                            "additionalProperties": ["type": "string"],
                            "description": "New headers (for http type)"
                        ] as [String: Any]
                    ] as [String: [String: Any]]),
                    "required": AnyCodable(["name"])
                ]
            )
            ])
        }

        return tools
    }

    // MARK: - Tool Handlers

    /// 处理 mcp_router__list_servers - 只返回 Server 列表(不含工具)
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

    /// 处理 mcp_router__list_tools - 返回指定 Server 的工具列表
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

    /// 处理 mcp_router__describe
    func handleDescribe(toolPath: String, workspace: Workspace?) async throws -> String {
        let resolved = try await resolveToolPath(toolPath, workspace: workspace)
        let serverName = resolved.server
        let toolName = resolved.tool

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
        if name == "mcp_router__list_servers" {
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
        } else if name == "mcp_router__list_tools" {
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
        } else if name == "mcp_router__describe" {
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
        } else if name == "mcp_router__call" {
            // 统一的工具调用入口
            guard let toolPath = arguments["tool"]?.value as? String else {
                throw MCPError.toolNotFound("Missing 'tool' parameter")
            }

            let toolArgs = arguments["arguments"]?.value as? [String: Any] ?? [:]
            let convertedArgs = toolArgs.mapValues { AnyCodable($0) }

            // 解析 tool path (支持安全名 server__tool)
            let resolved = try await resolveToolPath(toolPath, workspace: workspace)
            let serverName = resolved.server
            let toolName = resolved.tool

            // 查找 server 配置
            guard let config = serverConfigs.first(where: { $0.name == serverName }) else {
                // Server 不存在,返回友好的错误提示
                return formatServerNotFoundError(serverName: serverName, workspace: workspace)
            }

            // 尝试调用工具,捕获参数错误并返回友好提示
            do {
                // 根据类型调用
                let result: AnyCodable
                if config.type == .http {
                    // HTTP 类型
                    guard let client = servers[serverName] else {
                        throw MCPError.toolNotFound("Server '\(serverName)' not found")
                    }
                    result = try await client.callTool(name: toolName, arguments: convertedArgs)
                } else {
                    // stdio 类型
                    let workspaceToken = workspace?.token ?? "default"
                    let stdioClient = try await stdioProcessPool.getOrCreateClient(
                        workspaceToken: workspaceToken,
                        config: config
                    )
                    result = try await stdioClient.callTool(name: toolName, arguments: convertedArgs)
                }

                // 检查返回结果是否包含参数错误(某些 MCP server 会在 result 中返回错误文本)
                if let resultDict = result.value as? [String: Any],
                   let content = resultDict["content"] as? [[String: Any]],
                   let firstContent = content.first,
                   let text = firstContent["text"] as? String {
                    // 检查是否为参数验证错误
                    let lowerText = text.lowercased()
                    if lowerText.contains("mcp error -32602") ||
                       (lowerText.contains("input validation error") && lowerText.contains("invalid arguments")) {
                        // 这是参数错误,创建一个 MCPError 并格式化
                        let error = MCPError.rpcError(-32602, text)
                        return await formatToolCallError(
                            serverName: serverName,
                            toolName: toolName,
                            error: error,
                            workspace: workspace
                        )
                    }
                }

                return result
            } catch {
                // 捕获所有错误,返回友好的错误提示
                return await formatToolCallError(
                    serverName: serverName,
                    toolName: toolName,
                    error: error,
                    workspace: workspace
                )
            }
        } else if name == "mcp_router__add_server" {
            // 添加 Server
            let result = try await handleAddServer(arguments: arguments)
            return AnyCodable([
                "content": [
                    [
                        "type": "text",
                        "text": result
                    ] as [String: Any]
                ] as [[String: Any]]
            ] as [String: Any])
        } else if name == "mcp_router__remove_server" {
            // 删除 Server
            guard let serverName = arguments["name"]?.value as? String else {
                throw MCPError.rpcError(-32602, "Missing 'name' parameter")
            }
            let result = try await handleRemoveServer(name: serverName)
            return AnyCodable([
                "content": [
                    [
                        "type": "text",
                        "text": result
                    ] as [String: Any]
                ] as [[String: Any]]
            ] as [String: Any])
        } else if name == "mcp_router__update_server" {
            // 更新 Server
            let result = try await handleUpdateServer(arguments: arguments)
            return AnyCodable([
                "content": [
                    [
                        "type": "text",
                        "text": result
                    ] as [String: Any]
                ] as [[String: Any]]
            ] as [String: Any])
        }

        // 不应该走到这里（所有工具都应该通过 mcp_router__call）
        throw MCPError.toolNotFound("Unknown tool: \(name). Please use mcp_router__call to invoke backend tools.")
    }

    // MARK: - Formatters

    private func formatListServersResult(_ result: [String: Any]) -> String {
        var lines = ["📋 Available MCP Servers:\n"]

        guard let serversList = result["servers"] as? [[String: Any]] else {
            return "No available servers"
        }

        for serverData in serversList {
            guard let name = serverData["name"] as? String,
                  let description = serverData["description"] as? String,
                  let type = serverData["type"] as? String else {
                continue
            }

            lines.append("📦 **\(name)** (\(type)): \(description)")
        }

        lines.append("\n💡 Available actions:")
        lines.append("  • mcp_router__list_tools - View tools for a server")
        lines.append("  • mcp_router__add_server - Add a new MCP server")
        lines.append("  • mcp_router__remove_server - Remove a server")
        lines.append("  • mcp_router__update_server - Update server config")
        return lines.joined(separator: "\n")
    }

    private func formatListToolsResult(_ result: [String: Any]) -> String {
        guard let serverName = result["server"] as? String,
              let tools = result["tools"] as? [[String: Any]] else {
            return "No tool data"
        }

        var lines = ["🔧 Tool list for server: \(serverName) (\(tools.count) tools):\n"]

        for tool in tools {
            if let name = tool["name"] as? String,
               let description = tool["description"] as? String {
                let shortDesc = description.components(separatedBy: "\n").first ?? description
                lines.append("• **\(name)**: \(shortDesc.prefix(80))")
            }
        }

        lines.append("\n💡 Next step:")
        lines.append("  Use mcp_router__describe to view detailed parameters")
        lines.append("  Example: mcp_router__describe {\"tool\": \"\(serverName)__tool_name\"}")
        return lines.joined(separator: "\n")
    }

    private func formatToolDetail(serverName: String, tool: MCPTool) -> String {
        var lines = ["📖 Tool details: \(serverName)__\(tool.name)\n"]
        lines.append("**Description**: \(tool.description)\n")

        if let schema = tool.inputSchema {
            lines.append("**Parameter Schema**:")
            if let jsonData = try? JSONSerialization.data(withJSONObject: schema.mapValues { $0.value }),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                lines.append("```json")
                lines.append(jsonString)
                lines.append("```")
            }
        }

        lines.append("\n💡 **How to call this tool**:")
        lines.append("   Use tool name directly: **\(serverName)__\(tool.name)**")
        lines.append("")
        lines.append("   Example:")
        lines.append("   Call tool: \(serverName)__\(tool.name)")
        lines.append("   With parameters: { \"param_name\": \"param_value\" }")
        return lines.joined(separator: "\n")
    }

    /// Format friendly error for server not found
    private func formatServerNotFoundError(serverName: String, workspace: Workspace?) -> AnyCodable {
        let effectiveServers = getEffectiveServers(for: workspace)
        let availableServers = effectiveServers.map { "  • \($0.name)" }.joined(separator: "\n")

        let errorMessage = """
        ❌ Server '\(serverName)' does not exist

        💡 Recommended workflow:

        1️⃣ Use mcp_router__list_servers to view available MCP servers
           Currently available servers:
        \(availableServers.isEmpty ? "  (No available servers)" : availableServers)

        2️⃣ Use mcp_router__list_tools to view tool list for a specific server
           Example:
           Tool: mcp_router__list_tools
           Parameters: { "server": "server_name" }

        3️⃣ Use mcp_router__describe to view parameter definition for a tool
           Example:
           Tool: mcp_router__describe
           Parameters: { "tool": "server_name/tool_name" }

        4️⃣ Use mcp_router__call to call the tool
           Example:
           Tool: mcp_router__call
           Parameters: {
             "tool": "server_name/tool_name",
             "arguments": { ...fill based on schema from describe... }
           }
        """

        return AnyCodable([
            "content": [
                [
                    "type": "text",
                    "text": errorMessage
                ] as [String: Any]
            ] as [[String: Any]],
            "isError": true
        ] as [String: Any])
    }

    /// 格式化工具调用错误的友好提示
    private func formatToolCallError(
        serverName: String,
        toolName: String,
        error: Error,
        workspace: Workspace?
    ) async -> AnyCodable {
        // 提取完整的错误信息
        let fullErrorMessage: String
        if let mcpError = error as? MCPError,
           case .rpcError(let code, let message) = mcpError {
            // 保留完整的后端错误信息
            fullErrorMessage = message
        } else {
            fullErrorMessage = error.localizedDescription
        }

        // 检查是否为参数错误(通常包含 "invalid"、"required"、"expected" 等关键词)
        let errorDesc = fullErrorMessage.lowercased()
        let isParameterError = errorDesc.contains("invalid") ||
                               errorDesc.contains("required") ||
                               errorDesc.contains("expected") ||
                               errorDesc.contains("schema") ||
                               errorDesc.contains("type") ||
                               errorDesc.contains("zod")

        var errorMessage = "❌ Failed to call tool '\(serverName)/\(toolName)'\n\n"

        if isParameterError {
            // Auto-fetch tool schema
            let schemaText: String
            do {
                schemaText = try await handleDescribe(
                    toolPath: "\(serverName)/\(toolName)",
                    workspace: workspace
                )
            } catch {
                schemaText = "(Unable to fetch tool schema: \(error.localizedDescription))"
            }

            errorMessage += """
            🔍 Parameter error or incorrect format

            📋 Backend error message:
            \(fullErrorMessage)

            📖 Correct parameter definition for this tool:

            \(schemaText)

            💡 Recommended actions:
            1. Carefully review the parameter definition (JSON Schema) above
            2. If you need more details, use mcp_router__describe to view again
            3. Fix parameters according to the definition and retry
            """
        } else {
            errorMessage += """
            📋 Backend error message:
            \(fullErrorMessage)

            💡 Suggested next steps:

            • Review the error message above
            • Verify your input parameters are correct
            • Use mcp_router__describe to check parameter requirements:
              { "tool": "\(serverName)/\(toolName)" }
            """
        }

        return AnyCodable([
            "content": [
                [
                    "type": "text",
                    "text": errorMessage
                ] as [String: Any]
            ] as [[String: Any]],
            "isError": true
        ] as [String: Any])
    }

    // MARK: - Server 管理方法

    /// 添加新的 Server 配置
    @MainActor
    private func handleAddServer(arguments: [String: AnyCodable]) async throws -> String {
        guard let container = modelContainer else {
            throw MCPError.rpcError(-32603, "Database not available. Server management is disabled.")
        }

        // 解析参数
        guard let name = arguments["name"]?.value as? String else {
            throw MCPError.rpcError(-32602, "Missing required parameter: 'name'")
        }
        guard let typeStr = arguments["type"]?.value as? String,
              let serverType = ServerType(rawValue: typeStr) else {
            throw MCPError.rpcError(-32602, "Missing or invalid parameter: 'type' (must be 'stdio' or 'http')")
        }

        let context = container.mainContext

        // 检查是否已存在同名 Server
        let descriptor = FetchDescriptor<ServerConfig>(
            predicate: #Predicate { $0.name == name }
        )
        let existing = try context.fetch(descriptor)
        if !existing.isEmpty {
            throw MCPError.rpcError(-32602, "Server '\(name)' already exists. Use mcp_router__update_server to modify it.")
        }

        // 验证类型特定的必填参数
        if serverType == .stdio {
            guard let _ = arguments["command"]?.value as? String else {
                throw MCPError.rpcError(-32602, "Missing required parameter for stdio type: 'command'")
            }
        } else if serverType == .http {
            guard let _ = arguments["url"]?.value as? String else {
                throw MCPError.rpcError(-32602, "Missing required parameter for http type: 'url'")
            }
        }

        // 创建新的 ServerConfig
        let description = arguments["description"]?.value as? String ?? ""
        let command = arguments["command"]?.value as? String
        let args = arguments["args"]?.value as? [String] ?? []
        let env = arguments["env"]?.value as? [String: String] ?? [:]
        let url = arguments["url"]?.value as? String
        let headers = arguments["headers"]?.value as? [String: String] ?? [:]
        let flattenMode = arguments["flattenMode"]?.value as? Bool ?? false

        let newServer = ServerConfig(
            name: name,
            type: serverType,
            description: description,
            url: url,
            headers: headers,
            command: command,
            args: args,
            env: env,
            isEnabled: true,
            flattenMode: flattenMode
        )

        context.insert(newServer)
        try context.save()

        // 更新内存中的配置
        serverConfigs.append(newServer)

        // 如果是 HTTP 类型，创建 Client
        if serverType == .http {
            let client = MCPClient(config: newServer)
            servers[name] = client
        }

        // 发送通知触发热重载
        NotificationCenter.default.post(name: .serverConfigDidChange, object: nil)

        print("✅ 通过 MCP 添加了 Server: \(name)")

        return """
        ✅ Successfully added server '\(name)'

        Configuration:
        • Name: \(name)
        • Type: \(serverType.rawValue)
        • Description: \(description.isEmpty ? "(none)" : description)
        \(serverType == .stdio ? "• Command: \(command ?? "")" : "• URL: \(url ?? "")")
        • Flatten Mode: \(flattenMode ? "enabled" : "disabled")
        • Status: enabled

        The server is now available. Use mcp_router__list_servers to verify.
        """
    }

    /// 删除 Server 配置
    @MainActor
    private func handleRemoveServer(name: String) async throws -> String {
        guard let container = modelContainer else {
            throw MCPError.rpcError(-32603, "Database not available. Server management is disabled.")
        }

        let context = container.mainContext

        // 查找要删除的 Server
        let descriptor = FetchDescriptor<ServerConfig>(
            predicate: #Predicate { $0.name == name }
        )
        let results = try context.fetch(descriptor)

        guard let serverToDelete = results.first else {
            throw MCPError.rpcError(-32602, "Server '\(name)' not found")
        }

        let serverType = serverToDelete.type

        // 从数据库删除
        context.delete(serverToDelete)
        try context.save()

        // 从内存中移除
        serverConfigs.removeAll { $0.name == name }
        servers.removeValue(forKey: name)

        // 发送通知触发热重载
        NotificationCenter.default.post(name: .serverConfigDidChange, object: nil)

        print("✅ 通过 MCP 删除了 Server: \(name)")

        return """
        ✅ Successfully removed server '\(name)'

        The server configuration has been permanently deleted.
        Type: \(serverType.rawValue)

        Use mcp_router__list_servers to verify the current server list.
        """
    }

    /// 更新 Server 配置
    @MainActor
    private func handleUpdateServer(arguments: [String: AnyCodable]) async throws -> String {
        guard let container = modelContainer else {
            throw MCPError.rpcError(-32603, "Database not available. Server management is disabled.")
        }

        guard let name = arguments["name"]?.value as? String else {
            throw MCPError.rpcError(-32602, "Missing required parameter: 'name'")
        }

        let context = container.mainContext

        // 查找要更新的 Server
        let descriptor = FetchDescriptor<ServerConfig>(
            predicate: #Predicate { $0.name == name }
        )
        let results = try context.fetch(descriptor)

        guard let server = results.first else {
            throw MCPError.rpcError(-32602, "Server '\(name)' not found")
        }

        var updates: [String] = []

        // 更新各字段（只更新提供的参数）
        if let description = arguments["description"]?.value as? String {
            server.serverDescription = description
            updates.append("description")
        }

        if let enabled = arguments["enabled"]?.value as? Bool {
            server.isEnabled = enabled
            updates.append("enabled = \(enabled)")
        }

        if let flattenMode = arguments["flattenMode"]?.value as? Bool {
            server.flattenMode = flattenMode
            updates.append("flattenMode = \(flattenMode)")
        }

        // stdio 类型特有字段
        if server.type == .stdio {
            if let command = arguments["command"]?.value as? String {
                server.command = command
                updates.append("command")
            }
            if let args = arguments["args"]?.value as? [String] {
                server.args = args
                updates.append("args")
            }
            if let env = arguments["env"]?.value as? [String: String] {
                server.env = env
                updates.append("env")
            }
        }

        // http 类型特有字段
        if server.type == .http {
            if let url = arguments["url"]?.value as? String {
                server.url = url
                updates.append("url")
            }
            if let headers = arguments["headers"]?.value as? [String: String] {
                server.headers = headers
                updates.append("headers")
            }
        }

        if updates.isEmpty {
            return """
            ⚠️ No updates applied to server '\(name)'

            No valid update parameters were provided.
            Available parameters:
            • description, enabled, flattenMode
            • For stdio: command, args, env
            • For http: url, headers
            """
        }

        try context.save()

        // 更新内存中的配置
        if let index = serverConfigs.firstIndex(where: { $0.name == name }) {
            serverConfigs[index] = server
        }

        // 如果是 HTTP 类型且 URL 变化，重新创建 Client
        if server.type == .http && updates.contains("url") {
            let client = MCPClient(config: server)
            servers[name] = client
        }

        // 发送通知触发热重载
        NotificationCenter.default.post(name: .serverConfigDidChange, object: nil)

        print("✅ 通过 MCP 更新了 Server: \(name)")

        return """
        ✅ Successfully updated server '\(name)'

        Updated fields: \(updates.joined(separator: ", "))

        Current configuration:
        • Name: \(server.name)
        • Type: \(server.type.rawValue)
        • Description: \(server.serverDescription.isEmpty ? "(none)" : server.serverDescription)
        • Status: \(server.isEnabled ? "enabled" : "disabled")
        • Flatten Mode: \(server.flattenMode ? "enabled" : "disabled")

        Use mcp_router__list_servers to verify the changes.
        """
    }
}
