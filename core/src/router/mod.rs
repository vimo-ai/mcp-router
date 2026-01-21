//! MCP Router core logic
//!
//! Manages multiple MCP servers and provides unified interface

pub mod meta_tools;

use crate::client::{HttpMcpClient, StdioMcpClient};
use crate::config::{ServerConfig, ServerType, Workspace};
use crate::protocol::{JsonRpcError, McpTool, ToolCallResult};
use dashmap::DashMap;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;

/// MCP Router - manages multiple MCP servers
pub struct McpRouter {
    /// Server configurations
    server_configs: Vec<ServerConfig>,

    /// HTTP clients (server_name -> client)
    http_clients: DashMap<String, Arc<HttpMcpClient>>,

    /// Stdio clients (workspace_token::server_name -> client)
    stdio_clients: DashMap<String, Arc<StdioMcpClient>>,

    /// Workspaces (token -> workspace)
    workspaces: DashMap<String, Workspace>,

    /// Default workspace
    default_workspace: Option<Workspace>,

    /// Flattened tool mapping (workspace_token -> safe_name -> (server, tool))
    flattened_tool_maps: DashMap<String, HashMap<String, (String, String)>>,

    /// Settings
    expose_management_tools: bool,
}

impl McpRouter {
    pub fn new() -> Self {
        Self {
            server_configs: Vec::new(),
            http_clients: DashMap::new(),
            stdio_clients: DashMap::new(),
            workspaces: DashMap::new(),
            default_workspace: Some(Workspace::default_workspace()),
            flattened_tool_maps: DashMap::new(),
            expose_management_tools: false,
        }
    }

    pub fn set_expose_management_tools(&mut self, expose: bool) {
        self.expose_management_tools = expose;
    }

    pub fn expose_management_tools(&self) -> bool {
        self.expose_management_tools
    }

    // MARK: - Server Management

    /// Load server configurations
    pub fn load_servers(&mut self, configs: Vec<ServerConfig>) {
        self.server_configs = configs;

        // Create HTTP clients for HTTP type servers
        for config in &self.server_configs {
            if config.server_type == ServerType::Http && config.is_enabled {
                if let Some(url) = &config.url {
                    let client = HttpMcpClient::new(config.name.clone(), url.clone());
                    self.http_clients.insert(config.name.clone(), Arc::new(client));
                }
            }
        }

        tracing::info!("Loaded {} server configs", self.server_configs.len());
    }

    /// Add a single server configuration
    pub fn add_server(&mut self, config: ServerConfig) {
        // Remove existing server with same name if exists
        self.remove_server(&config.name);

        // Add HTTP client if needed
        if config.server_type == ServerType::Http && config.is_enabled {
            if let Some(url) = &config.url {
                let client = HttpMcpClient::new(config.name.clone(), url.clone());
                self.http_clients.insert(config.name.clone(), Arc::new(client));
            }
        }

        self.server_configs.push(config);
    }

    /// Remove a server by name
    pub fn remove_server(&mut self, name: &str) -> bool {
        let before_len = self.server_configs.len();
        self.server_configs.retain(|c| c.name != name);
        self.http_clients.remove(name);
        self.stdio_clients.remove(name);
        before_len != self.server_configs.len()
    }

    /// Update server enabled status
    pub fn set_server_enabled(&mut self, name: &str, enabled: bool) {
        if let Some(config) = self.server_configs.iter_mut().find(|c| c.name == name) {
            config.is_enabled = enabled;

            if enabled && config.server_type == ServerType::Http {
                if let Some(url) = &config.url {
                    let client = HttpMcpClient::new(config.name.clone(), url.clone());
                    self.http_clients.insert(config.name.clone(), Arc::new(client));
                }
            } else if !enabled {
                self.http_clients.remove(name);
            }
        }
    }

    /// Update server flatten mode
    pub fn set_server_flatten_mode(&mut self, name: &str, flatten: bool) {
        if let Some(config) = self.server_configs.iter_mut().find(|c| c.name == name) {
            config.flatten_mode = flatten;
        }
    }

