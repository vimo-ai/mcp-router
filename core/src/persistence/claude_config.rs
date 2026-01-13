//! Claude global configuration management
//!
//! Handles incremental modification of `~/.claude.json` file.
//! Only modifies the `mcpServers` section, preserving all other content.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::config::{ServerConfig, ServerType, StdioProtocol};
use super::PersistenceError;

/// Get the Claude config file path: ~/.claude.json
fn get_claude_config_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".claude.json"))
}

/// Get the backup file path: ~/.claude.json.backup
fn get_backup_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".claude.json.backup"))
}

/// MCP Server configuration in Claude format
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ClaudeMcpServer {
    Http {
        #[serde(rename = "type")]
        server_type: String,
        url: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        headers: Option<HashMap<String, String>>,
    },
    Stdio {
        command: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        args: Vec<String>,
        #[serde(default, skip_serializing_if = "HashMap::is_empty")]
        env: HashMap<String, String>,
    },
}

impl From<&ServerConfig> for ClaudeMcpServer {
    fn from(config: &ServerConfig) -> Self {
        match config.server_type {
            ServerType::Http => ClaudeMcpServer::Http {
                server_type: "http".to_string(),
                url: config.url.clone().unwrap_or_default(),
                headers: if config.headers.is_empty() {
                    None
                } else {
                    Some(config.headers.clone())
                },
            },
            ServerType::Stdio => ClaudeMcpServer::Stdio {
                command: config.command.clone().unwrap_or_default(),
                args: config.args.clone(),
                env: config.env.clone(),
            },
        }
    }
}

/// Claude global configuration manager
pub struct ClaudeConfigManager;

impl ClaudeConfigManager {
    /// Check if mcp-router is installed in global config
    pub fn is_installed() -> Result<bool, PersistenceError> {
        let path = get_claude_config_path()
            .ok_or(PersistenceError::HomeDirNotFound)?;

        if !path.exists() {
            return Ok(false);
        }

        let content = fs::read_to_string(&path)?;
        let json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        let servers = json.get("mcpServers")
            .and_then(|v| v.as_object());

        Ok(servers.map(|s| s.contains_key("mcp-router")).unwrap_or(false))
    }

    /// Install mcp-router to global config
    pub fn install(port: u16) -> Result<(), PersistenceError> {
        let path = get_claude_config_path()
            .ok_or(PersistenceError::HomeDirNotFound)?;

        if !path.exists() {
            return Err(PersistenceError::FileNotFound(path.display().to_string()));
        }

        // Read and backup
        let content = fs::read_to_string(&path)?;
        Self::create_backup(&content)?;

        // Parse JSON
        let mut json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        // Ensure mcpServers exists and is an object
        match json.get("mcpServers") {
            None => {
                json["mcpServers"] = json!({});
            }
            Some(v) if !v.is_object() => {
                Self::remove_backup();
                return Err(PersistenceError::InvalidFormat(
                    "mcpServers must be an object".to_string(),
                ));
            }
            _ => {}
        }

        // Add mcp-router config
        let router_config = json!({
            "type": "http",
            "url": format!("http://localhost:{}", port)
        });

        json["mcpServers"]["mcp-router"] = router_config;

        // Write back with pretty formatting
        let output = serde_json::to_string_pretty(&json)?;
        Self::atomic_write(&path, &output)?;

        // Remove backup on success
        Self::remove_backup();

        Ok(())
    }

    /// Uninstall mcp-router from global config
    pub fn uninstall() -> Result<(), PersistenceError> {
        let path = get_claude_config_path()
            .ok_or(PersistenceError::HomeDirNotFound)?;

        if !path.exists() {
            return Ok(());
        }

        // Read and backup
        let content = fs::read_to_string(&path)?;
        Self::create_backup(&content)?;

        // Parse JSON
        let mut json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        // Remove mcp-router from mcpServers
        if let Some(servers) = json.get_mut("mcpServers").and_then(|v| v.as_object_mut()) {
            servers.remove("mcp-router");
        }

        // Write back
        let output = serde_json::to_string_pretty(&json)?;
        Self::atomic_write(&path, &output)?;

        Self::remove_backup();

        Ok(())
    }

    /// Read all MCP servers from global config
    pub fn read_servers() -> Result<Vec<ServerConfig>, PersistenceError> {
        let path = get_claude_config_path()
            .ok_or(PersistenceError::HomeDirNotFound)?;

        if !path.exists() {
            return Ok(Vec::new());
        }

        let content = fs::read_to_string(&path)?;
        let json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        let servers = json.get("mcpServers")
            .and_then(|v| v.as_object())
            .cloned()
            .unwrap_or_default();

        let mut result = Vec::new();
        for (name, config) in servers {
            if let Some(server_config) = Self::parse_server_config(&name, &config) {
                result.push(server_config);
            }
        }

        Ok(result)
    }

