//! Meta tools implementation (mcp_router__*)

use super::McpRouter;
use crate::config::Workspace;
use crate::protocol::{JsonRpcError, McpTool, ToolCallResult};
use serde_json::{json, Value};

/// Generate meta tools for the router
pub fn generate_meta_tools(
    router: &McpRouter,
    workspace: Option<&Workspace>,
    expose_management: bool,
) -> Vec<McpTool> {
    let effective_servers = router.get_effective_servers(workspace);
    let server_summary: String = effective_servers
        .iter()
        .map(|c| format!("- {}: {}", c.name, c.description))
        .collect::<Vec<_>>()
        .join("\n");

    let mut tools = vec![
        McpTool {
            name: "mcp_router__list_servers".to_string(),
            description: format!(
                r#"List all available MCP Servers

Loaded servers:
{}

Returns server list (without tool details to save tokens).
Use mcp_router__list_tools to view tools for a specific server."#,
                server_summary
            ),
            input_schema: Some(json!({
                "type": "object",
                "properties": {}
            })),
        },
        McpTool {
            name: "mcp_router__list_tools".to_string(),
            description: r#"List all tools for a specific server

Parameters:
- server: Server name (required)

Returns tool names and descriptions.
Use mcp_router__describe to view detailed parameters."#
                .to_string(),
            input_schema: Some(json!({
                "type": "object",
                "properties": {
                    "server": {
                        "type": "string",
                        "description": "Server name"
                    }
                },
                "required": ["server"]
            })),
        },
        McpTool {
            name: "mcp_router__describe".to_string(),
            description: r#"Get detailed parameter description for a tool

Parameters: { "tool": "server_name__tool_name" }
Example: { "tool": "context7__resolve-library-id" }"#
                .to_string(),
            input_schema: Some(json!({
                "type": "object",
                "properties": {
                    "tool": {
                        "type": "string",
                        "description": "Tool name, format: server_name__tool_name"
                    }
                },
                "required": ["tool"]
            })),
        },
        McpTool {
            name: "mcp_router__call".to_string(),
            description: r#"Unified entry point for calling backend MCP tools

IMPORTANT: Always use mcp_router__describe to check the parameter schema before calling!

Correct workflow:
1. mcp_router__list -> See available servers and tools
2. mcp_router__describe -> Check parameter definition for target tool
3. mcp_router__call -> Call with correct parameters based on schema

Parameter format:
{
  "tool": "server_name__tool_name",
  "arguments": { ...fill based on schema from describe... }
}"#
                .to_string(),
            input_schema: Some(json!({
                "type": "object",
                "properties": {
                    "tool": {
                        "type": "string",
                        "description": "Tool name, format: server_name__tool_name"
                    },
                    "arguments": {
                        "type": "object",
                        "description": "Arguments to pass to the tool",
                        "additionalProperties": true
                    }
                },
                "required": ["tool", "arguments"]
            })),
        },
    ];

    if expose_management {
        tools.extend(generate_management_tools());
    }

    tools
}

fn generate_management_tools() -> Vec<McpTool> {
    vec![
        McpTool {
            name: "mcp_router__add_server".to_string(),
            description: r#"Add a new MCP Server configuration

Supports two types:
- stdio: Local process (npx, uvx, node, python, etc.)
- http: Remote HTTP server

Parameters:
- name: Unique server name (required)
- type: "stdio" or "http" (required)
- description: Server description (optional)
- command: Command to run, for stdio type (required for stdio)
- args: Command arguments array, for stdio type (optional)
- env: Environment variables object, for stdio type (optional)
- url: Server URL, for http type (required for http)
- headers: HTTP headers object, for http type (optional)
- flattenMode: Whether to flatten tools (default: false)"#
                .to_string(),
            input_schema: Some(json!({
                "type": "object",
                "properties": {
                    "name": { "type": "string", "description": "Unique server name" },
                    "type": { "type": "string", "enum": ["stdio", "http"] },
                    "description": { "type": "string" },
                    "command": { "type": "string" },
                    "args": { "type": "array", "items": { "type": "string" } },
                    "env": { "type": "object", "additionalProperties": { "type": "string" } },
                    "url": { "type": "string" },
                    "headers": { "type": "object", "additionalProperties": { "type": "string" } },
                    "flattenMode": { "type": "boolean" }
                },
                "required": ["name", "type"]
            })),
        },
        McpTool {
            name: "mcp_router__remove_server".to_string(),
            description: r#"Remove an MCP Server configuration

Parameters:
- name: Server name to remove (required)

WARNING: This will permanently delete the server configuration."#
                .to_string(),
            input_schema: Some(json!({
                "type": "object",
                "properties": {
                    "name": { "type": "string", "description": "Server name to remove" }
                },
                "required": ["name"]
            })),
        },
        McpTool {
            name: "mcp_router__update_server".to_string(),
            description: r#"Update an existing MCP Server configuration

Parameters:
- name: Server name to update (required)
- description: New description (optional)
- enabled: Enable/disable server (optional)
- flattenMode: Enable/disable flatten mode (optional)

Only provided fields will be updated."#
                .to_string(),
            input_schema: Some(json!({
                "type": "object",
                "properties": {
                    "name": { "type": "string", "description": "Server name to update" },
                    "description": { "type": "string" },
                    "enabled": { "type": "boolean" },
                    "flattenMode": { "type": "boolean" }
                },
                "required": ["name"]
            })),
        },
    ]
}

