//! Project-level MCP configuration management
//!
//! Handles reading/writing of `.mcp.json` files in project directories.

use std::fs;
use std::path::Path;

use serde_json::{json, Value};

use crate::config::{ServerConfig, ServerType};
use super::PersistenceError;

const MCP_CONFIG_FILE: &str = ".mcp.json";

/// Project-level MCP configuration manager
pub struct McpConfigManager;

impl McpConfigManager {
    /// Check if .mcp.json exists in the project directory
    pub fn exists(project_path: &Path) -> bool {
        project_path.join(MCP_CONFIG_FILE).exists()
    }

    /// Check if mcp-router is installed in the project config
    pub fn is_installed(project_path: &Path) -> Result<bool, PersistenceError> {
        let config_path = project_path.join(MCP_CONFIG_FILE);

        if !config_path.exists() {
            return Ok(false);
        }

        let content = fs::read_to_string(&config_path)?;
        let json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        let has_router = json.get("mcpServers")
            .and_then(|v| v.as_object())
            .map(|s| s.contains_key("mcp-router"))
            .unwrap_or(false);

        Ok(has_router)
    }

    /// Get the workspace token from project config, if mcp-router is installed
    pub fn get_token(project_path: &Path) -> Result<Option<String>, PersistenceError> {
        let config_path = project_path.join(MCP_CONFIG_FILE);

        if !config_path.exists() {
            return Ok(None);
        }

        let content = fs::read_to_string(&config_path)?;
        let json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        let token = json.get("mcpServers")
            .and_then(|v| v.get("mcp-router"))
            .and_then(|v| v.get("headers"))
            .and_then(|v| v.get("X-Workspace-Token"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        Ok(token)
    }

    /// Install mcp-router to project config
    pub fn install(project_path: &Path, token: &str, port: u16) -> Result<(), PersistenceError> {
        let config_path = project_path.join(MCP_CONFIG_FILE);

        // Read existing config or create empty
        let mut json: Value = if config_path.exists() {
            let content = fs::read_to_string(&config_path)?;
            serde_json::from_str(&content)
                .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?
        } else {
            json!({})
        };

        // Ensure mcpServers exists
        if json.get("mcpServers").is_none() {
            json["mcpServers"] = json!({});
        }

        // Add mcp-router config with token
        json["mcpServers"]["mcp-router"] = json!({
            "type": "http",
            "url": format!("http://localhost:{}", port),
            "headers": {
                "X-Workspace-Token": token
            }
        });

        // Write back with pretty formatting
        let output = serde_json::to_string_pretty(&json)?;
        super::atomic_write(&config_path, &output)?;

        Ok(())
    }

    /// Uninstall mcp-router from project config
    pub fn uninstall(project_path: &Path) -> Result<(), PersistenceError> {
        let config_path = project_path.join(MCP_CONFIG_FILE);

        if !config_path.exists() {
            return Ok(());
        }

        let content = fs::read_to_string(&config_path)?;
        let mut json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        // Remove mcp-router from mcpServers
        if let Some(servers) = json.get_mut("mcpServers").and_then(|v| v.as_object_mut()) {
            servers.remove("mcp-router");

            // If mcpServers is now empty, remove the entire file
            if servers.is_empty() {
                fs::remove_file(&config_path)?;
                return Ok(());
            }
        }

        // Write back
        let output = serde_json::to_string_pretty(&json)?;
        super::atomic_write(&config_path, &output)?;

        Ok(())
    }

    /// Read all MCP servers from project config
    pub fn read_servers(project_path: &Path) -> Result<Vec<ServerConfig>, PersistenceError> {
        let config_path = project_path.join(MCP_CONFIG_FILE);

        if !config_path.exists() {
            return Ok(Vec::new());
        }

        let content = fs::read_to_string(&config_path)?;
        let json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        let servers = json.get("mcpServers")
            .and_then(|v| v.as_object())
            .cloned()
            .unwrap_or_default();

        let mut result = Vec::new();
        for (name, config) in servers {
            // Skip mcp-router itself
            if name == "mcp-router" {
                continue;
            }
            if let Some(server_config) = super::parse_server_config(&name, &config) {
                result.push(server_config);
            }
        }

        Ok(result)
    }

    /// Add or update a server in project config
    pub fn upsert_server(project_path: &Path, config: &ServerConfig) -> Result<(), PersistenceError> {
        let config_path = project_path.join(MCP_CONFIG_FILE);

        // Read existing config or create empty
        let mut json: Value = if config_path.exists() {
            let content = fs::read_to_string(&config_path)?;
            serde_json::from_str(&content)
                .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?
        } else {
            json!({})
        };

        // Ensure mcpServers exists
        if json.get("mcpServers").is_none() {
            json["mcpServers"] = json!({});
        }

        // Convert ServerConfig to Claude format
        let config_value = Self::server_config_to_value(config);
        json["mcpServers"][&config.name] = config_value;

        // Write back
        let output = serde_json::to_string_pretty(&json)?;
        super::atomic_write(&config_path, &output)?;

        Ok(())
    }

    /// Remove a server from project config
    pub fn remove_server(project_path: &Path, name: &str) -> Result<(), PersistenceError> {
        let config_path = project_path.join(MCP_CONFIG_FILE);

        if !config_path.exists() {
            return Err(PersistenceError::FileNotFound(config_path.display().to_string()));
        }

        let content = fs::read_to_string(&config_path)?;
        let mut json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        // Remove server from mcpServers
        let removed = if let Some(servers) = json.get_mut("mcpServers").and_then(|v| v.as_object_mut()) {
            servers.remove(name).is_some()
        } else {
            false
        };

        if !removed {
            return Err(PersistenceError::ServerNotFound(name.to_string()));
        }

        // Write back
        let output = serde_json::to_string_pretty(&json)?;
        super::atomic_write(&config_path, &output)?;

        Ok(())
    }

    // MARK: - Private helpers

    fn server_config_to_value(config: &ServerConfig) -> Value {
        match config.server_type {
            ServerType::Http => {
                let mut obj = json!({
                    "type": "http",
                    "url": config.url.clone().unwrap_or_default()
                });
                if !config.headers.is_empty() {
                    obj["headers"] = serde_json::to_value(&config.headers).unwrap_or_default();
                }
                obj
            }
            ServerType::Stdio => {
                let mut obj = json!({
                    "command": config.command.clone().unwrap_or_default()
                });
                if !config.args.is_empty() {
                    obj["args"] = serde_json::to_value(&config.args).unwrap_or_default();
                }
                if !config.env.is_empty() {
                    obj["env"] = serde_json::to_value(&config.env).unwrap_or_default();
                }
                obj
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_install_uninstall() {
        let temp_dir = TempDir::new().unwrap();
        let project_path = temp_dir.path();

        // Initially not installed
        assert!(!McpConfigManager::is_installed(project_path).unwrap());

        // Install
        McpConfigManager::install(project_path, "test-token", 19104).unwrap();
        assert!(McpConfigManager::is_installed(project_path).unwrap());

        // Check token
        let token = McpConfigManager::get_token(project_path).unwrap();
        assert_eq!(token, Some("test-token".to_string()));

        // Uninstall
        McpConfigManager::uninstall(project_path).unwrap();
        assert!(!McpConfigManager::is_installed(project_path).unwrap());
    }

    #[test]
    fn test_preserve_existing_config() {
        let temp_dir = TempDir::new().unwrap();
        let project_path = temp_dir.path();
        let config_path = project_path.join(".mcp.json");

        // Create existing config
        let existing = json!({
            "mcpServers": {
                "existing-server": {
                    "command": "npx",
                    "args": ["-y", "@mcp/existing"]
                }
            }
        });
        fs::write(&config_path, serde_json::to_string_pretty(&existing).unwrap()).unwrap();

        // Install mcp-router
        McpConfigManager::install(project_path, "test-token", 19104).unwrap();

        // Verify both exist
        let content = fs::read_to_string(&config_path).unwrap();
        let json: Value = serde_json::from_str(&content).unwrap();

        assert!(json["mcpServers"]["existing-server"].is_object());
        assert!(json["mcpServers"]["mcp-router"].is_object());
    }

    #[test]
    fn test_read_servers() {
        let temp_dir = TempDir::new().unwrap();
        let project_path = temp_dir.path();
        let config_path = project_path.join(".mcp.json");

        // Create config with servers
        let config = json!({
            "mcpServers": {
                "mcp-router": {
                    "type": "http",
                    "url": "http://localhost:19104"
                },
                "my-server": {
                    "command": "npx",
                    "args": ["-y", "@mcp/my-server"]
                }
            }
        });
        fs::write(&config_path, serde_json::to_string_pretty(&config).unwrap()).unwrap();

        // Read servers (should exclude mcp-router)
        let servers = McpConfigManager::read_servers(project_path).unwrap();
        assert_eq!(servers.len(), 1);
        assert_eq!(servers[0].name, "my-server");
    }
}