    /// Add or update a server in global config
    pub fn upsert_server(config: &ServerConfig) -> Result<(), PersistenceError> {
        let path = get_claude_config_path()
            .ok_or(PersistenceError::HomeDirNotFound)?;

        if !path.exists() {
            return Err(PersistenceError::FileNotFound(path.display().to_string()));
        }

        // Read and backup
        let content = fs::read_to_string(&path)?;
        Self::create_backup(&content)?;

        // Parse JSON
        let mut json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        // Ensure mcpServers exists and is an object
        match json.get("mcpServers") {
            None => {
                json["mcpServers"] = json!({});
            }
            Some(v) if !v.is_object() => {
                Self::remove_backup();
                return Err(PersistenceError::InvalidFormat(
                    "mcpServers must be an object".to_string(),
                ));
            }
            _ => {}
        }

        // Convert ServerConfig to Claude format
        let claude_config: ClaudeMcpServer = config.into();
        let config_value = serde_json::to_value(&claude_config)?;

        json["mcpServers"][&config.name] = config_value;

        // Write back
        let output = serde_json::to_string_pretty(&json)?;
        Self::atomic_write(&path, &output)?;

        Self::remove_backup();

        Ok(())
    }

    /// Remove a server from global config
    pub fn remove_server(name: &str) -> Result<(), PersistenceError> {
        let path = get_claude_config_path()
            .ok_or(PersistenceError::HomeDirNotFound)?;

        if !path.exists() {
            return Err(PersistenceError::FileNotFound(path.display().to_string()));
        }

        // Read and backup
        let content = fs::read_to_string(&path)?;
        Self::create_backup(&content)?;

        // Parse JSON
        let mut json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        // Remove server from mcpServers
        let removed = if let Some(servers) = json.get_mut("mcpServers").and_then(|v| v.as_object_mut()) {
            servers.remove(name).is_some()
        } else {
            false
        };

        if !removed {
            Self::remove_backup();
            return Err(PersistenceError::ServerNotFound(name.to_string()));
        }

        // Write back
        let output = serde_json::to_string_pretty(&json)?;
        Self::atomic_write(&path, &output)?;

        Self::remove_backup();

        Ok(())
    }

    /// Check if a specific server exists
    pub fn has_server(name: &str) -> Result<bool, PersistenceError> {
        let path = get_claude_config_path()
            .ok_or(PersistenceError::HomeDirNotFound)?;

        if !path.exists() {
            return Ok(false);
        }

        let content = fs::read_to_string(&path)?;
        let json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        let has = json.get("mcpServers")
            .and_then(|v| v.as_object())
            .map(|s| s.contains_key(name))
            .unwrap_or(false);

        Ok(has)
    }

    // MARK: - Private helpers

    fn parse_server_config(name: &str, config: &Value) -> Option<ServerConfig> {
        // Check if it's HTTP type
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

        // Check if it's stdio type
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

    fn create_backup(content: &str) -> Result<(), PersistenceError> {
        if let Some(backup_path) = get_backup_path() {
            fs::write(&backup_path, content)?;
        }
        Ok(())
    }

    fn remove_backup() {
        if let Some(backup_path) = get_backup_path() {
            let _ = fs::remove_file(&backup_path);
        }
    }

    fn atomic_write(path: &PathBuf, content: &str) -> Result<(), PersistenceError> {
        let temp_path = path.with_extension("json.tmp");
        fs::write(&temp_path, content)?;
        fs::rename(&temp_path, path)?;
        Ok(())
    }

    /// Restore from backup if it exists
    pub fn restore_backup() -> Result<(), PersistenceError> {
        let backup_path = get_backup_path()
            .ok_or(PersistenceError::HomeDirNotFound)?;

        if !backup_path.exists() {
            return Err(PersistenceError::BackupNotFound);
        }

        let config_path = get_claude_config_path()
            .ok_or(PersistenceError::HomeDirNotFound)?;

        fs::copy(&backup_path, &config_path)?;
        fs::remove_file(&backup_path)?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    // Note: These tests require a mock home directory setup
    // For now, just testing the parsing logic

    #[test]
    fn test_parse_http_server() {
        let config = json!({
            "type": "http",
            "url": "http://localhost:8080",
            "headers": {
                "X-API-Key": "test"
            }
        });

        let server = ClaudeConfigManager::parse_server_config("test-server", &config).unwrap();
        assert_eq!(server.name, "test-server");
        assert_eq!(server.server_type, ServerType::Http);
        assert_eq!(server.url, Some("http://localhost:8080".to_string()));
        assert_eq!(server.headers.get("X-API-Key"), Some(&"test".to_string()));
    }

    #[test]
    fn test_parse_stdio_server() {
        let config = json!({
            "command": "npx",
            "args": ["-y", "@mcp/server"],
            "env": {
                "NODE_ENV": "production"
            }
        });

        let server = ClaudeConfigManager::parse_server_config("test-server", &config).unwrap();
        assert_eq!(server.name, "test-server");
        assert_eq!(server.server_type, ServerType::Stdio);
        assert_eq!(server.command, Some("npx".to_string()));
        assert_eq!(server.args, vec!["-y", "@mcp/server"]);
        assert_eq!(server.env.get("NODE_ENV"), Some(&"production".to_string()));
    }

    #[test]
    fn test_server_config_to_claude_format() {
        let config = ServerConfig::new_http("test", "http://localhost:8080");
        let claude: ClaudeMcpServer = (&config).into();

        match claude {
            ClaudeMcpServer::Http { server_type, url, .. } => {
                assert_eq!(server_type, "http");
                assert_eq!(url, "http://localhost:8080");
            }
            _ => panic!("Expected HTTP config"),
        }
    }
}
