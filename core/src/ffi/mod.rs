//! FFI bindings for Swift/C
//!
//! This module provides C-compatible functions for use from Swift.
//! All strings are passed as C strings and must be freed by the caller.
//!
//! Functions that can fail use out parameters:
//! - Returns `bool` (true = success, false = failure)
//! - `out_error: *mut *mut c_char` receives error message on failure (caller must free)

use crate::config::{AppSettings, ServerConfig, Workspace};
use crate::get_runtime;
use crate::persistence::{ClaudeConfigManager, McpConfigManager, RouterConfigManager};
use crate::router::McpRouter;
use crate::server;
use libc::{c_char, c_void};
use parking_lot::RwLock;
use std::ffi::{CStr, CString};
use std::sync::Arc;
use tokio::sync::oneshot;

/// Callback type for async tool calls
/// - context: opaque pointer passed back to Swift (e.g., continuation)
/// - success: true if call succeeded
/// - result_json: JSON string of result (null if failed)
/// - error_message: error message (null if succeeded)
///
/// NOTE: Strings are valid only during callback. Swift must copy if needed.
pub type McpToolCallback = extern "C" fn(
    context: *mut c_void,
    success: bool,
    result_json: *const c_char,
    error_message: *const c_char,
);

/// Context wrapper for async callbacks - allows sending across threads
/// SAFETY: The context pointer is managed by Swift and remains valid until callback completes
struct AsyncCallbackContext {
    callback: McpToolCallback,
    /// Store as usize to make it Send-safe, convert back to *mut c_void when calling
    context_addr: usize,
}

unsafe impl Send for AsyncCallbackContext {}

impl AsyncCallbackContext {
    fn new(callback: McpToolCallback, context: *mut c_void) -> Self {
        Self {
            callback,
            context_addr: context as usize,
        }
    }

    fn invoke(&self, success: bool, result: *const c_char, error: *const c_char) {
        (self.callback)(self.context_addr as *mut c_void, success, result, error);
    }
}

/// Opaque handle to the router
pub struct McpRouterHandle {
    router: Arc<RwLock<McpRouter>>,
    shutdown_tx: Option<oneshot::Sender<()>>,
}

/// Helper to set error message
unsafe fn set_error(out_error: *mut *mut c_char, msg: &str) {
    if !out_error.is_null() {
        if let Ok(c_string) = CString::new(msg) {
            *out_error = c_string.into_raw();
        }
    }
}

// MARK: - Router Lifecycle

/// Create a new router instance
#[no_mangle]
pub extern "C" fn mcp_router_create() -> *mut McpRouterHandle {
    let router = Arc::new(RwLock::new(McpRouter::new()));
    let handle = Box::new(McpRouterHandle {
        router,
        shutdown_tx: None,
    });
    Box::into_raw(handle)
}

/// Destroy the router instance
#[no_mangle]
pub extern "C" fn mcp_router_destroy(handle: *mut McpRouterHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}

/// Free a string returned by the library
#[no_mangle]
pub extern "C" fn mcp_router_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

// MARK: - Server Management

/// Add an HTTP server configuration
/// Returns true on success, false on failure (error message in out_error)
#[no_mangle]
pub extern "C" fn mcp_router_add_http_server(
    handle: *mut McpRouterHandle,
    name: *const c_char,
    url: *const c_char,
    description: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() || name.is_null() || url.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let name = unsafe { CStr::from_ptr(name) }
        .to_str()
        .unwrap_or_default()
        .to_string();
    let url = unsafe { CStr::from_ptr(url) }
        .to_str()
        .unwrap_or_default()
        .to_string();
    let description = if description.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(description) }
            .to_str()
            .unwrap_or_default()
            .to_string()
    };

    let handle = unsafe { &mut *handle };
    let config = ServerConfig::new_http(&name, &url).with_description(&description);

    let mut router = handle.router.write();
    router.load_servers(vec![config]);

    true
}

/// Add a stdio server configuration (JSON format)
#[no_mangle]
pub extern "C" fn mcp_router_add_server_json(
    handle: *mut McpRouterHandle,
    json: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() || json.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let json_str = unsafe { CStr::from_ptr(json) }
        .to_str()
        .unwrap_or_default();

    let config: ServerConfig = match serde_json::from_str(json_str) {
        Ok(c) => c,
        Err(e) => {
            unsafe { set_error(out_error, &format!("Invalid JSON: {}", e)) };
            return false;
        }
    };

    let handle = unsafe { &mut *handle };
    let mut router = handle.router.write();
    router.add_server(config);

    true
}

