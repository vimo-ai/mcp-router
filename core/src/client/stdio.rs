//! Stdio MCP Client - manages subprocess communication

use super::ClientError;
use crate::config::{ServerConfig, StdioProtocol};
use crate::protocol::{JsonRpcRequest, JsonRpcResponse, McpTool, McpToolsListResult, ToolCallResult};
use parking_lot::RwLock;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
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
        let protocol = self.config.stdio_protocol;

        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout);

            loop {
                let message = match protocol {
                    StdioProtocol::Line => {
                        // 按行读取
                        let mut line = String::new();
                        match reader.read_line(&mut line).await {
                            Ok(0) => break, // EOF
                            Ok(_) => {
                                let trimmed = line.trim();
                                if trimmed.is_empty() {
                                    continue;
                                }
                                trimmed.to_string()
                            }
                            Err(_) => break,
                        }
                    }
                    StdioProtocol::ContentLength => {
                        // Content-Length 格式读取
                        match read_content_length_message(&mut reader).await {
                            Ok(Some(msg)) => msg,
                            Ok(None) => break, // EOF
                            Err(e) => {
                                tracing::warn!("{} Content-Length read error: {}", name, e);
                                continue;
                            }
                        }
                    }
                };

                tracing::debug!("{} stdout: {}", name, &message[..message.len().min(100)]);

                match serde_json::from_str::<JsonRpcResponse>(&message) {
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
        let request_json = serde_json::to_string(&request)?;

        // 根据协议类型格式化消息
        let formatted_message = match self.config.stdio_protocol {
            StdioProtocol::Line => format!("{}\n", request_json),
            StdioProtocol::ContentLength => {
                format!("Content-Length: {}\r\n\r\n{}", request_json.len(), request_json)
            }
        };

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
                    .send(formatted_message)
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

/// 读取 Content-Length 格式的消息
async fn read_content_length_message<R: tokio::io::AsyncRead + Unpin>(
    reader: &mut BufReader<R>,
) -> Result<Option<String>, std::io::Error> {
    // 1. 读取 header 直到 \r\n\r\n
    let mut header = String::new();
    loop {
        let mut line = String::new();
        let n = reader.read_line(&mut line).await?;
        if n == 0 {
            return Ok(None); // EOF
        }

        header.push_str(&line);

        // 检查是否到达 header 结束
        if header.ends_with("\r\n\r\n") || header.ends_with("\n\n") {
            break;
        }
    }

    // 2. 解析 Content-Length
    let content_length = header
        .lines()
        .find_map(|line| {
            let lower = line.to_lowercase();
            if lower.starts_with("content-length:") {
                line.split(':')
                    .nth(1)
                    .and_then(|s| s.trim().parse::<usize>().ok())
            } else {
                None
            }
        })
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Missing Content-Length header",
            )
        })?;

    // 3. 读取指定长度的内容
    let mut content = vec![0u8; content_length];
    reader.read_exact(&mut content).await?;

    String::from_utf8(content).map(Some).map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, format!("Invalid UTF-8: {}", e))
    })
}