    /// Update server description
    pub fn set_server_description(&mut self, name: &str, description: &str) {
        if let Some(config) = self.server_configs.iter_mut().find(|c| c.name == name) {
            config.description = description.to_string();
        }
    }

    /// Get server count
    pub fn server_count(&self) -> usize {
        self.server_configs.len()
    }

    /// Get enabled server count
    pub fn enabled_server_count(&self) -> usize {
        self.server_configs.iter().filter(|c| c.is_enabled).count()
    }

    /// Load workspaces
    pub fn load_workspaces(&mut self, workspaces: Vec<Workspace>) {
        for ws in workspaces {
            if ws.is_default {
                self.default_workspace = Some(ws.clone());
            }
            self.workspaces.insert(ws.token.clone(), ws);
        }

        tracing::info!("Loaded {} workspaces", self.workspaces.len());
    }

    /// Find workspace by token
    pub fn find_workspace(&self, token: Option<&str>) -> Option<Workspace> {
        if let Some(token) = token {
            if let Some(ws) = self.workspaces.get(token) {
                return Some(ws.clone());
            }
        }
        self.default_workspace.clone()
    }

    /// Get effective servers for a workspace
    pub fn get_effective_servers(&self, workspace: Option<&Workspace>) -> Vec<&ServerConfig> {
        self.server_configs
            .iter()
            .filter(|config| {
                if let Some(ws) = workspace {
                    ws.is_server_enabled(&config.name, config)
                } else {
                    config.is_enabled
                }
            })
            .collect()
    }

    // MARK: - Tool Resolution

    /// Generate safe tool name (server__tool format)
    fn make_safe_tool_name(
        server_name: &str,
        tool_name: &str,
        existing: &mut std::collections::HashSet<String>,
    ) -> String {
        let raw = format!("{}__{}", server_name, tool_name);
        let sanitized: String = raw
            .chars()
            .map(|c| {
                if c.is_alphanumeric() || c == '_' || c == '-' {
                    c
                } else {
                    '_'
                }
            })
            .collect();

        let mut candidate = sanitized.clone();
        let mut index = 2;
        while existing.contains(&candidate) {
            candidate = format!("{}_{}", sanitized, index);
            index += 1;
        }

        existing.insert(candidate.clone());
        candidate
    }

    /// Resolve tool path to (server, tool)
    pub fn resolve_tool_path(
        &self,
        tool_path: &str,
        workspace: Option<&Workspace>,
    ) -> Result<(String, String), JsonRpcError> {
        let token = workspace
            .map(|w| w.token.as_str())
            .unwrap_or("default");

        // Check cached mapping
        if let Some(mapping) = self.flattened_tool_maps.get(token) {
            if let Some((server, tool)) = mapping.get(tool_path) {
                return Ok((server.clone(), tool.clone()));
            }
        }

        // Try parsing server/tool format
        if tool_path.contains('/') {
            let parts: Vec<&str> = tool_path.splitn(2, '/').collect();
            if parts.len() == 2 {
                return Ok((parts[0].to_string(), parts[1].to_string()));
            }
        }

        // Try parsing server__tool format
        if tool_path.contains("__") {
            let parts: Vec<&str> = tool_path.splitn(2, "__").collect();
            if parts.len() == 2 {
                return Ok((parts[0].to_string(), parts[1].to_string()));
            }
        }

        Err(JsonRpcError::new(
            -32602,
            format!("Tool '{}' not found", tool_path),
        ))
    }

    // MARK: - Tool Listing