/// Handle meta tool call
pub async fn handle_meta_tool_call(
    router: &McpRouter,
    name: &str,
    arguments: Value,
    workspace: Option<&Workspace>,
) -> Result<ToolCallResult, JsonRpcError> {
    match name {
        "mcp_router__list_servers" => handle_list_servers(router, workspace),
        "mcp_router__list_tools" => handle_list_tools(router, arguments, workspace).await,
        "mcp_router__describe" => handle_describe(router, arguments, workspace).await,
        "mcp_router__call" => handle_call(router, arguments, workspace).await,
        _ => Err(JsonRpcError::method_not_found(name)),
    }
}

fn handle_list_servers(
    router: &McpRouter,
    workspace: Option<&Workspace>,
) -> Result<ToolCallResult, JsonRpcError> {
    let effective_servers = router.get_effective_servers(workspace);

    let mut lines = vec!["Available MCP Servers:\n".to_string()];
    for config in effective_servers {
        lines.push(format!(
            "- **{}** ({}): {}",
            config.name,
            format!("{:?}", config.server_type).to_lowercase(),
            config.description
        ));
    }

    lines.push("\nAvailable actions:".to_string());
    lines.push("  - mcp_router__list_tools - View tools for a server".to_string());
    lines.push("  - mcp_router__describe - Get tool parameter details".to_string());
    lines.push("  - mcp_router__call - Call a tool".to_string());

    Ok(ToolCallResult::text(lines.join("\n")))
}

async fn handle_list_tools(
    router: &McpRouter,
    arguments: Value,
    workspace: Option<&Workspace>,
) -> Result<ToolCallResult, JsonRpcError> {
    let server_name = arguments
        .get("server")
        .and_then(|v| v.as_str())
        .ok_or_else(|| JsonRpcError::invalid_params("Missing 'server' parameter"))?;

    let _config = router
        .server_configs()
        .iter()
        .find(|c| c.name == server_name)
        .ok_or_else(|| JsonRpcError::new(-32602, format!("Server '{}' not found", server_name)))?;

    // 直接从服务器获取工具列表，不依赖 flatten_mode
    let tools = router
        .list_tools_for_server(server_name, workspace)
        .await
        .map_err(|e| JsonRpcError::new(-32603, e))?;

    let mut lines = vec![format!(
        "Tools for server '{}' ({} tools):\n",
        server_name,
        tools.len()
    )];

    for tool in &tools {
        let short_desc = tool
            .description
            .lines()
            .next()
            .unwrap_or(&tool.description);
        lines.push(format!(
            "- **{}**: {}",
            tool.name,
            short_desc.chars().take(80).collect::<String>()
        ));
    }

    lines.push("\nNext step:".to_string());
    lines.push(format!(
        "  Use mcp_router__describe to view detailed parameters"
    ));
    lines.push(format!(
        "  Example: mcp_router__describe {{\"tool\": \"{}__tool_name\"}}",
        server_name
    ));

    Ok(ToolCallResult::text(lines.join("\n")))
}

async fn handle_describe(
    router: &McpRouter,
    arguments: Value,
    workspace: Option<&Workspace>,
) -> Result<ToolCallResult, JsonRpcError> {
    let tool_path = arguments
        .get("tool")
        .and_then(|v| v.as_str())
        .ok_or_else(|| JsonRpcError::invalid_params("Missing 'tool' parameter"))?;

    let (server_name, tool_name) = router.resolve_tool_path(tool_path, workspace)?;

    // 直接从服务器获取工具列表
    let tools = router
        .list_tools_for_server(&server_name, workspace)
        .await
        .map_err(|e| JsonRpcError::new(-32603, e))?;

    let tool = tools
        .iter()
        .find(|t| t.name == tool_name)
        .ok_or_else(|| {
            JsonRpcError::new(
                -32602,
                format!("Tool '{}' not found in server '{}'", tool_name, server_name),
            )
        })?;

    let mut lines = vec![format!("Tool details: {}__{}\n", server_name, tool_name)];
    lines.push(format!("**Description**: {}\n", tool.description));

    if let Some(schema) = &tool.input_schema {
        lines.push("**Parameter Schema**:".to_string());
        lines.push("```json".to_string());
        lines.push(serde_json::to_string_pretty(schema).unwrap_or_default());
        lines.push("```".to_string());
    }

    lines.push("\n**How to call this tool**:".to_string());
    lines.push(format!("   Use tool name directly: **{}__{}**", server_name, tool_name));

    Ok(ToolCallResult::text(lines.join("\n")))
}

async fn handle_call(
    router: &McpRouter,
    arguments: Value,
    workspace: Option<&Workspace>,
) -> Result<ToolCallResult, JsonRpcError> {
    let tool_path = arguments
        .get("tool")
        .and_then(|v| v.as_str())
        .ok_or_else(|| JsonRpcError::invalid_params("Missing 'tool' parameter"))?;

    let tool_args = arguments
        .get("arguments")
        .cloned()
        .unwrap_or(json!({}));

    let (server_name, tool_name) = router.resolve_tool_path(tool_path, workspace)?;

    router
        .call_tool(&server_name, &tool_name, tool_args, workspace)
        .await
}
