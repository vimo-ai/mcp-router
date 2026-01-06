//! HTTP MCP Client

use super::ClientError;
use crate::protocol::{JsonRpcRequest, JsonRpcResponse, McpTool, McpToolsListResult, ToolCallResult};
use parking_lot::RwLock;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicI64, Ordering};

/// HTTP-based MCP client
pub struct HttpMcpClient {
    name: String,
    url: String,
    request_id: AtomicI64,
    tools_cache: RwLock<Option<Vec<McpTool>>>,
}

impl HttpMcpClient {
    pub fn new(name: String, url: String) -> Self {
        Self {
            name,
            url,
            request_id: AtomicI64::new(0),
            tools_cache: RwLock::new(None),
        }
    }

    fn next_id(&self) -> i64 {
        self.request_id.fetch_add(1, Ordering::SeqCst)
    }

    async fn send_request(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, ClientError> {
        let id = self.next_id();
        let request = JsonRpcRequest::new(Some(id), method, params);

        let client = reqwest::Client::new();
        let response = client
            .post(&self.url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/event-stream")
            .json(&request)
            .send()
            .await
            .map_err(|e| ClientError::Http(e.to_string()))?;

        if !response.status().is_success() {
            return Err(ClientError::Http(format!(
                "HTTP {}: {}",
                response.status(),
                response.text().await.unwrap_or_default()
            )));
        }

        let body = response.text().await.map_err(|e| ClientError::Http(e.to_string()))?;
        tracing::debug!("{} response: {}", self.name, &body[..body.len().min(500)]);

        let json_response: JsonRpcResponse =
            serde_json::from_str(&body).map_err(ClientError::Json)?;

        if let Some(error) = json_response.error {
            return Err(ClientError::Rpc {
                code: error.code,
                message: error.message,
            });
        }

        json_response.result.ok_or(ClientError::EmptyResponse)
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

        tracing::info!("{}: loaded {} tools", self.name, tools_result.tools.len());
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

    /// Clear tools cache
    pub fn clear_cache(&self) {
        let mut cache = self.tools_cache.write();
        *cache = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_client_creation() {
        let client = HttpMcpClient::new("test".to_string(), "http://localhost:8080".to_string());
        assert_eq!(client.name, "test");
        assert_eq!(client.url, "http://localhost:8080");
    }
}