/// Load servers from JSON array
#[no_mangle]
pub extern "C" fn mcp_router_load_servers_json(
    handle: *mut McpRouterHandle,
    json: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() || json.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let json_str = unsafe { CStr::from_ptr(json) }
        .to_str()
        .unwrap_or_default();

    let configs: Vec<ServerConfig> = match serde_json::from_str(json_str) {
        Ok(c) => c,
        Err(e) => {
            unsafe { set_error(out_error, &format!("Invalid JSON: {}", e)) };
            return false;
        }
    };

    let handle = unsafe { &mut *handle };
    let mut router = handle.router.write();
    router.load_servers(configs);

    true
}

/// Load workspaces from JSON array
#[no_mangle]
pub extern "C" fn mcp_router_load_workspaces_json(
    handle: *mut McpRouterHandle,
    json: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() || json.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let json_str = unsafe { CStr::from_ptr(json) }
        .to_str()
        .unwrap_or_default();

    let workspaces: Vec<Workspace> = match serde_json::from_str(json_str) {
        Ok(w) => w,
        Err(e) => {
            unsafe { set_error(out_error, &format!("Invalid JSON: {}", e)) };
            return false;
        }
    };

    let handle = unsafe { &mut *handle };
    let mut router = handle.router.write();
    router.load_workspaces(workspaces);

    true
}

// MARK: - Server Query & Management

