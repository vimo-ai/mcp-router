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
use libc::c_char;
use parking_lot::RwLock;
use std::ffi::{CStr, CString};
use std::sync::Arc;
use tokio::sync::oneshot;

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
