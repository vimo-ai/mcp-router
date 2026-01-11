//! FFI bindings for Swift/C
//!
//! This module provides C-compatible functions for use from Swift.
//! All strings are passed as C strings and must be freed by the caller.
//!
//! Functions that can fail use out parameters:
//! - Returns `bool` (true = success, false = failure)
//! - `out_error: *mut *mut c_char` receives error message on failure (caller must free)

use crate::config::{ServerConfig, Workspace};
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

/// Set server enabled/disabled
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

    true
}

/// Set server flatten mode
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

    // Start server in background
    std::thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().expect("Failed to create runtime");
        rt.block_on(async {
            if let Err(e) = server::run_server(port, router, shutdown_rx).await {
                tracing::error!("Server error: {}", e);
            }
        });
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

    // Spawn async task in background thread
    std::thread::spawn(move || {
        let rt = match tokio::runtime::Runtime::new() {
            Ok(rt) => rt,
            Err(e) => {
                let error_msg = CString::new(format!("Failed to create runtime: {}", e))
                    .unwrap_or_else(|_| CString::new("Runtime error").unwrap());
                ctx.invoke(false, std::ptr::null(), error_msg.as_ptr());
                return;
            }
        };

        rt.block_on(async {
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
        });
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

    std::thread::spawn(move || {
        let rt = match tokio::runtime::Runtime::new() {
            Ok(rt) => rt,
            Err(e) => {
                let error_msg = CString::new(format!("Failed to create runtime: {}", e))
                    .unwrap_or_else(|_| CString::new("Runtime error").unwrap());
                ctx.invoke(false, std::ptr::null(), error_msg.as_ptr());
                return;
            }
        };

        rt.block_on(async {
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
        });
    });

    true
}