    /// Get flattened tools for a workspace
    pub async fn get_flattened_tools(&self, workspace: Option<&Workspace>) -> Vec<McpTool> {
        let effective_servers = self.get_effective_servers(workspace);
        let mut flattened_tools = Vec::new();
        let mut mapping: HashMap<String, (String, String)> = HashMap::new();
        let mut used_names = std::collections::HashSet::new();

        for config in effective_servers {
            let is_flatten_enabled = workspace
                .map(|ws| ws.is_flatten_enabled(&config.name, config))
                .unwrap_or(config.flatten_mode);

            if !is_flatten_enabled {
                continue;
            }

            let tools = match self.list_server_tools(config, workspace).await {
                Ok(tools) => tools,
                Err(e) => {
                    tracing::warn!("Failed to get tools from {}: {}", config.name, e);
                    continue;
                }
            };

            for tool in tools {
                let safe_name =
                    Self::make_safe_tool_name(&config.name, &tool.name, &mut used_names);
                mapping.insert(safe_name.clone(), (config.name.clone(), tool.name.clone()));

                flattened_tools.push(McpTool {
                    name: safe_name,
                    description: tool.description,
                    input_schema: tool.input_schema,
                });
            }
        }

        // Cache the mapping
        let token = workspace
            .map(|w| w.token.clone())
            .unwrap_or_else(|| "default".to_string());
        self.flattened_tool_maps.insert(token, mapping);

        tracing::info!("Flattened {} tools", flattened_tools.len());
        flattened_tools
    }

    /// List tools for a specific server by name (public API)
    pub async fn list_tools_for_server(
        &self,
        server_name: &str,
        workspace: Option<&Workspace>,
    ) -> Result<Vec<McpTool>, String> {
        let config = self
            .server_configs
            .iter()
            .find(|c| c.name == server_name)
            .ok_or_else(|| format!("Server '{}' not found", server_name))?;

        self.list_server_tools(config, workspace).await
    }

    /// List tools from a specific server
    async fn list_server_tools(
        &self,
        config: &ServerConfig,
        workspace: Option<&Workspace>,
    ) -> Result<Vec<McpTool>, String> {
        match config.server_type {
            ServerType::Http => {
                if let Some(client) = self.http_clients.get(&config.name) {
                    client
                        .list_tools()
                        .await
                        .map_err(|e| format!("{}", e))
                } else {
                    Err(format!("HTTP client not found: {}", config.name))
                }
            }
            ServerType::Stdio => {
                let token = workspace
                    .map(|w| w.token.as_str())
                    .unwrap_or("default");
                let key = format!("{}::{}", token, config.name);

                if let Some(client) = self.stdio_clients.get(&key) {
                    client
                        .list_tools()
                        .await
                        .map_err(|e| format!("{}", e))
                } else {
                    // Create new stdio client
                    let client = StdioMcpClient::new(config.clone());
                    if let Err(e) = client.start().await {
                        return Err(format!("Failed to start stdio client: {}", e));
                    }
                    let client = Arc::new(client);
                    self.stdio_clients.insert(key, client.clone());
                    client.list_tools().await.map_err(|e| format!("{}", e))
                }
            }
        }
    }

    // MARK: - Tool Calling

    /// Call a tool
    pub async fn call_tool(
        &self,
        server_name: &str,
        tool_name: &str,
        arguments: Value,
        workspace: Option<&Workspace>,
    ) -> Result<ToolCallResult, JsonRpcError> {
        let config = self
            .server_configs
            .iter()
            .find(|c| c.name == server_name)
            .ok_or_else(|| JsonRpcError::new(-32602, format!("Server '{}' not found", server_name)))?;

        match config.server_type {
            ServerType::Http => {
                if let Some(client) = self.http_clients.get(server_name) {
                    client
                        .call_tool(tool_name, arguments)
                        .await
                        .map_err(|e| JsonRpcError::internal_error(&e.to_string()))
                } else {
                    Err(JsonRpcError::new(
                        -32602,
                        format!("HTTP client not found: {}", server_name),
                    ))
                }
            }
            ServerType::Stdio => {
                let token = workspace
                    .map(|w| w.token.as_str())
                    .unwrap_or("default");
                let key = format!("{}::{}", token, server_name);

                if let Some(client) = self.stdio_clients.get(&key) {
                    client
                        .call_tool(tool_name, arguments)
                        .await
                        .map_err(|e| JsonRpcError::internal_error(&e.to_string()))
                } else {
                    Err(JsonRpcError::new(
                        -32602,
                        format!("Stdio client not found: {}", server_name),
                    ))
                }
            }
        }
    }

