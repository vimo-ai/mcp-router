//! MCP Protocol types
//!
//! JSON-RPC 2.0 and MCP protocol models

use serde::{Deserialize, Serialize};
use serde_json::Value;

// MARK: - JSON-RPC 2.0

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<i64>,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

impl JsonRpcRequest {
    pub fn new(id: Option<i64>, method: impl Into<String>, params: Option<Value>) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            method: method.into(),
            params,
        }
    }

    /// Check if this is a notification (no response expected)
    pub fn is_notification(&self) -> bool {
        self.id.is_none() || self.method.starts_with("notifications/")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

impl JsonRpcResponse {
    pub fn success(id: Option<i64>, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(id: Option<i64>, error: JsonRpcError) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(error),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcError {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl JsonRpcError {
    pub fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            data: None,
        }
    }

    pub fn new_with_data(code: i32, message: impl Into<String>, data: Value) -> Self {
        Self {
            code,
            message: message.into(),
            data: Some(data),
        }
    }

    // Standard JSON-RPC error codes
    pub fn parse_error() -> Self {
        Self::new(-32700, "Parse error")
    }

    pub fn invalid_request() -> Self {
        Self::new(-32600, "Invalid Request")
    }

    pub fn method_not_found(method: &str) -> Self {
        Self::new(-32601, format!("Method not found: {}", method))
    }

    pub fn invalid_params(msg: &str) -> Self {
        Self::new(-32602, format!("Invalid params: {}", msg))
    }

    pub fn internal_error(msg: &str) -> Self {
        Self::new(-32603, format!("Internal error: {}", msg))
    }
}

// MARK: - MCP Protocol

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpTool {
    pub name: String,
    pub description: String,
    #[serde(rename = "inputSchema", skip_serializing_if = "Option::is_none")]
    pub input_schema: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpToolsListResult {
    pub tools: Vec<McpTool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpToolCallParams {
    pub name: String,
    #[serde(default)]
    pub arguments: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpInitializeResult {
    #[serde(rename = "protocolVersion")]
    pub protocol_version: String,
    #[serde(rename = "serverInfo")]
    pub server_info: ServerInfo,
    pub capabilities: Capabilities,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Capabilities {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Value>,
}

impl Default for McpInitializeResult {
    fn default() -> Self {
        Self {
            protocol_version: "2024-11-05".to_string(),
            server_info: ServerInfo {
                name: "mcp-router".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
            },
            capabilities: Capabilities {
                tools: Some(serde_json::json!({})),
            },
        }
    }
}

// MARK: - Tool Call Result

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCallResult {
    pub content: Vec<ContentBlock>,
    #[serde(rename = "isError", skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ContentBlock {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "image")]
    Image {
        data: String,
        #[serde(alias = "mime_type", rename = "mimeType")]
        mime_type: String,
    },
}

impl ToolCallResult {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            content: vec![ContentBlock::Text { text: text.into() }],
            is_error: None,
        }
    }

    pub fn error(text: impl Into<String>) -> Self {
        Self {
            content: vec![ContentBlock::Text { text: text.into() }],
            is_error: Some(true),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // MARK: - JSON-RPC Request Tests

    #[test]
    fn test_json_rpc_request() {
        let req = JsonRpcRequest::new(Some(1), "tools/list", None);
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"jsonrpc\":\"2.0\""));
        assert!(json.contains("\"method\":\"tools/list\""));
    }

    #[test]
    fn test_json_rpc_request_with_params() {
        let params = json!({ "name": "test", "value": 42 });
        let req = JsonRpcRequest::new(Some(1), "tools/call", Some(params.clone()));

        let json_str = serde_json::to_string(&req).unwrap();
        assert!(json_str.contains("\"params\""));

        // Round-trip test
        let parsed: JsonRpcRequest = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed.method, "tools/call");
        assert_eq!(parsed.params.unwrap()["name"], "test");
    }

    #[test]
    fn test_notification_detection() {
        // No ID = notification
        let notification = JsonRpcRequest::new(None, "notifications/initialized", None);
        assert!(notification.is_notification());

        // notifications/ prefix = notification even with ID
        let notification2 = JsonRpcRequest::new(Some(1), "notifications/progress", None);
        assert!(notification2.is_notification());

        // Regular request
        let request = JsonRpcRequest::new(Some(1), "tools/list", None);
        assert!(!request.is_notification());
    }

    // MARK: - JSON-RPC Response Tests

    #[test]
    fn test_json_rpc_response_success() {
        let result = json!({ "tools": [] });
        let response = JsonRpcResponse::success(Some(1), result.clone());

        assert_eq!(response.id, Some(1));
        assert!(response.result.is_some());
        assert!(response.error.is_none());

        let json_str = serde_json::to_string(&response).unwrap();
        assert!(!json_str.contains("\"error\""));
    }

    #[test]
    fn test_json_rpc_response_error() {
        let error = JsonRpcError::method_not_found("unknown");
        let response = JsonRpcResponse::error(Some(1), error);

        assert_eq!(response.id, Some(1));
        assert!(response.result.is_none());
        assert!(response.error.is_some());
        assert_eq!(response.error.as_ref().unwrap().code, -32601);
    }

    #[test]
    fn test_json_rpc_response_roundtrip() {
        let result = json!({ "status": "ok" });
        let response = JsonRpcResponse::success(Some(42), result);

        let json_str = serde_json::to_string(&response).unwrap();
        let parsed: JsonRpcResponse = serde_json::from_str(&json_str).unwrap();

        assert_eq!(parsed.id, Some(42));
        assert_eq!(parsed.result.unwrap()["status"], "ok");
    }

    // MARK: - JSON-RPC Error Tests

    #[test]
    fn test_standard_error_codes() {
        assert_eq!(JsonRpcError::parse_error().code, -32700);
        assert_eq!(JsonRpcError::invalid_request().code, -32600);
        assert_eq!(JsonRpcError::method_not_found("test").code, -32601);
        assert_eq!(JsonRpcError::invalid_params("test").code, -32602);
        assert_eq!(JsonRpcError::internal_error("test").code, -32603);
    }

    #[test]
    fn test_error_message_formatting() {
        let error = JsonRpcError::method_not_found("custom_method");
        assert!(error.message.contains("custom_method"));

        let error = JsonRpcError::invalid_params("missing required field");
        assert!(error.message.contains("missing required field"));
    }

    // MARK: - MCP Protocol Tests

    #[test]
    fn test_mcp_tool_serialization() {
        let tool = McpTool {
            name: "test_tool".to_string(),
            description: "A test tool".to_string(),
            input_schema: Some(json!({
                "type": "object",
                "properties": {
                    "arg1": { "type": "string" }
                }
            })),
        };

        let json_str = serde_json::to_string(&tool).unwrap();
        assert!(json_str.contains("\"inputSchema\""));

        let parsed: McpTool = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed.name, "test_tool");
    }

    #[test]
    fn test_mcp_tool_without_schema() {
        let tool = McpTool {
            name: "simple_tool".to_string(),
            description: "No schema".to_string(),
            input_schema: None,
        };

        let json_str = serde_json::to_string(&tool).unwrap();
        assert!(!json_str.contains("inputSchema"));
    }

    #[test]
    fn test_mcp_tool_call_params() {
        let json_str = r#"{"name": "my_tool", "arguments": {"key": "value"}}"#;
        let params: McpToolCallParams = serde_json::from_str(json_str).unwrap();

        assert_eq!(params.name, "my_tool");
        assert_eq!(params.arguments["key"], "value");
    }

    #[test]
    fn test_mcp_tool_call_params_no_arguments() {
        let json_str = r#"{"name": "my_tool"}"#;
        let params: McpToolCallParams = serde_json::from_str(json_str).unwrap();

        assert_eq!(params.name, "my_tool");
        // arguments should default to null
        assert!(params.arguments.is_null());
    }

    #[test]
    fn test_mcp_initialize_result_default() {
        let result = McpInitializeResult::default();

        assert_eq!(result.protocol_version, "2024-11-05");
        assert_eq!(result.server_info.name, "mcp-router");
        assert!(result.capabilities.tools.is_some());
    }

    #[test]
    fn test_mcp_initialize_result_serialization() {
        let result = McpInitializeResult::default();
        let json_str = serde_json::to_string(&result).unwrap();

        assert!(json_str.contains("\"protocolVersion\""));
        assert!(json_str.contains("\"serverInfo\""));

        let parsed: McpInitializeResult = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed.protocol_version, result.protocol_version);
    }

    // MARK: - Tool Call Result Tests

    #[test]
    fn test_tool_call_result_text() {
        let result = ToolCallResult::text("Hello, world!");

        assert_eq!(result.content.len(), 1);
        assert!(result.is_error.is_none());

        match &result.content[0] {
            ContentBlock::Text { text } => assert_eq!(text, "Hello, world!"),
            _ => panic!("Expected text content"),
        }
    }

    #[test]
    fn test_tool_call_result_error() {
        let result = ToolCallResult::error("Something went wrong");

        assert_eq!(result.is_error, Some(true));

        match &result.content[0] {
            ContentBlock::Text { text } => assert!(text.contains("went wrong")),
            _ => panic!("Expected text content"),
        }
    }

    #[test]
    fn test_content_block_serialization() {
        let text_block = ContentBlock::Text {
            text: "Hello".to_string(),
        };
        let json_str = serde_json::to_string(&text_block).unwrap();
        assert!(json_str.contains("\"type\":\"text\""));
        assert!(json_str.contains("\"text\":\"Hello\""));

        let image_block = ContentBlock::Image {
            data: "base64data".to_string(),
            mime_type: "image/png".to_string(),
        };
        let json_str = serde_json::to_string(&image_block).unwrap();
        assert!(json_str.contains("\"type\":\"image\""));
        assert!(json_str.contains("\"mimeType\""));
    }

    #[test]
    fn test_tool_call_result_roundtrip() {
        let result = ToolCallResult::text("Test message");
        let json_str = serde_json::to_string(&result).unwrap();

        let parsed: ToolCallResult = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed.content.len(), 1);

        match &parsed.content[0] {
            ContentBlock::Text { text } => assert_eq!(text, "Test message"),
            _ => panic!("Expected text content"),
        }
    }
}
