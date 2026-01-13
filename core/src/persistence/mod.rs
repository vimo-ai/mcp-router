//! Configuration persistence module
//!
//! Handles reading/writing of:
//! - `~/.vimo/mcp-router/settings.json` - Application settings
//! - `~/.vimo/mcp-router/workspaces.json` - Workspace configurations
//! - `~/.claude.json` - Claude global MCP server config
//! - `.mcp.json` - Project-level MCP server config

mod error;
mod router_config;
mod claude_config;
mod mcp_config;
mod swiftdata_migration;

pub use error::PersistenceError;
pub use router_config::RouterConfigManager;
pub use claude_config::ClaudeConfigManager;
pub use mcp_config::McpConfigManager;
pub use swiftdata_migration::auto_migrate_if_needed;

use std::path::PathBuf;

/// Get the MCP Router config directory: ~/.vimo/mcp-router/
pub fn get_config_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".vimo").join("mcp-router"))
}

/// Ensure the config directory exists
pub fn ensure_config_dir() -> Result<PathBuf, PersistenceError> {
    let dir = get_config_dir().ok_or(PersistenceError::HomeDirNotFound)?;
    if !dir.exists() {
        std::fs::create_dir_all(&dir)?;
    }
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_config_dir() {
        let dir = get_config_dir();
        assert!(dir.is_some());
        let path = dir.unwrap();
        assert!(path.ends_with(".vimo/mcp-router"));
    }
}