    // MARK: - Router Tools (Meta Tools)

    /// Generate router's own tool list
    pub fn generate_router_tools(&self, workspace: Option<&Workspace>) -> Vec<McpTool> {
        meta_tools::generate_meta_tools(self, workspace, self.expose_management_tools)
    }

    /// Handle router tool call
    pub async fn handle_router_tool_call(
        &self,
        name: &str,
        arguments: Value,
        workspace: Option<&Workspace>,
    ) -> Result<ToolCallResult, JsonRpcError> {
        meta_tools::handle_meta_tool_call(self, name, arguments, workspace).await
    }

    /// Get server configs (for meta tools)
    pub fn server_configs(&self) -> &[ServerConfig] {
        &self.server_configs
    }

    /// Get all workspaces as a vector
    pub fn workspaces(&self) -> Vec<Workspace> {
        self.workspaces
            .iter()
            .map(|entry| entry.value().clone())
            .collect()
    }
}

impl Default for McpRouter {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{ServerConfig, Workspace};

    fn create_test_http_config(name: &str) -> ServerConfig {
        ServerConfig::new_http(name, &format!("http://localhost:8080/{}", name))
            .with_description(&format!("Test server {}", name))
    }

    fn create_test_stdio_config(name: &str) -> ServerConfig {
        ServerConfig::new_stdio(name, "echo", vec!["hello".to_string()])
            .with_description(&format!("Stdio server {}", name))
    }

    #[test]
    fn test_router_creation() {
        let router = McpRouter::new();
        assert!(router.server_configs.is_empty());
        assert!(router.default_workspace.is_some());
    }

    #[test]
    fn test_load_servers() {
        let mut router = McpRouter::new();
        let configs = vec![
            create_test_http_config("server1"),
            create_test_http_config("server2"),
            create_test_stdio_config("server3"),
        ];

        router.load_servers(configs);

        assert_eq!(router.server_configs.len(), 3);
        // HTTP clients should be created for HTTP servers
        assert!(router.http_clients.contains_key("server1"));
        assert!(router.http_clients.contains_key("server2"));
        // No HTTP client for stdio server
        assert!(!router.http_clients.contains_key("server3"));
    }

    #[test]
    fn test_load_workspaces() {
        let mut router = McpRouter::new();

        let ws1 = Workspace::new("token1", "Workspace 1");
        let ws2 = Workspace::default_workspace();

        router.load_workspaces(vec![ws1.clone(), ws2]);

        assert_eq!(router.workspaces.len(), 2);
        assert!(router.default_workspace.is_some());
        assert_eq!(router.default_workspace.as_ref().unwrap().name, "Default");
    }

    #[test]
    fn test_find_workspace() {
        let mut router = McpRouter::new();

        let ws1 = Workspace::new("token1", "Workspace 1");
        let ws_default = Workspace::default_workspace();
        router.load_workspaces(vec![ws1.clone(), ws_default]);

        // Find by token
        let found = router.find_workspace(Some("token1"));
        assert!(found.is_some());
        assert_eq!(found.unwrap().name, "Workspace 1");

        // Find default when token not found
        let found = router.find_workspace(Some("nonexistent"));
        assert!(found.is_some());
        assert_eq!(found.unwrap().name, "Default");

        // Find default when no token
        let found = router.find_workspace(None);
        assert!(found.is_some());
        assert_eq!(found.unwrap().name, "Default");
    }

    #[test]
    fn test_get_effective_servers() {
        let mut router = McpRouter::new();

        let mut config1 = create_test_http_config("enabled");
        config1.is_enabled = true;

        let mut config2 = create_test_http_config("disabled");
        config2.is_enabled = false;

        router.load_servers(vec![config1, config2]);

        // Without workspace, only enabled servers
        let effective = router.get_effective_servers(None);
        assert_eq!(effective.len(), 1);
        assert_eq!(effective[0].name, "enabled");
    }