/// List all servers as JSON array
#[no_mangle]
pub extern "C" fn mcp_router_list_servers(handle: *mut McpRouterHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    let handle = unsafe { &*handle };
    let router = handle.router.read();
    let configs = router.server_configs();

    match serde_json::to_string(configs) {
        Ok(json) => CString::new(json)
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Remove a server by name
#[no_mangle]
pub extern "C" fn mcp_router_remove_server(
    handle: *mut McpRouterHandle,
    name: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() || name.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let name = unsafe { CStr::from_ptr(name) }
        .to_str()
        .unwrap_or_default();

    let handle = unsafe { &mut *handle };
    let mut router = handle.router.write();

    if router.remove_server(name) {
        true
    } else {
        unsafe { set_error(out_error, "Server not found") };
        false
    }
}

/// Set server enabled/disabled and persist to servers.json
#[no_mangle]
pub extern "C" fn mcp_router_set_server_enabled(
    handle: *mut McpRouterHandle,
    name: *const c_char,
    enabled: bool,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() || name.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let name = unsafe { CStr::from_ptr(name) }
        .to_str()
        .unwrap_or_default();

    let handle = unsafe { &mut *handle };
    let mut router = handle.router.write();
    router.set_server_enabled(name, enabled);

    // Persist to servers.json
    if let Some(config) = router.server_configs().iter().find(|c| c.name == name) {
        if let Ok(manager) = RouterConfigManager::new() {
            if let Err(e) = manager.upsert_server(config) {
                tracing::warn!("Failed to persist server '{}' enabled={}: {}", name, enabled, e);
                unsafe { set_error(out_error, &format!("Failed to persist: {}", e)) };
                return false;
            }
            tracing::info!("Persisted server '{}' enabled={} to servers.json", name, enabled);
        }
    }

    true
}

/// Set server flatten mode and persist to servers.json
#[no_mangle]
pub extern "C" fn mcp_router_set_server_flatten_mode(
    handle: *mut McpRouterHandle,
    name: *const c_char,
    flatten: bool,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() || name.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let name = unsafe { CStr::from_ptr(name) }
        .to_str()
        .unwrap_or_default();

    let handle = unsafe { &mut *handle };
    let mut router = handle.router.write();
    router.set_server_flatten_mode(name, flatten);

    // Persist to servers.json
    if let Some(config) = router.server_configs().iter().find(|c| c.name == name) {
        if let Ok(manager) = RouterConfigManager::new() {
            if let Err(e) = manager.upsert_server(config) {
                tracing::warn!("Failed to persist server '{}' flatten={}: {}", name, flatten, e);
                unsafe { set_error(out_error, &format!("Failed to persist: {}", e)) };
                return false;
            }
            tracing::info!("Persisted server '{}' flatten={} to servers.json", name, flatten);
        }
    }

    true
}

/// Set expose management tools (Light/Full mode)
/// - false = Light mode (basic tools only)
/// - true = Full mode (includes add_server, remove_server, update_server)
#[no_mangle]
pub extern "C" fn mcp_router_set_expose_management_tools(
    handle: *mut McpRouterHandle,
    expose: bool,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() {
        unsafe { set_error(out_error, "Invalid handle") };
        return false;
    }

    let handle = unsafe { &mut *handle };
    let mut router = handle.router.write();
    router.set_expose_management_tools(expose);

    true
}

/// Get current expose management tools setting
#[no_mangle]
pub extern "C" fn mcp_router_get_expose_management_tools(handle: *mut McpRouterHandle) -> bool {
    if handle.is_null() {
        return false;
    }

    let handle = unsafe { &*handle };
    let router = handle.router.read();
    router.expose_management_tools()
}

/// Get router status as JSON
#[no_mangle]
pub extern "C" fn mcp_router_get_status(handle: *mut McpRouterHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    let handle = unsafe { &*handle };
    let router = handle.router.read();
    let is_running = handle.shutdown_tx.is_some();

    let status = serde_json::json!({
        "is_running": is_running,
        "server_count": router.server_count(),
        "enabled_server_count": router.enabled_server_count(),
    });

    match serde_json::to_string(&status) {
        Ok(json) => CString::new(json)
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        Err(_) => std::ptr::null_mut(),
    }
}

// MARK: - HTTP Server Control

/// Start the HTTP server
#[no_mangle]
pub extern "C" fn mcp_router_start_server(
    handle: *mut McpRouterHandle,
    port: u16,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() {
        unsafe { set_error(out_error, "Invalid handle") };
        return false;
    }

    let handle = unsafe { &mut *handle };

    // Check if already running
    if handle.shutdown_tx.is_some() {
        unsafe { set_error(out_error, "Server already running") };
        return false;
    }

    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    handle.shutdown_tx = Some(shutdown_tx);

    let router = handle.router.clone();

    // Start server on global runtime
    get_runtime().spawn(async move {
        if let Err(e) = server::run_server(port, router, shutdown_rx).await {
            tracing::error!("Server error: {}", e);
        }
    });

    true
}

/// Stop the HTTP server
#[no_mangle]
pub extern "C" fn mcp_router_stop_server(
    handle: *mut McpRouterHandle,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() {
        unsafe { set_error(out_error, "Invalid handle") };
        return false;
    }

    let handle = unsafe { &mut *handle };

    if let Some(tx) = handle.shutdown_tx.take() {
        let _ = tx.send(());
        true
    } else {
        unsafe { set_error(out_error, "Server not running") };
        false
    }
}

// MARK: - Utilities

/// Initialize logging (call once at startup)
/// Only shows WARN+ for mcp_router_core, silences other crates
#[no_mangle]
pub extern "C" fn mcp_router_init_logging() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive(tracing::Level::ERROR.into())
                .add_directive("mcp_router_core=warn".parse().unwrap()),
        )
        .try_init();
}

