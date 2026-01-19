//! Gemini CLI global configuration management
//!
//! Handles incremental modification of `~/.gemini/settings.json` file.
//! Gemini uses `httpUrl` field for HTTP MCP servers (not `type` + `url`).

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use super::PersistenceError;

/// Get the Gemini config directory: ~/.gemini/
fn get_config_dir() -> Result<PathBuf, PersistenceError> {
    dirs::home_dir()
        .map(|home| home.join(".gemini"))
        .ok_or(PersistenceError::HomeDirNotFound)
}

/// Get the Gemini config file path: ~/.gemini/settings.json
fn get_config_path() -> Result<PathBuf, PersistenceError> {
    get_config_dir().map(|dir| dir.join("settings.json"))
}

/// Gemini global configuration manager
pub struct GeminiConfigManager;

impl GeminiConfigManager {
    /// Check if mcp-router is installed in Gemini global config
    pub fn is_installed() -> Result<bool, PersistenceError> {
        let path = get_config_path()?;
        Self::is_installed_at(&path)
    }

    /// Install mcp-router to Gemini global config
    pub fn install(port: u16) -> Result<(), PersistenceError> {
        let dir = get_config_dir()?;
        let path = dir.join("settings.json");
        Self::install_at(&dir, &path, port)
    }

    /// Uninstall mcp-router from Gemini global config
    pub fn uninstall() -> Result<(), PersistenceError> {
        let path = get_config_path()?;
        Self::uninstall_at(&path)
    }

    /// Restore from backup if it exists
    pub fn restore_backup() -> Result<(), PersistenceError> {
        let path = get_config_path()?;
        super::restore_backup(&path)
    }

    // MARK: - Internal functions (testable with custom paths)

    fn is_installed_at(path: &Path) -> Result<bool, PersistenceError> {
        if !path.exists() {
            return Ok(false);
        }

        let content = fs::read_to_string(path)?;
        let json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        let servers = json.get("mcpServers").and_then(|v| v.as_object());

        Ok(servers
            .map(|s| s.contains_key("mcp-router"))
            .unwrap_or(false))
    }

    fn install_at(dir: &Path, path: &Path, port: u16) -> Result<(), PersistenceError> {
        // Create initial config if file doesn't exist
        if !path.exists() {
            return Self::create_initial_config_at(dir, path, port);
        }

        // Read and backup
        let content = fs::read_to_string(path)?;
        super::create_backup(path, &content)?;

        // Parse JSON
        let mut json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        // Ensure mcpServers exists and is an object
        match json.get("mcpServers") {
            None => {
                json["mcpServers"] = json!({});
            }
            Some(v) if !v.is_object() => {
                super::remove_backup(path);
                return Err(PersistenceError::InvalidFormat(
                    "mcpServers must be an object".to_string(),
                ));
            }
            _ => {}
        }

        // Add mcp-router config (Gemini uses httpUrl, not type+url)
        let router_config = json!({
            "httpUrl": format!("http://localhost:{}", port)
        });

        json["mcpServers"]["mcp-router"] = router_config;

        // Write back with pretty formatting
        let output = serde_json::to_string_pretty(&json)?;
        super::atomic_write(path, &output)?;

        super::remove_backup(path);

        Ok(())
    }

    fn uninstall_at(path: &Path) -> Result<(), PersistenceError> {
        if !path.exists() {
            return Ok(());
        }

        // Read and backup
        let content = fs::read_to_string(path)?;
        super::create_backup(path, &content)?;

        // Parse JSON
        let mut json: Value = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        // Remove mcp-router from mcpServers
        if let Some(servers) = json.get_mut("mcpServers").and_then(|v| v.as_object_mut()) {
            servers.remove("mcp-router");
        }

        // Write back
        let output = serde_json::to_string_pretty(&json)?;
        super::atomic_write(path, &output)?;

        super::remove_backup(path);

        Ok(())
    }

    fn create_initial_config_at(
        dir: &Path,
        path: &Path,
        port: u16,
    ) -> Result<(), PersistenceError> {
        super::ensure_dir_exists(dir)?;

        let config = json!({
            "mcpServers": {
                "mcp-router": {
                    "httpUrl": format!("http://localhost:{}", port)
                }
            }
        });

        let output = serde_json::to_string_pretty(&config)?;
        super::atomic_write(path, &output)?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_config_path() {
        let path = get_config_path();
        assert!(path.is_ok());
        let p = path.unwrap();
        assert!(p.ends_with(".gemini/settings.json"));
    }

    #[test]
    fn test_install_uninstall() {
        let temp_dir = TempDir::new().unwrap();
        let dir = temp_dir.path();
        let path = dir.join("settings.json");

        // Initially not installed
        assert!(!GeminiConfigManager::is_installed_at(&path).unwrap());

        // Install
        GeminiConfigManager::install_at(dir, &path, 19104).unwrap();
        assert!(GeminiConfigManager::is_installed_at(&path).unwrap());

        // Verify content format (httpUrl, not type+url)
        let content = fs::read_to_string(&path).unwrap();
        let json: Value = serde_json::from_str(&content).unwrap();
        assert_eq!(
            json["mcpServers"]["mcp-router"]["httpUrl"],
            "http://localhost:19104"
        );
        // Should NOT have "type" field
        assert!(json["mcpServers"]["mcp-router"]["type"].is_null());

        // Uninstall
        GeminiConfigManager::uninstall_at(&path).unwrap();
        assert!(!GeminiConfigManager::is_installed_at(&path).unwrap());
    }

    #[test]
    fn test_preserve_existing_config() {
        let temp_dir = TempDir::new().unwrap();
        let dir = temp_dir.path();
        let path = dir.join("settings.json");

        // Create existing config with other settings
        let existing = json!({
            "someOtherSetting": true,
            "mcpServers": {
                "existing-server": {
                    "httpUrl": "http://example.com"
                }
            }
        });
        fs::write(&path, serde_json::to_string_pretty(&existing).unwrap()).unwrap();

        // Install mcp-router
        GeminiConfigManager::install_at(dir, &path, 19104).unwrap();

        // Verify both servers exist and other settings preserved
        let content = fs::read_to_string(&path).unwrap();
        let json: Value = serde_json::from_str(&content).unwrap();

        assert_eq!(json["someOtherSetting"], true);
        assert!(json["mcpServers"]["existing-server"].is_object());
        assert!(json["mcpServers"]["mcp-router"].is_object());
    }

    #[test]
    fn test_install_creates_mcp_servers_if_missing() {
        let temp_dir = TempDir::new().unwrap();
        let dir = temp_dir.path();
        let path = dir.join("settings.json");

        // Create config without mcpServers
        let existing = json!({
            "someOtherSetting": true
        });
        fs::write(&path, serde_json::to_string_pretty(&existing).unwrap()).unwrap();

        // Install should create mcpServers
        GeminiConfigManager::install_at(dir, &path, 19104).unwrap();

        let content = fs::read_to_string(&path).unwrap();
        let json: Value = serde_json::from_str(&content).unwrap();

        assert!(json["mcpServers"]["mcp-router"].is_object());
    }

    #[test]
    fn test_uninstall_nonexistent_file_is_ok() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().join("nonexistent.json");

        // Should not error
        assert!(GeminiConfigManager::uninstall_at(&path).is_ok());
    }

    #[test]
    fn test_invalid_json_returns_error() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().join("settings.json");

        // Write invalid JSON
        fs::write(&path, "not valid json").unwrap();

        let result = GeminiConfigManager::is_installed_at(&path);
        assert!(result.is_err());
    }
}
