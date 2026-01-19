//! OpenCode global configuration management
//!
//! Handles incremental modification of `~/.config/opencode/opencode.json` file.
//! OpenCode uses `mcp` field (not `mcpServers`) with `{ "type": "remote", "url": "..." }`.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use super::PersistenceError;

/// Get the OpenCode config directory: ~/.config/opencode/
fn get_config_dir() -> Result<PathBuf, PersistenceError> {
    dirs::home_dir()
        .map(|home| home.join(".config").join("opencode"))
        .ok_or(PersistenceError::HomeDirNotFound)
}

/// Get the OpenCode config file path: ~/.config/opencode/opencode.json
fn get_config_path() -> Result<PathBuf, PersistenceError> {
    get_config_dir().map(|dir| dir.join("opencode.json"))
}

/// OpenCode global configuration manager
pub struct OpenCodeConfigManager;

impl OpenCodeConfigManager {
    /// Check if mcp-router is installed in OpenCode global config
    pub fn is_installed() -> Result<bool, PersistenceError> {
        let path = get_config_path()?;
        Self::is_installed_at(&path)
    }

    /// Install mcp-router to OpenCode global config
    pub fn install(port: u16) -> Result<(), PersistenceError> {
        let dir = get_config_dir()?;
        let path = dir.join("opencode.json");
        Self::install_at(&dir, &path, port)
    }

    /// Uninstall mcp-router from OpenCode global config
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

        // OpenCode uses "mcp" field, not "mcpServers"
        let servers = json.get("mcp").and_then(|v| v.as_object());

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

        // Ensure mcp exists and is an object
        match json.get("mcp") {
            None => {
                json["mcp"] = json!({});
            }
            Some(v) if !v.is_object() => {
                super::remove_backup(path);
                return Err(PersistenceError::InvalidFormat(
                    "mcp must be an object".to_string(),
                ));
            }
            _ => {}
        }

        // Add mcp-router config (OpenCode uses type: "remote", not type: "http")
        let router_config = json!({
            "type": "remote",
            "url": format!("http://localhost:{}", port)
        });

        json["mcp"]["mcp-router"] = router_config;

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

        // Remove mcp-router from mcp
        if let Some(servers) = json.get_mut("mcp").and_then(|v| v.as_object_mut()) {
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
            "mcp": {
                "mcp-router": {
                    "type": "remote",
                    "url": format!("http://localhost:{}", port)
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
        assert!(p.ends_with(".config/opencode/opencode.json"));
    }

    #[test]
    fn test_install_uninstall() {
        let temp_dir = TempDir::new().unwrap();
        let dir = temp_dir.path();
        let path = dir.join("opencode.json");

        // Initially not installed
        assert!(!OpenCodeConfigManager::is_installed_at(&path).unwrap());

        // Install
        OpenCodeConfigManager::install_at(dir, &path, 19104).unwrap();
        assert!(OpenCodeConfigManager::is_installed_at(&path).unwrap());

        // Verify content format (type: "remote", field: "mcp")
        let content = fs::read_to_string(&path).unwrap();
        let json: Value = serde_json::from_str(&content).unwrap();
        assert_eq!(json["mcp"]["mcp-router"]["type"], "remote");
        assert_eq!(json["mcp"]["mcp-router"]["url"], "http://localhost:19104");
        // Should NOT have "mcpServers" field
        assert!(json["mcpServers"].is_null());

        // Uninstall
        OpenCodeConfigManager::uninstall_at(&path).unwrap();
        assert!(!OpenCodeConfigManager::is_installed_at(&path).unwrap());
    }

    #[test]
    fn test_preserve_existing_config() {
        let temp_dir = TempDir::new().unwrap();
        let dir = temp_dir.path();
        let path = dir.join("opencode.json");

        // Create existing config with other settings
        let existing = json!({
            "someOtherSetting": true,
            "mcp": {
                "existing-server": {
                    "type": "remote",
                    "url": "http://example.com"
                }
            }
        });
        fs::write(&path, serde_json::to_string_pretty(&existing).unwrap()).unwrap();

        // Install mcp-router
        OpenCodeConfigManager::install_at(dir, &path, 19104).unwrap();

        // Verify both servers exist and other settings preserved
        let content = fs::read_to_string(&path).unwrap();
        let json: Value = serde_json::from_str(&content).unwrap();

        assert_eq!(json["someOtherSetting"], true);
        assert!(json["mcp"]["existing-server"].is_object());
        assert!(json["mcp"]["mcp-router"].is_object());
    }

    #[test]
    fn test_install_creates_mcp_field_if_missing() {
        let temp_dir = TempDir::new().unwrap();
        let dir = temp_dir.path();
        let path = dir.join("opencode.json");

        // Create config without mcp field
        let existing = json!({
            "someOtherSetting": true
        });
        fs::write(&path, serde_json::to_string_pretty(&existing).unwrap()).unwrap();

        // Install should create mcp field
        OpenCodeConfigManager::install_at(dir, &path, 19104).unwrap();

        let content = fs::read_to_string(&path).unwrap();
        let json: Value = serde_json::from_str(&content).unwrap();

        assert!(json["mcp"]["mcp-router"].is_object());
    }

    #[test]
    fn test_uninstall_nonexistent_file_is_ok() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().join("nonexistent.json");

        // Should not error
        assert!(OpenCodeConfigManager::uninstall_at(&path).is_ok());
    }

    #[test]
    fn test_invalid_json_returns_error() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().join("opencode.json");

        // Write invalid JSON
        fs::write(&path, "not valid json").unwrap();

        let result = OpenCodeConfigManager::is_installed_at(&path);
        assert!(result.is_err());
    }
}