/// Get version string
#[no_mangle]
pub extern "C" fn mcp_router_version() -> *mut c_char {
    let version = env!("CARGO_PKG_VERSION");
    CString::new(version)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

// MARK: - Async Tool Calls

/// Call a tool asynchronously
///
/// This function returns immediately. The callback will be invoked on completion.
/// The callback is called from a background thread - Swift must dispatch to main if needed.
///
/// Parameters:
/// - handle: Router handle
/// - server_name: Name of the server (e.g., "lsp")
/// - tool_name: Name of the tool (e.g., "lsp_goto_definition")
/// - arguments_json: JSON string of tool arguments
/// - workspace_token: Optional workspace token (can be null for default)
/// - timeout_secs: Timeout in seconds (0 = default 120s)
/// - callback: Function to call on completion
/// - context: Opaque pointer passed to callback (typically Swift continuation)
/// - out_error: Receives error message if function returns false
///
/// Returns: true if async call was started, false if setup failed
#[no_mangle]
pub extern "C" fn mcp_router_call_tool_async(
    handle: *mut McpRouterHandle,
    server_name: *const c_char,
    tool_name: *const c_char,
    arguments_json: *const c_char,
    workspace_token: *const c_char,
    timeout_secs: u32,
    callback: McpToolCallback,
    context: *mut c_void,
    out_error: *mut *mut c_char,
) -> bool {
    // Validate handle
    if handle.is_null() {
        unsafe { set_error(out_error, "Invalid handle") };
        return false;
    }

    // Validate required parameters
    if server_name.is_null() || tool_name.is_null() || arguments_json.is_null() {
        unsafe { set_error(out_error, "Invalid arguments: server_name, tool_name, and arguments_json are required") };
        return false;
    }

    // Parse parameters (must be done on calling thread)
    let server_name = match unsafe { CStr::from_ptr(server_name) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => {
            unsafe { set_error(out_error, "Invalid UTF-8 in server_name") };
            return false;
        }
    };

    let tool_name = match unsafe { CStr::from_ptr(tool_name) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => {
            unsafe { set_error(out_error, "Invalid UTF-8 in tool_name") };
            return false;
        }
    };

    let arguments_str = match unsafe { CStr::from_ptr(arguments_json) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => {
            unsafe { set_error(out_error, "Invalid UTF-8 in arguments_json") };
            return false;
        }
    };

    let arguments: serde_json::Value = match serde_json::from_str(&arguments_str) {
        Ok(v) => v,
        Err(e) => {
            unsafe { set_error(out_error, &format!("Invalid JSON in arguments: {}", e)) };
            return false;
        }
    };

    let workspace_token = if workspace_token.is_null() {
        None
    } else {
        match unsafe { CStr::from_ptr(workspace_token) }.to_str() {
            Ok(s) if !s.is_empty() => Some(s.to_string()),
            _ => None,
        }
    };

    let timeout = if timeout_secs == 0 {
        std::time::Duration::from_secs(120) // Default 120 seconds
    } else {
        std::time::Duration::from_secs(timeout_secs as u64)
    };

    // Get router reference
    let handle = unsafe { &*handle };
    let router = handle.router.clone();

    let ctx = AsyncCallbackContext::new(callback, context);

    // Spawn async task on global runtime (use spawn_blocking for non-Send futures)
    get_runtime().spawn_blocking(move || {
        get_runtime().block_on(async move {
            // Find workspace
            let router_read = router.read();
            let workspace = router_read.find_workspace(workspace_token.as_deref());
            drop(router_read);

            // Call tool with timeout
            let result = tokio::time::timeout(timeout, async {
                let router_read = router.read();
                router_read.call_tool(&server_name, &tool_name, arguments, workspace.as_ref()).await
            }).await;

        match result {
            Ok(Ok(tool_result)) => {
                // Serialize result
                match serde_json::to_string(&tool_result) {
                    Ok(json) => {
                        let json_cstr = CString::new(json)
                            .unwrap_or_else(|_| CString::new("{}").unwrap());
                        ctx.invoke(true, json_cstr.as_ptr(), std::ptr::null());
                    }
                    Err(e) => {
                        let error_msg = CString::new(format!("Failed to serialize result: {}", e))
                            .unwrap_or_else(|_| CString::new("Serialization error").unwrap());
                        ctx.invoke(false, std::ptr::null(), error_msg.as_ptr());
                    }
                }
            }
            Ok(Err(e)) => {
                let error_msg = CString::new(format!("Tool call failed: {}", e.message))
                    .unwrap_or_else(|_| CString::new("Tool error").unwrap());
                ctx.invoke(false, std::ptr::null(), error_msg.as_ptr());
            }
            Err(_) => {
                let error_msg = CString::new(format!("Tool call timed out after {} seconds", timeout.as_secs()))
                    .unwrap_or_else(|_| CString::new("Timeout").unwrap());
                ctx.invoke(false, std::ptr::null(), error_msg.as_ptr());
            }
        }
        })
    });

    true
}

/// List tools for a server asynchronously
///
/// Similar to call_tool_async, returns immediately and invokes callback on completion.
#[no_mangle]
pub extern "C" fn mcp_router_list_tools_async(
    handle: *mut McpRouterHandle,
    server_name: *const c_char,
    workspace_token: *const c_char,
    timeout_secs: u32,
    callback: McpToolCallback,
    context: *mut c_void,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() {
        unsafe { set_error(out_error, "Invalid handle") };
        return false;
    }

    if server_name.is_null() {
        unsafe { set_error(out_error, "server_name is required") };
        return false;
    }

    let server_name = match unsafe { CStr::from_ptr(server_name) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => {
            unsafe { set_error(out_error, "Invalid UTF-8 in server_name") };
            return false;
        }
    };

    let workspace_token = if workspace_token.is_null() {
        None
    } else {
        match unsafe { CStr::from_ptr(workspace_token) }.to_str() {
            Ok(s) if !s.is_empty() => Some(s.to_string()),
            _ => None,
        }
    };

    let timeout = if timeout_secs == 0 {
        std::time::Duration::from_secs(60) // Default 60 seconds for list
    } else {
        std::time::Duration::from_secs(timeout_secs as u64)
    };

    let handle = unsafe { &*handle };
    let router = handle.router.clone();

    let ctx = AsyncCallbackContext::new(callback, context);

    get_runtime().spawn_blocking(move || {
        get_runtime().block_on(async move {
            let router_read = router.read();
            let workspace = router_read.find_workspace(workspace_token.as_deref());

            let result = tokio::time::timeout(timeout, async {
                router_read.list_tools_for_server(&server_name, workspace.as_ref()).await
            }).await;

            match result {
                Ok(Ok(tools)) => {
                    match serde_json::to_string(&tools) {
                        Ok(json) => {
                            let json_cstr = CString::new(json)
                                .unwrap_or_else(|_| CString::new("[]").unwrap());
                            ctx.invoke(true, json_cstr.as_ptr(), std::ptr::null());
                        }
                        Err(e) => {
                            let error_msg = CString::new(format!("Failed to serialize: {}", e))
                                .unwrap_or_else(|_| CString::new("Serialization error").unwrap());
                            ctx.invoke(false, std::ptr::null(), error_msg.as_ptr());
                        }
                    }
                }
                Ok(Err(e)) => {
                    let error_msg = CString::new(format!("Failed to list tools: {}", e))
                        .unwrap_or_else(|_| CString::new("List error").unwrap());
                    ctx.invoke(false, std::ptr::null(), error_msg.as_ptr());
                }
                Err(_) => {
                    let error_msg = CString::new(format!("List tools timed out after {} seconds", timeout.as_secs()))
                        .unwrap_or_else(|_| CString::new("Timeout").unwrap());
                    ctx.invoke(false, std::ptr::null(), error_msg.as_ptr());
                }
            }
        })
    });

    true
}

// MARK: - Persistence: Settings

/// Load settings from ~/.vimo/mcp-router/settings.json
/// Returns JSON string on success (caller must free), null on failure
#[no_mangle]
pub extern "C" fn mcp_router_load_settings(
    out_error: *mut *mut c_char,
) -> *mut c_char {
    let manager = match RouterConfigManager::new() {
        Ok(m) => m,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            return std::ptr::null_mut();
        }
    };

    match manager.load_settings() {
        Ok(settings) => {
            match serde_json::to_string(&settings) {
                Ok(json) => CString::new(json)
                    .map(|s| s.into_raw())
                    .unwrap_or(std::ptr::null_mut()),
                Err(e) => {
                    unsafe { set_error(out_error, &e.to_string()) };
                    std::ptr::null_mut()
                }
            }
        }
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            std::ptr::null_mut()
        }
    }
}

