//! Codex global configuration management
//!
//! Handles incremental modification of `~/.codex/config.toml` file.
//! Codex uses TOML format with `[mcp_servers.xxx]` sections.

use std::fs;
use std::path::{Path, PathBuf};

use toml::{Table, Value};

use super::PersistenceError;

/// Get the Codex config directory: ~/.codex/
fn get_config_dir() -> Result<PathBuf, PersistenceError> {
    dirs::home_dir()
        .map(|home| home.join(".codex"))
        .ok_or(PersistenceError::HomeDirNotFound)
}

/// Get the Codex config file path: ~/.codex/config.toml
fn get_config_path() -> Result<PathBuf, PersistenceError> {
    get_config_dir().map(|dir| dir.join("config.toml"))
}

/// Codex global configuration manager
pub struct CodexConfigManager;

impl CodexConfigManager {
    /// Check if mcp-router is installed in Codex global config
    pub fn is_installed() -> Result<bool, PersistenceError> {
        let path = get_config_path()?;
        Self::is_installed_at(&path)
    }

    /// Install mcp-router to Codex global config
    pub fn install(port: u16) -> Result<(), PersistenceError> {
        let dir = get_config_dir()?;
        let path = dir.join("config.toml");
        Self::install_at(&dir, &path, port)
    }

    /// Uninstall mcp-router from Codex global config
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
        let toml: Table = content
            .parse()
            .map_err(|e: toml::de::Error| PersistenceError::InvalidFormat(e.to_string()))?;

        let servers = toml.get("mcp_servers").and_then(|v| v.as_table());

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

        // Parse TOML
        let mut toml: Table = content
            .parse()
            .map_err(|e: toml::de::Error| PersistenceError::InvalidFormat(e.to_string()))?;

        // Ensure mcp_servers exists and is a table
        match toml.get("mcp_servers") {
            None => {
                toml.insert("mcp_servers".to_string(), Value::Table(Table::new()));
            }
            Some(v) if !v.is_table() => {
                super::remove_backup(path);
                return Err(PersistenceError::InvalidFormat(
                    "mcp_servers must be a table".to_string(),
                ));
            }
            _ => {}
        }

        // Create mcp-router config table
        let mut router_config = Table::new();
        router_config.insert("type".to_string(), Value::String("http".to_string()));
        router_config.insert(
            "url".to_string(),
            Value::String(format!("http://localhost:{}", port)),
        );

        // Add to mcp_servers
        if let Some(Value::Table(servers)) = toml.get_mut("mcp_servers") {
            servers.insert("mcp-router".to_string(), Value::Table(router_config));
        }

        // Write back
        let output = toml::to_string_pretty(&toml)
            .map_err(|e| PersistenceError::InvalidFormat(e.to_string()))?;
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

        // Parse TOML
        let mut toml: Table = content
            .parse()
            .map_err(|e: toml::de::Error| PersistenceError::InvalidFormat(e.to_string()))?;

        // Remove mcp-router from mcp_servers
        if let Some(Value::Table(servers)) = toml.get_mut("mcp_servers") {
            servers.remove("mcp-router");
        }

        // Write back
        let output = toml::to_string_pretty(&toml)
            .map_err(|e| PersistenceError::InvalidFormat(e.to_string()))?;
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

        let mut toml = Table::new();
        let mut mcp_servers = Table::new();
        let mut router_config = Table::new();

        router_config.insert("type".to_string(), Value::String("http".to_string()));
        router_config.insert(
            "url".to_string(),
            Value::String(format!("http://localhost:{}", port)),
        );

        mcp_servers.insert("mcp-router".to_string(), Value::Table(router_config));
        toml.insert("mcp_servers".to_string(), Value::Table(mcp_servers));

        let output = toml::to_string_pretty(&toml)
            .map_err(|e| PersistenceError::InvalidFormat(e.to_string()))?;
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
        assert!(p.ends_with(".codex/config.toml"));
    }

    #[test]
    fn test_install_uninstall() {
        let temp_dir = TempDir::new().unwrap();
        let dir = temp_dir.path();
        let path = dir.join("config.toml");

        // Initially not installed
        assert!(!CodexConfigManager::is_installed_at(&path).unwrap());

        // Install
        CodexConfigManager::install_at(dir, &path, 19104).unwrap();
        assert!(CodexConfigManager::is_installed_at(&path).unwrap());

        // Verify content format (TOML with mcp_servers section)
        let content = fs::read_to_string(&path).unwrap();
        let toml: Table = content.parse().unwrap();
        let router = toml["mcp_servers"]["mcp-router"].as_table().unwrap();
        assert_eq!(router["type"].as_str().unwrap(), "http");
        assert_eq!(router["url"].as_str().unwrap(), "http://localhost:19104");

        // Uninstall
        CodexConfigManager::uninstall_at(&path).unwrap();
        assert!(!CodexConfigManager::is_installed_at(&path).unwrap());
    }

    #[test]
    fn test_preserve_existing_config() {
        let temp_dir = TempDir::new().unwrap();
        let dir = temp_dir.path();
        let path = dir.join("config.toml");

        // Create existing config with other settings
        let existing = r#"
[some_other_setting]
value = true

[mcp_servers.existing-server]
type = "http"
url = "http://example.com"
"#;
        fs::write(&path, existing).unwrap();

        // Install mcp-router
        CodexConfigManager::install_at(dir, &path, 19104).unwrap();

        // Verify both servers exist and other settings preserved
        let content = fs::read_to_string(&path).unwrap();
        let toml: Table = content.parse().unwrap();

        assert!(toml["some_other_setting"].is_table());
        assert!(toml["mcp_servers"]["existing-server"].is_table());
        assert!(toml["mcp_servers"]["mcp-router"].is_table());
    }

    #[test]
    fn test_install_creates_mcp_servers_if_missing() {
        let temp_dir = TempDir::new().unwrap();
        let dir = temp_dir.path();
        let path = dir.join("config.toml");

        // Create config without mcp_servers
        let existing = r#"
[some_other_setting]
value = true
"#;
        fs::write(&path, existing).unwrap();

        // Install should create mcp_servers
        CodexConfigManager::install_at(dir, &path, 19104).unwrap();

        let content = fs::read_to_string(&path).unwrap();
        let toml: Table = content.parse().unwrap();

        assert!(toml["mcp_servers"]["mcp-router"].is_table());
    }

    #[test]
    fn test_uninstall_nonexistent_file_is_ok() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().join("nonexistent.toml");

        // Should not error
        assert!(CodexConfigManager::uninstall_at(&path).is_ok());
    }

    #[test]
    fn test_invalid_toml_returns_error() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().join("config.toml");

        // Write invalid TOML
        fs::write(&path, "not valid toml [[[").unwrap();

        let result = CodexConfigManager::is_installed_at(&path);
        assert!(result.is_err());
    }

    #[test]
    fn test_toml_format_is_correct() {
        let temp_dir = TempDir::new().unwrap();
        let dir = temp_dir.path();
        let path = dir.join("config.toml");

        CodexConfigManager::install_at(dir, &path, 19104).unwrap();

        // Verify it's valid TOML and has correct structure
        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("[mcp_servers.mcp-router]"));
        assert!(content.contains("type = \"http\""));
        assert!(content.contains("url = \"http://localhost:19104\""));
    }
}