    #[test]
    fn test_get_effective_servers_with_workspace_override() {
        let mut router = McpRouter::new();

        let config1 = create_test_http_config("server1");
        let mut config2 = create_test_http_config("server2");
        config2.is_enabled = false; // Disabled by default

        router.load_servers(vec![config1, config2]);

        // Create workspace that enables server2
        let mut ws = Workspace::new("ws1", "Test Workspace");
        ws.server_overrides.insert("server2".to_string(), true);
        router.load_workspaces(vec![ws.clone()]);

        // With workspace override, both servers should be effective
        let effective = router.get_effective_servers(Some(&ws));
        assert_eq!(effective.len(), 2);
    }

    #[test]
    fn test_resolve_tool_path_slash_format() {
        let router = McpRouter::new();

        let result = router.resolve_tool_path("server1/tool1", None);
        assert!(result.is_ok());
        let (server, tool) = result.unwrap();
        assert_eq!(server, "server1");
        assert_eq!(tool, "tool1");
    }

    #[test]
    fn test_resolve_tool_path_underscore_format() {
        let router = McpRouter::new();

        let result = router.resolve_tool_path("server1__tool1", None);
        assert!(result.is_ok());
        let (server, tool) = result.unwrap();
        assert_eq!(server, "server1");
        assert_eq!(tool, "tool1");
    }

    #[test]
    fn test_resolve_tool_path_invalid() {
        let router = McpRouter::new();

        let result = router.resolve_tool_path("invalid_path", None);
        assert!(result.is_err());
    }

    #[test]
    fn test_make_safe_tool_name() {
        let mut existing = std::collections::HashSet::new();

        // Basic case
        let name = McpRouter::make_safe_tool_name("server", "tool", &mut existing);
        assert_eq!(name, "server__tool");

        // With special characters
        let name = McpRouter::make_safe_tool_name("my-server", "my/tool", &mut existing);
        assert_eq!(name, "my-server__my_tool");

        // Collision handling
        existing.clear();
        let name1 = McpRouter::make_safe_tool_name("server", "tool", &mut existing);
        let name2 = McpRouter::make_safe_tool_name("server", "tool", &mut existing);
        assert_eq!(name1, "server__tool");
        assert_eq!(name2, "server__tool_2");
    }

    #[test]
    fn test_generate_router_tools_basic() {
        let router = McpRouter::new();
        let tools = router.generate_router_tools(None);

        // Should have at least 4 basic meta tools
        assert!(tools.len() >= 4);

        let tool_names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
        assert!(tool_names.contains(&"mcp_router__list_servers"));
        assert!(tool_names.contains(&"mcp_router__list_tools"));
        assert!(tool_names.contains(&"mcp_router__describe"));
        assert!(tool_names.contains(&"mcp_router__call"));
    }

    #[test]
    fn test_generate_router_tools_with_management() {
        let mut router = McpRouter::new();
        router.set_expose_management_tools(true);

        let tools = router.generate_router_tools(None);

        let tool_names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
        assert!(tool_names.contains(&"mcp_router__add_server"));
        assert!(tool_names.contains(&"mcp_router__remove_server"));
        assert!(tool_names.contains(&"mcp_router__update_server"));
    }

    #[tokio::test]
    async fn test_handle_list_servers() {
        let mut router = McpRouter::new();
        router.load_servers(vec![
            create_test_http_config("server1"),
            create_test_http_config("server2"),
        ]);

        let result = router
            .handle_router_tool_call(
                "mcp_router__list_servers",
                serde_json::json!({}),
                None,
            )
            .await;

        assert!(result.is_ok());
        let tool_result = result.unwrap();
        assert!(tool_result.is_error.is_none());

        // Check content contains server names
        if let Some(crate::protocol::ContentBlock::Text { text }) = tool_result.content.first() {
            assert!(text.contains("server1"));
            assert!(text.contains("server2"));
        } else {
            panic!("Expected text content");
        }
    }
}