/// Save settings to ~/.vimo/mcp-router/settings.json
#[no_mangle]
pub extern "C" fn mcp_router_save_settings(
    json: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    if json.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let json_str = unsafe { CStr::from_ptr(json) }
        .to_str()
        .unwrap_or_default();

    let settings: AppSettings = match serde_json::from_str(json_str) {
        Ok(s) => s,
        Err(e) => {
            unsafe { set_error(out_error, &format!("Invalid JSON: {}", e)) };
            return false;
        }
    };

    let manager = match RouterConfigManager::new() {
        Ok(m) => m,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            return false;
        }
    };

    match manager.save_settings(&settings) {
        Ok(_) => true,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

// MARK: - Persistence: Workspaces

/// Load workspaces from ~/.vimo/mcp-router/workspaces.json into router
#[no_mangle]
pub extern "C" fn mcp_router_load_workspaces_from_file(
    handle: *mut McpRouterHandle,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() {
        unsafe { set_error(out_error, "Invalid handle") };
        return false;
    }

    let manager = match RouterConfigManager::new() {
        Ok(m) => m,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            return false;
        }
    };

    match manager.load_workspaces() {
        Ok(workspaces) => {
            let handle = unsafe { &mut *handle };
            let mut router = handle.router.write();
            router.load_workspaces(workspaces);
            true
        }
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

/// Save workspaces from router to ~/.vimo/mcp-router/workspaces.json
#[no_mangle]
pub extern "C" fn mcp_router_save_workspaces_to_file(
    handle: *mut McpRouterHandle,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() {
        unsafe { set_error(out_error, "Invalid handle") };
        return false;
    }

    let handle = unsafe { &*handle };
    let router = handle.router.read();

    let manager = match RouterConfigManager::new() {
        Ok(m) => m,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            return false;
        }
    };

    // Get workspaces from router
    let workspaces = router.workspaces();

    match manager.save_workspaces(&workspaces) {
        Ok(_) => true,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

// MARK: - Persistence: Claude Config

/// Check if mcp-router is installed in ~/.claude.json
#[no_mangle]
pub extern "C" fn mcp_router_is_installed_to_claude_global(
    out_error: *mut *mut c_char,
) -> bool {
    match ClaudeConfigManager::is_installed() {
        Ok(installed) => installed,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

/// Install mcp-router to ~/.claude.json
#[no_mangle]
pub extern "C" fn mcp_router_install_to_claude_global(
    port: u16,
    out_error: *mut *mut c_char,
) -> bool {
    match ClaudeConfigManager::install(port) {
        Ok(_) => true,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

/// Uninstall mcp-router from ~/.claude.json
#[no_mangle]
pub extern "C" fn mcp_router_uninstall_from_claude_global(
    out_error: *mut *mut c_char,
) -> bool {
    match ClaudeConfigManager::uninstall() {
        Ok(_) => true,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

/// Load servers from ~/.claude.json into router
#[no_mangle]
pub extern "C" fn mcp_router_load_servers_from_claude_config(
    handle: *mut McpRouterHandle,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() {
        unsafe { set_error(out_error, "Invalid handle") };
        return false;
    }

    match ClaudeConfigManager::read_servers() {
        Ok(servers) => {
            let handle = unsafe { &mut *handle };
            let mut router = handle.router.write();
            router.load_servers(servers);
            true
        }
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

/// Load servers from ~/.vimo/mcp-router/servers.json into router (appends to existing)
#[no_mangle]
pub extern "C" fn mcp_router_load_servers_from_router_config(
    handle: *mut McpRouterHandle,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() {
        unsafe { set_error(out_error, "Invalid handle") };
        return false;
    }

    let manager = match RouterConfigManager::new() {
        Ok(m) => m,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            return false;
        }
    };

    match manager.load_servers() {
        Ok(servers) => {
            let handle = unsafe { &mut *handle };
            let mut router = handle.router.write();
            // Append servers (add_server handles deduplication by name)
            for server in servers {
                router.add_server(server);
            }
            true
        }
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

/// Load servers from ~/.vimo/mcp-router/servers.json
/// Also auto-migrates from SwiftData if servers.json doesn't exist
/// NOTE: ~/.claude.json is NOT read here - Claude Code reads it directly
#[no_mangle]
pub extern "C" fn mcp_router_load_all_servers(
    handle: *mut McpRouterHandle,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() {
        unsafe { set_error(out_error, "Invalid handle") };
        return false;
    }

    // Auto-migrate from SwiftData if needed (servers.json doesn't exist)
    match crate::persistence::auto_migrate_if_needed() {
        Ok(count) if count > 0 => {
            tracing::info!("Auto-migrated {} servers from SwiftData", count);
        }
        Err(e) => {
            tracing::warn!("SwiftData migration failed: {}", e);
        }
        _ => {}
    }

    let handle_ref = unsafe { &mut *handle };
    let mut router = handle_ref.router.write();

    // Load from ~/.vimo/mcp-router/servers.json (our own managed servers)
    if let Ok(manager) = RouterConfigManager::new() {
        if let Ok(router_servers) = manager.load_servers() {
            router.load_servers(router_servers);
            tracing::info!("Loaded {} servers from servers.json", router.server_configs().len());
        }
    }

    true
}

/// Add server to both router and config file
/// target: "global" or "project:/path/to/project"
#[no_mangle]
pub extern "C" fn mcp_router_add_server_and_persist(
    handle: *mut McpRouterHandle,
    json: *const c_char,
    target: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() || json.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let json_str = unsafe { CStr::from_ptr(json) }
        .to_str()
        .unwrap_or_default();

    let config: ServerConfig = match serde_json::from_str(json_str) {
        Ok(c) => c,
        Err(e) => {
            unsafe { set_error(out_error, &format!("Invalid JSON: {}", e)) };
            return false;
        }
    };

    let target_str = if target.is_null() {
        "global"
    } else {
        unsafe { CStr::from_ptr(target) }
            .to_str()
            .unwrap_or("global")
    };

    // Add to router
    let handle = unsafe { &mut *handle };
    {
        let mut router = handle.router.write();
        router.add_server(config.clone());
    }

    // Persist based on target
    let result = if target_str == "global" {
        ClaudeConfigManager::upsert_server(&config)
    } else if target_str.starts_with("project:") {
        let project_path = &target_str[8..];
        McpConfigManager::upsert_server(std::path::Path::new(project_path), &config)
    } else {
        unsafe { set_error(out_error, "Invalid target: use 'global' or 'project:/path'") };
        return false;
    };

    match result {
        Ok(_) => true,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

/// Remove server from both router and config file
#[no_mangle]
pub extern "C" fn mcp_router_remove_server_and_persist(
    handle: *mut McpRouterHandle,
    name: *const c_char,
    target: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    if handle.is_null() || name.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let name_str = unsafe { CStr::from_ptr(name) }
        .to_str()
        .unwrap_or_default();

    let target_str = if target.is_null() {
        "global"
    } else {
        unsafe { CStr::from_ptr(target) }
            .to_str()
            .unwrap_or("global")
    };

    // Remove from router
    let handle = unsafe { &mut *handle };
    {
        let mut router = handle.router.write();
        router.remove_server(name_str);
    }

    // Remove from config file
    let result = if target_str == "global" {
        ClaudeConfigManager::remove_server(name_str)
    } else if target_str.starts_with("project:") {
        let project_path = &target_str[8..];
        McpConfigManager::remove_server(std::path::Path::new(project_path), name_str)
    } else {
        unsafe { set_error(out_error, "Invalid target: use 'global' or 'project:/path'") };
        return false;
    };

    match result {
        Ok(_) => true,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

// MARK: - Persistence: Project Config

/// Install mcp-router to project .mcp.json
#[no_mangle]
pub extern "C" fn mcp_router_install_to_project(
    project_path: *const c_char,
    token: *const c_char,
    port: u16,
    out_error: *mut *mut c_char,
) -> bool {
    if project_path.is_null() || token.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let path_str = unsafe { CStr::from_ptr(project_path) }
        .to_str()
        .unwrap_or_default();

    let token_str = unsafe { CStr::from_ptr(token) }
        .to_str()
        .unwrap_or_default();

    match McpConfigManager::install(std::path::Path::new(path_str), token_str, port) {
        Ok(_) => true,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

/// Uninstall mcp-router from project .mcp.json
#[no_mangle]
pub extern "C" fn mcp_router_uninstall_from_project(
    project_path: *const c_char,
    out_error: *mut *mut c_char,
) -> bool {
    if project_path.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return false;
    }

    let path_str = unsafe { CStr::from_ptr(project_path) }
        .to_str()
        .unwrap_or_default();

    match McpConfigManager::uninstall(std::path::Path::new(path_str)) {
        Ok(_) => true,
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            false
        }
    }
}

/// Get workspace token from project .mcp.json
/// Returns token string or null if not found
#[no_mangle]
pub extern "C" fn mcp_router_get_project_token(
    project_path: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut c_char {
    if project_path.is_null() {
        unsafe { set_error(out_error, "Invalid arguments") };
        return std::ptr::null_mut();
    }

    let path_str = unsafe { CStr::from_ptr(project_path) }
        .to_str()
        .unwrap_or_default();

    match McpConfigManager::get_token(std::path::Path::new(path_str)) {
        Ok(Some(token)) => CString::new(token)
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        Ok(None) => std::ptr::null_mut(),
        Err(e) => {
            unsafe { set_error(out_error, &e.to_string()) };
            std::ptr::null_mut()
        }
    }
}
