//! Stdio MCP Client - manages subprocess communication

use super::ClientError;
use crate::config::ServerConfig;
use crate::protocol::{JsonRpcRequest, JsonRpcResponse, McpTool, McpToolsListResult, ToolCallResult};
use parking_lot::RwLock;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot};

/// Stdio-based MCP client
pub struct StdioMcpClient {
    config: ServerConfig,
    request_id: AtomicI64,
    is_running: AtomicBool,
    tools_cache: RwLock<Option<Vec<McpTool>>>,

    // Process communication
    stdin_tx: RwLock<Option<mpsc::Sender<String>>>,
    pending_requests: Arc<RwLock<HashMap<i64, oneshot::Sender<JsonRpcResponse>>>>,
}

impl StdioMcpClient {
    pub fn new(config: ServerConfig) -> Self {
        Self {
            config,
            request_id: AtomicI64::new(0),
            is_running: AtomicBool::new(false),
            tools_cache: RwLock::new(None),
            stdin_tx: RwLock::new(None),
            pending_requests: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    fn next_id(&self) -> i64 {
        self.request_id.fetch_add(1, Ordering::SeqCst)
    }

    /// Start the subprocess
    pub async fn start(&self) -> Result<(), ClientError> {
        if self.is_running.load(Ordering::SeqCst) {
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
        let nvm_path = format!("{}/.nvm/versions/node", home);

        let extra_paths: Vec<&str> = vec![
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            &local_bin,
            &cargo_bin,
            &nvm_path,
        ];

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

        tracing::info!(
            "Starting stdio process: {} {}",
            executable,
            self.config.args.join(" ")
        );

        let mut child = Command::new(&executable)
            .args(&self.config.args)
            .envs(&env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| ClientError::Process(format!("Failed to spawn: {}", e)))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| ClientError::Process("No stdin".to_string()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| ClientError::Process("No stdout".to_string()))?;

        // Create channels for stdin communication
        let (stdin_tx, mut stdin_rx) = mpsc::channel::<String>(100);
        *self.stdin_tx.write() = Some(stdin_tx);

        // Spawn stdin writer task
        let mut stdin = stdin;
        tokio::spawn(async move {
            while let Some(data) = stdin_rx.recv().await {
                if stdin.write_all(data.as_bytes()).await.is_err() {
                    break;
                }
                if stdin.flush().await.is_err() {
                    break;
                }
            }
        });

        // Spawn stdout reader task
        let pending = self.pending_requests.clone();
        let name = self.config.name.clone();
        tokio::spawn(async move {
            let reader = BufReader::new(stdout);
            let mut lines = reader.lines();

            while let Ok(Some(line)) = lines.next_line().await {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }

                tracing::debug!("{} stdout: {}", name, &trimmed[..trimmed.len().min(100)]);

                match serde_json::from_str::<JsonRpcResponse>(trimmed) {
                    Ok(response) => {
                        if let Some(id) = response.id {
                            let mut pending = pending.write();
                            if let Some(sender) = pending.remove(&id) {
                                let _ = sender.send(response);
                            }
                        }
                    }
                    Err(e) => {
                        tracing::warn!("{} failed to parse response: {}", name, e);
                    }
                }
            }

            tracing::info!("{} stdout reader stopped", name);
        });

        self.is_running.store(true, Ordering::SeqCst);

        // Wait a bit for process to be ready
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;

        tracing::info!("{} stdio client started", self.config.name);
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

    /// Send request and wait for response
    async fn send_request(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, ClientError> {
        if !self.is_running.load(Ordering::SeqCst) {
            return Err(ClientError::NotConnected);
        }

        let id = self.next_id();
        let request = JsonRpcRequest::new(Some(id), method, params);
        let request_json = serde_json::to_string(&request)? + "\n";

        // Create response channel
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = self.pending_requests.write();
            pending.insert(id, tx);
        }

        // Send request
        {
            let stdin_tx = self.stdin_tx.read();
            if let Some(sender) = stdin_tx.as_ref() {
                sender
                    .send(request_json)
                    .await
                    .map_err(|e| ClientError::Process(format!("Failed to send: {}", e)))?;
            } else {
                return Err(ClientError::NotConnected);
            }
        }

        // Wait for response with timeout
        let response = tokio::time::timeout(std::time::Duration::from_secs(30), rx)
            .await
            .map_err(|_| ClientError::Timeout)?
            .map_err(|_| ClientError::Process("Response channel closed".to_string()))?;

        if let Some(error) = response.error {
            return Err(ClientError::Rpc {
                code: error.code,
                message: error.message,
            });
        }

        response.result.ok_or(ClientError::EmptyResponse)
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

        let result = self.send_request("tools/list", None).await?;
        let tools_result: McpToolsListResult = serde_json::from_value(result)?;

        // Update cache
        {
            let mut cache = self.tools_cache.write();
            *cache = Some(tools_result.tools.clone());
        }

        tracing::info!(
            "{}: loaded {} tools",
            self.config.name,
            tools_result.tools.len()
        );
        Ok(tools_result.tools)
    }

    /// Call a tool
    pub async fn call_tool(
        &self,
        name: &str,
        arguments: Value,
    ) -> Result<ToolCallResult, ClientError> {
        let params = json!({
            "name": name,
            "arguments": arguments
        });

        let result = self.send_request("tools/call", Some(params)).await?;
        let tool_result: ToolCallResult = serde_json::from_value(result)?;
        Ok(tool_result)
    }

    /// Stop the subprocess
    pub async fn stop(&self) {
        self.is_running.store(false, Ordering::SeqCst);
        *self.stdin_tx.write() = None;
        self.pending_requests.write().clear();
        tracing::info!("{} stdio client stopped", self.config.name);
    }

    /// Check if running
    pub fn is_running(&self) -> bool {
        self.is_running.load(Ordering::SeqCst)
    }
}

impl Drop for StdioMcpClient {
    fn drop(&mut self) {
        self.is_running.store(false, Ordering::SeqCst);
    }
}
