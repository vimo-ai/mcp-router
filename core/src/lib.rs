//! MCP Router Core
//!
//! Multi-server MCP proxy with workspace isolation.
//! Provides FFI bindings for Swift/macOS and other platforms.

pub mod client;
pub mod config;
pub mod ffi;
pub mod protocol;
pub mod router;
pub mod server;

use std::sync::Arc;
use parking_lot::RwLock;
use tokio::runtime::Runtime;

/// Global runtime instance for FFI calls
static RUNTIME: std::sync::OnceLock<Runtime> = std::sync::OnceLock::new();

fn get_runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("Failed to create Tokio runtime")
    })
}

/// Global router instance
static ROUTER: std::sync::OnceLock<Arc<RwLock<router::McpRouter>>> = std::sync::OnceLock::new();

fn get_router() -> &'static Arc<RwLock<router::McpRouter>> {
    ROUTER.get_or_init(|| Arc::new(RwLock::new(router::McpRouter::new())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_runtime_init() {
        let rt = get_runtime();
        rt.block_on(async {
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        });
    }
}
