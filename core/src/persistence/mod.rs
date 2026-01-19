//! Configuration persistence module
//!
//! Handles reading/writing of:
//! - `~/.vimo/mcp-router/settings.json` - Application settings
//! - `~/.vimo/mcp-router/workspaces.json` - Workspace configurations
//! - `~/.claude.json` - Claude global MCP server config
//! - `~/.gemini/settings.json` - Gemini CLI global config
//! - `~/.config/opencode/opencode.json` - OpenCode global config
//! - `~/.codex/config.toml` - Codex global config
//! - `.mcp.json` - Project-level MCP server config

mod error;
mod router_config;
mod claude_config;
mod gemini_config;
mod opencode_config;
mod codex_config;
mod mcp_config;
mod swiftdata_migration;

pub use error::PersistenceError;
pub use router_config::RouterConfigManager;
pub use claude_config::ClaudeConfigManager;
pub use gemini_config::GeminiConfigManager;
pub use opencode_config::OpenCodeConfigManager;
pub use codex_config::CodexConfigManager;
pub use mcp_config::McpConfigManager;
pub use swiftdata_migration::auto_migrate_if_needed;

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::config::{ServerConfig, ServerType, StdioProtocol};

/// Get the MCP Router config directory: ~/.vimo/mcp-router/
pub fn get_config_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".vimo").join("mcp-router"))
}

/// Ensure the config directory exists
pub fn ensure_config_dir() -> Result<PathBuf, PersistenceError> {
    let dir = get_config_dir().ok_or(PersistenceError::HomeDirNotFound)?;
    ensure_dir_exists(&dir)?;
    Ok(dir)
}

// MARK: - Common utilities for config file operations

/// Ensure a directory exists, creating it if necessary
pub fn ensure_dir_exists(dir: &Path) -> Result<(), PersistenceError> {
    if !dir.exists() {
        fs::create_dir_all(dir)?;
    }
    Ok(())
}

/// Create a backup file (adds .backup before final extension)
pub fn create_backup(config_path: &Path, content: &str) -> Result<(), PersistenceError> {
    let backup_path = backup_path_for(config_path);
    fs::write(&backup_path, content)?;
    Ok(())
}

/// Remove the backup file if it exists
pub fn remove_backup(config_path: &Path) {
    let backup_path = backup_path_for(config_path);
    let _ = fs::remove_file(&backup_path);
}

/// Restore from backup file
pub fn restore_backup(config_path: &Path) -> Result<(), PersistenceError> {
    let backup_path = backup_path_for(config_path);

    if !backup_path.exists() {
        return Err(PersistenceError::BackupNotFound);
    }

    fs::copy(&backup_path, config_path)?;
    fs::remove_file(&backup_path)?;

    Ok(())
}

/// Atomic write: write to temp file then rename
pub fn atomic_write(path: &Path, content: &str) -> Result<(), PersistenceError> {
    let temp_path = temp_path_for(path);
    fs::write(&temp_path, content)?;
    fs::rename(&temp_path, path)?;
    Ok(())
}

/// Get backup path for a config file (e.g., foo.json -> foo.json.backup)
fn backup_path_for(path: &Path) -> PathBuf {
    let mut backup = path.to_path_buf();
    let ext = path.extension()
        .map(|e| format!("{}.backup", e.to_string_lossy()))
        .unwrap_or_else(|| "backup".to_string());
    backup.set_extension(ext);
    backup
}

/// Get temp path for atomic write (e.g., foo.json -> foo.json.tmp)
fn temp_path_for(path: &Path) -> PathBuf {
    let mut temp = path.to_path_buf();
    let ext = path.extension()
        .map(|e| format!("{}.tmp", e.to_string_lossy()))
        .unwrap_or_else(|| "tmp".to_string());
    temp.set_extension(ext);
    temp
}

/// Parse a server config from JSON Value (Claude/MCP format)
/// Used by both claude_config and mcp_config
pub fn parse_server_config(name: &str, config: &Value) -> Option<ServerConfig> {
    // HTTP type: has "url" field
    if let Some(url) = config.get("url").and_then(|v| v.as_str()) {
        let headers: HashMap<String, String> = config.get("headers")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
            .unwrap_or_default();

        return Some(ServerConfig {
            name: name.to_string(),
            server_type: ServerType::Http,
            description: String::new(),
            is_enabled: true,
            flatten_mode: false,
            url: Some(url.to_string()),
            headers,
            command: None,
            args: Vec::new(),
            env: HashMap::new(),
            stdio_protocol: StdioProtocol::default(),
        });
    }

    // Stdio type: has "command" field
    if let Some(command) = config.get("command").and_then(|v| v.as_str()) {
        let args: Vec<String> = config.get("args")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
            .unwrap_or_default();

        let env: HashMap<String, String> = config.get("env")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
            .unwrap_or_default();

        return Some(ServerConfig {
            name: name.to_string(),
            server_type: ServerType::Stdio,
            description: String::new(),
            is_enabled: true,
            flatten_mode: false,
            url: None,
            headers: HashMap::new(),
            command: Some(command.to_string()),
            args,
            env,
            stdio_protocol: StdioProtocol::default(),
        });
    }

    None
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
