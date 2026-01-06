//! Integration tests for MCP Router

use mcp_router_core::config::{ServerConfig, Workspace};
use mcp_router_core::protocol::{JsonRpcRequest, JsonRpcResponse};
use mcp_router_core::router::McpRouter;
use mcp_router_core::server;
use parking_lot::RwLock;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::oneshot;

/// Helper to create test router with some servers
fn create_test_router() -> Arc<RwLock<McpRouter>> {
    let mut router = McpRouter::new();

    let config1 = ServerConfig::new_http("test-server", "http://localhost:9999")
        .with_description("Test HTTP server");

    router.load_servers(vec![config1]);
    router.load_workspaces(vec![Workspace::default_workspace()]);

    Arc::new(RwLock::new(router))
}

#[tokio::test]
async fn test_server_starts_and_stops() {
    let router = create_test_router();
    let (shutdown_tx, shutdown_rx) = oneshot::channel();

    // Start server in background
    let server_handle = tokio::spawn(async move {
        let result = server::run_server(19200, router, shutdown_rx).await;
        result
    });

    // Wait for server to start
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Send shutdown signal
    let _ = shutdown_tx.send(());

    // Wait for server to stop
    let result = tokio::time::timeout(Duration::from_secs(5), server_handle).await;
    assert!(result.is_ok());
}

#[tokio::test]
async fn test_health_endpoint() {
    let router = create_test_router();
    let (shutdown_tx, shutdown_rx) = oneshot::channel();

    // Start server
    tokio::spawn(async move {
        let _ = server::run_server(19201, router, shutdown_rx).await;
    });

    // Wait for server to start
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Test health endpoint
    let client = reqwest::Client::new();
    let response = client
        .get("http://127.0.0.1:19201/health")
        .send()
        .await
        .expect("Failed to send request");

    assert!(response.status().is_success());

    let body: serde_json::Value = response.json().await.expect("Failed to parse JSON");
    assert_eq!(body["status"], "ok");

    // Shutdown
    let _ = shutdown_tx.send(());
}

#[tokio::test]
async fn test_initialize_request() {
    let router = create_test_router();
    let (shutdown_tx, shutdown_rx) = oneshot::channel();

    // Start server
    tokio::spawn(async move {
        let _ = server::run_server(19202, router, shutdown_rx).await;
    });

    tokio::time::sleep(Duration::from_millis(200)).await;

    // Send initialize request
    let client = reqwest::Client::new();
    let request = JsonRpcRequest::new(Some(1), "initialize", None);

    let response = client
        .post("http://127.0.0.1:19202/")
        .header("Content-Type", "application/json")
        .json(&request)
        .send()
        .await
        .expect("Failed to send request");

    assert!(response.status().is_success());

    // Check for session ID header
    let session_id = response.headers().get("mcp-session-id");
    assert!(session_id.is_some(), "Should return session ID");

    let body: JsonRpcResponse = response.json().await.expect("Failed to parse JSON");
    assert!(body.error.is_none());
    assert!(body.result.is_some());

    let result = body.result.unwrap();
    assert_eq!(result["protocolVersion"], "2024-11-05");
    assert_eq!(result["serverInfo"]["name"], "mcp-router");

    let _ = shutdown_tx.send(());
}

