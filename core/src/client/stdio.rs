//! Stdio MCP Client - uses official rmcp SDK for subprocess communication

use super::ClientError;
use crate::config::ServerConfig;
use crate::get_runtime;
use crate::protocol::{McpTool, ToolCallResult, ContentBlock};
use parking_lot::RwLock;
use rmcp::model::{CallToolRequestParam, Tool};
use rmcp::service::{RoleClient, RunningService, Peer};
use rmcp::transport::TokioChildProcess;
use rmcp::ServiceExt;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::oneshot;

/// Stdio-based MCP client using official rmcp SDK
pub struct StdioMcpClient {
    config: ServerConfig,
    /// The peer for sending requests to the MCP server
    peer: RwLock<Option<Arc<Peer<RoleClient>>>>,
    /// Cached tools list
    tools_cache: RwLock<Option<Vec<McpTool>>>,
}

impl StdioMcpClient {
    pub fn new(config: ServerConfig) -> Self {
        Self {
            config,
            peer: RwLock::new(None),
            tools_cache: RwLock::new(None),
        }
    }

    /// Start the subprocess and establish MCP connection
    pub async fn start(&self) -> Result<(), ClientError> {
        // Check if already running
        if self.peer.read().is_some() {
            return Ok(());
        }

        let command = self
            .config
            .command
            .as_ref()
            .ok_or_else(|| ClientError::Process("No command specified".to_string()))?;

        // Build environment with PATH
        let mut env: HashMap<String, String> = std::env::vars().collect();

        // Add common paths
        let home = std::env::var("HOME").unwrap_or_default();
        let local_bin = format!("{}/.local/bin", home);
        let cargo_bin = format!("{}/.cargo/bin", home);

        let mut extra_paths: Vec<String> = vec![
            "/opt/homebrew/bin".to_string(),
            "/opt/homebrew/sbin".to_string(),
            "/usr/local/bin".to_string(),
            local_bin,
            cargo_bin,
        ];

        // Add nvm node bin paths (scan all installed versions)
        let nvm_versions_dir = format!("{}/.nvm/versions/node", home);
        if let Ok(entries) = std::fs::read_dir(&nvm_versions_dir) {
            for entry in entries.flatten() {
                let bin_path = entry.path().join("bin");
                if bin_path.exists() {
                    extra_paths.push(bin_path.to_string_lossy().to_string());
                }
            }
        }

        if let Some(current_path) = env.get("PATH") {
            let new_path = format!("{}:{}", extra_paths.join(":"), current_path);
            env.insert("PATH".to_string(), new_path);
        }

        // Add user-defined env vars
        for (k, v) in &self.config.env {
            env.insert(k.clone(), v.clone());
        }

        // Find the actual executable path
        let executable = self.find_executable(command, &env)?;
        let args = self.config.args.clone();
        let name = self.config.name.clone();

        tracing::info!(
            "Starting stdio process via rmcp: {} {}",
            executable,
            args.join(" ")
        );

        // Use a channel to get the peer back from the spawned task
        let (tx, rx) = oneshot::channel();

        // Spawn the rmcp service on the global runtime so it stays alive
        get_runtime().spawn(async move {
            // Create command for rmcp
            let mut cmd = Command::new(&executable);
            cmd.args(&args).envs(&env);

            // Create TokioChildProcess transport and start service
            let transport = match TokioChildProcess::new(&mut cmd) {
                Ok(t) => t,
                Err(e) => {
                    let _ = tx.send(Err(format!("Failed to create transport: {}", e)));
                    return;
                }
            };

            // Start the MCP client service (handles initialize handshake automatically)
            let service: RunningService<RoleClient, ()> = match ().serve(transport).await {
                Ok(s) => s,
                Err(e) => {
                    let _ = tx.send(Err(format!("Failed to start MCP client: {}", e)));
                    return;
                }
            };

            tracing::info!(
                "{} MCP client connected, server info: {:?}",
                name,
                service.peer_info()
            );

            // Send the peer back to the caller
            let peer = service.peer().clone();
            let _ = tx.send(Ok(peer));

            // Keep the service running (this task will stay alive)
            let _ = service.waiting().await;
            tracing::info!("{} MCP client service stopped", name);
        });

        // Wait for the service to initialize
        let peer = rx
            .await
            .map_err(|_| ClientError::Process("Service init channel closed".to_string()))?
            .map_err(|e| ClientError::Process(e))?;

        *self.peer.write() = Some(Arc::new(peer));
        Ok(())
    }

