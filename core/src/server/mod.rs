//! HTTP Server implementation using axum

use crate::protocol::{
    JsonRpcError, JsonRpcRequest, JsonRpcResponse, McpInitializeResult, McpToolCallParams,
};
use crate::router::McpRouter;
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use parking_lot::RwLock;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::oneshot;
use uuid::Uuid;

/// Server state
pub struct ServerState {
    pub router: Arc<RwLock<McpRouter>>,
    pub sessions: Arc<RwLock<HashMap<String, std::time::Instant>>>,
}

/// Create and run the HTTP server
pub async fn run_server(
    port: u16,
    router: Arc<RwLock<McpRouter>>,
    shutdown_rx: oneshot::Receiver<()>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let state = Arc::new(ServerState {
        router,
        sessions: Arc::new(RwLock::new(HashMap::new())),
    });

    let app = Router::new()
        .route("/", post(handle_post))
        .route("/", get(handle_get))
        .route("/health", get(health_check))
        .with_state(state);

    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    tracing::info!("MCP Router HTTP server starting on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;

    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = shutdown_rx.await;
            tracing::info!("HTTP server shutting down");
        })
        .await?;

    Ok(())
}

/// Health check endpoint
async fn health_check() -> impl IntoResponse {
    Json(json!({ "status": "ok" }))
}

/// Handle POST requests (JSON-RPC)
async fn handle_post(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Json(request): Json<JsonRpcRequest>,
) -> Response {
    let session_id = headers
        .get("mcp-session-id")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    let workspace_token = headers
        .get("x-workspace-token")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    tracing::debug!(
        "Received request: method={}, session={:?}",
        request.method,
        session_id
    );

    // Handle notifications (no response needed)
    if request.is_notification() {
        tracing::debug!("Processing notification: {}", request.method);
        return Response::builder()
            .status(StatusCode::ACCEPTED)
            .header("content-type", "application/json")
            .body(axum::body::Body::empty())
            .unwrap();
    }

    // Process the request
    let (result, new_session_id) =
        process_request(&state, &request, session_id.as_deref(), workspace_token.as_deref()).await;

    let response = match result {
        Ok(value) => JsonRpcResponse::success(request.id, value),
        Err(error) => JsonRpcResponse::error(request.id, error),
    };

    let body = serde_json::to_string(&response).unwrap_or_default();

    let mut builder = Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/json");

    if let Some(sid) = new_session_id {
        builder = builder.header("mcp-session-id", sid);
    }

    builder
        .body(axum::body::Body::from(body))
        .unwrap()
}

/// Handle GET requests (SSE - not implemented)
async fn handle_get() -> impl IntoResponse {
    (StatusCode::METHOD_NOT_ALLOWED, "SSE not supported")
}

/// Process a JSON-RPC request
async fn process_request(
    state: &ServerState,
    request: &JsonRpcRequest,
    session_id: Option<&str>,
    workspace_token: Option<&str>,
) -> (Result<Value, JsonRpcError>, Option<String>) {
    let router = state.router.read();
    let workspace = router.find_workspace(workspace_token);

    match request.method.as_str() {
        "initialize" => {
            let new_session_id = Uuid::new_v4().to_string();
            state
                .sessions
                .write()
                .insert(new_session_id.clone(), std::time::Instant::now());

            let result = McpInitializeResult::default();
            (
                Ok(serde_json::to_value(result).unwrap()),
                Some(new_session_id),
            )
        }

        "notifications/initialized" => {
            if let Some(sid) = session_id {
                tracing::debug!("Session initialized: {}", sid);
            }
            (Ok(json!({})), None)
        }

        "tools/list" => {
            drop(router); // Release lock before async operation

            let router = state.router.read();
            let meta_tools = router.generate_router_tools(workspace.as_ref());
            drop(router);

            // Get flattened tools - use block_in_place to allow blocking in async context
            let workspace_clone = workspace.clone();
            let router_clone = state.router.clone();
            let flattened_tools = tokio::task::block_in_place(|| {
                let router = router_clone.read();
                tokio::runtime::Handle::current()
                    .block_on(router.get_flattened_tools(workspace_clone.as_ref()))
            });

            let all_tools: Vec<_> = meta_tools.into_iter().chain(flattened_tools).collect();

            let tools_json: Vec<Value> = all_tools
                .into_iter()
                .map(|t| {
                    let mut obj = json!({
                        "name": t.name,
                        "description": t.description
                    });
                    if let Some(schema) = t.input_schema {
                        obj["inputSchema"] = schema;
                    }
                    obj
                })
                .collect();

            (Ok(json!({ "tools": tools_json })), None)
        }

        "tools/call" => {
            let params = match request.params.as_ref() {
                Some(p) => p,
                None => return (Err(JsonRpcError::invalid_params("Missing params")), None),
            };

            let tool_params: McpToolCallParams = match serde_json::from_value(params.clone()) {
                Ok(p) => p,
                Err(e) => return (Err(JsonRpcError::invalid_params(&e.to_string())), None),
            };

            drop(router); // Release lock before async operation

            let result = if tool_params.name.starts_with("mcp_router__") {
                let router_clone = state.router.clone();
                let tool_name = tool_params.name.clone();
                let arguments = tool_params.arguments.clone();
                let workspace_clone = workspace.clone();
                tokio::task::block_in_place(|| {
                    let router = router_clone.read();
                    tokio::runtime::Handle::current().block_on(router.handle_router_tool_call(
                        &tool_name,
                        arguments,
                        workspace_clone.as_ref(),
                    ))
                })
            } else {
                // Resolve tool path and call
                let router = state.router.read();
                let resolved = router.resolve_tool_path(&tool_params.name, workspace.as_ref());
                drop(router);

                match resolved {
                    Ok((server, tool)) => {
                        let router_clone = state.router.clone();
                        let arguments = tool_params.arguments.clone();
                        let workspace_clone = workspace.clone();
                        tokio::task::block_in_place(|| {
                            let router = router_clone.read();
                            tokio::runtime::Handle::current().block_on(router.call_tool(
                                &server,
                                &tool,
                                arguments,
                                workspace_clone.as_ref(),
                            ))
                        })
                    }
                    Err(e) => Err(e),
                }
            };

            match result {
                Ok(tool_result) => (Ok(serde_json::to_value(tool_result).unwrap()), None),
                Err(e) => (Err(e), None),
            }
        }

        _ => (Err(JsonRpcError::method_not_found(&request.method)), None),
    }
}