#[tokio::test(flavor = "multi_thread")]
async fn test_tools_list_request() {
    let router = create_test_router();
    let (shutdown_tx, shutdown_rx) = oneshot::channel();

    tokio::spawn(async move {
        let _ = server::run_server(19203, router, shutdown_rx).await;
    });

    tokio::time::sleep(Duration::from_millis(200)).await;

    let client = reqwest::Client::new();

    // First initialize
    let init_request = JsonRpcRequest::new(Some(1), "initialize", None);
    let init_response = client
        .post("http://127.0.0.1:19203/")
        .header("Content-Type", "application/json")
        .json(&init_request)
        .send()
        .await
        .expect("Failed to send init request");

    let session_id = init_response
        .headers()
        .get("mcp-session-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    // Then list tools
    let list_request = JsonRpcRequest::new(Some(2), "tools/list", None);
    let response = client
        .post("http://127.0.0.1:19203/")
        .header("Content-Type", "application/json")
        .header("mcp-session-id", &session_id)
        .json(&list_request)
        .send()
        .await
        .expect("Failed to send request");

    assert!(response.status().is_success());

    let body: JsonRpcResponse = response.json().await.expect("Failed to parse JSON");
    assert!(body.error.is_none());
    assert!(body.result.is_some());

    let result = body.result.unwrap();
    let tools = result["tools"].as_array().expect("tools should be array");

    // Should have meta tools
    let tool_names: Vec<&str> = tools
        .iter()
        .filter_map(|t| t["name"].as_str())
        .collect();

    assert!(tool_names.contains(&"mcp_router__list_servers"));
    assert!(tool_names.contains(&"mcp_router__list_tools"));
    assert!(tool_names.contains(&"mcp_router__describe"));
    assert!(tool_names.contains(&"mcp_router__call"));

    let _ = shutdown_tx.send(());
}

#[tokio::test]
async fn test_notification_returns_202() {
    let router = create_test_router();
    let (shutdown_tx, shutdown_rx) = oneshot::channel();

    tokio::spawn(async move {
        let _ = server::run_server(19204, router, shutdown_rx).await;
    });

    tokio::time::sleep(Duration::from_millis(200)).await;

    let client = reqwest::Client::new();

    // Send notification (no id)
    let notification = JsonRpcRequest::new(None, "notifications/initialized", None);

    let response = client
        .post("http://127.0.0.1:19204/")
        .header("Content-Type", "application/json")
        .json(&notification)
        .send()
        .await
        .expect("Failed to send request");

    // Notifications should return 202 Accepted
    assert_eq!(response.status().as_u16(), 202);

    let _ = shutdown_tx.send(());
}

#[tokio::test(flavor = "multi_thread")]
async fn test_tools_call_list_servers() {
    let router = create_test_router();
    let (shutdown_tx, shutdown_rx) = oneshot::channel();

    tokio::spawn(async move {
        let _ = server::run_server(19205, router, shutdown_rx).await;
    });

    tokio::time::sleep(Duration::from_millis(200)).await;

    let client = reqwest::Client::new();

    // Call mcp_router__list_servers
    let call_request = JsonRpcRequest::new(
        Some(1),
        "tools/call",
        Some(serde_json::json!({
            "name": "mcp_router__list_servers",
            "arguments": {}
        })),
    );

    let response = client
        .post("http://127.0.0.1:19205/")
        .header("Content-Type", "application/json")
        .json(&call_request)
        .send()
        .await
        .expect("Failed to send request");

    assert!(response.status().is_success());

    let body: JsonRpcResponse = response.json().await.expect("Failed to parse JSON");
    assert!(body.error.is_none());
    assert!(body.result.is_some());

    let result = body.result.unwrap();
    let content = result["content"].as_array().expect("content should be array");
    assert!(!content.is_empty());

    // Check text content mentions our test server
    let text = content[0]["text"].as_str().unwrap_or("");
    assert!(text.contains("test-server"));

    let _ = shutdown_tx.send(());
}

#[tokio::test]
async fn test_unknown_method_returns_error() {
    let router = create_test_router();
    let (shutdown_tx, shutdown_rx) = oneshot::channel();

    tokio::spawn(async move {
        let _ = server::run_server(19206, router, shutdown_rx).await;
    });

    tokio::time::sleep(Duration::from_millis(200)).await;

    let client = reqwest::Client::new();

    let request = JsonRpcRequest::new(Some(1), "unknown/method", None);

    let response = client
        .post("http://127.0.0.1:19206/")
        .header("Content-Type", "application/json")
        .json(&request)
        .send()
        .await
        .expect("Failed to send request");

    let body: JsonRpcResponse = response.json().await.expect("Failed to parse JSON");
    assert!(body.error.is_some());
    assert_eq!(body.error.as_ref().unwrap().code, -32601); // Method not found

    let _ = shutdown_tx.send(());
}