    /// Find executable in PATH
    fn find_executable(
        &self,
        command: &str,
        env: &HashMap<String, String>,
    ) -> Result<String, ClientError> {
        // If it's an absolute path, use it directly
        if command.starts_with('/') {
            return Ok(command.to_string());
        }

        // Search in PATH
        if let Some(path) = env.get("PATH") {
            for dir in path.split(':') {
                let full_path = format!("{}/{}", dir, command);
                if std::path::Path::new(&full_path).exists() {
                    // Resolve symlinks
                    if let Ok(resolved) = std::fs::canonicalize(&full_path) {
                        return Ok(resolved.to_string_lossy().to_string());
                    }
                    return Ok(full_path);
                }
            }
        }

        Err(ClientError::Process(format!(
            "Command not found: {}",
            command
        )))
    }

    /// List tools (with caching)
    pub async fn list_tools(&self) -> Result<Vec<McpTool>, ClientError> {
        // Check cache first
        {
            let cache = self.tools_cache.read();
            if let Some(tools) = cache.as_ref() {
                return Ok(tools.clone());
            }
        }

        let peer = self
            .peer
            .read()
            .clone()
            .ok_or(ClientError::NotConnected)?;

        // Use rmcp's list_all_tools method
        let tools = peer
            .list_all_tools()
            .await
            .map_err(|e| ClientError::Rpc {
                code: -32603,
                message: format!("Failed to list tools: {}", e),
            })?;

        // Convert rmcp::model::Tool to our McpTool
        let mcp_tools: Vec<McpTool> = tools.into_iter().map(convert_tool).collect();

        // Update cache
        {
            let mut cache = self.tools_cache.write();
            *cache = Some(mcp_tools.clone());
        }

        tracing::info!("{}: loaded {} tools", self.config.name, mcp_tools.len());
        Ok(mcp_tools)
    }

    /// Call a tool
    pub async fn call_tool(
        &self,
        name: &str,
        arguments: Value,
    ) -> Result<ToolCallResult, ClientError> {
        tracing::debug!("call_tool: {} args={}", name, arguments);

        let peer = self
            .peer
            .read()
            .clone()
            .ok_or(ClientError::NotConnected)?;

        // Convert Value to serde_json::Map
        let args_map = match arguments {
            Value::Object(map) => map,
            Value::Null => serde_json::Map::new(),
            _ => {
                return Err(ClientError::Rpc {
                    code: -32602,
                    message: "Arguments must be an object".to_string(),
                })
            }
        };

        let params = CallToolRequestParam {
            name: name.to_string().into(),
            arguments: Some(args_map),
        };

        let result = peer.call_tool(params).await.map_err(|e| {
            tracing::warn!("call_tool {} failed: {}", name, e);
            ClientError::Rpc {
                code: -32603,
                message: format!("Tool call failed: {}", e),
            }
        })?;

        // Convert rmcp result to our ToolCallResult
        let content: Vec<ContentBlock> = result
            .content
            .into_iter()
            .filter_map(|c| {
                // rmcp Content (Annotated<RawContent>) -> our ContentBlock
                use rmcp::model::RawContent;
                match c.raw {
                    RawContent::Text(t) => Some(ContentBlock::Text { text: t.text }),
                    RawContent::Image(i) => Some(ContentBlock::Image {
                        data: i.data,
                        mime_type: i.mime_type
                    }),
                    RawContent::Resource(_) => None, // Skip resource content for now
                }
            })
            .collect();

        Ok(ToolCallResult {
            content,
            is_error: result.is_error,
        })
    }

    /// Stop the subprocess
    pub async fn stop(&self) {
        *self.peer.write() = None;
        *self.tools_cache.write() = None;
        tracing::info!("{} stdio client stopped", self.config.name);
    }

    /// Check if running
    pub fn is_running(&self) -> bool {
        self.peer.read().is_some()
    }
}

/// Convert rmcp::model::Tool to our McpTool
fn convert_tool(tool: Tool) -> McpTool {
    McpTool {
        name: tool.name.to_string(),
        description: tool.description.to_string(),
        input_schema: Some(Value::Object((*tool.input_schema).clone())),
    }
}
