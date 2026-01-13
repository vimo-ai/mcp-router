//! Router's own configuration persistence
//!
//! Handles:
//! - `~/.vimo/mcp-router/settings.json` - Application settings (port, fullMode)
//! - `~/.vimo/mcp-router/workspaces.json` - Workspace configurations
//! - `~/.vimo/mcp-router/servers.json` - Dynamically added MCP servers

use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::config::{AppSettings, ServerConfig, Workspace};
use super::{ensure_config_dir, PersistenceError};

const SETTINGS_FILE: &str = "settings.json";
const WORKSPACES_FILE: &str = "workspaces.json";
const SERVERS_FILE: &str = "servers.json";

/// Wrapper for servers file format
#[derive(Debug, Clone, Serialize, Deserialize)]
struct ServersFile {
    servers: Vec<ServerConfig>,
}

/// Wrapper for workspaces file format
#[derive(Debug, Clone, Serialize, Deserialize)]
struct WorkspacesFile {
    workspaces: Vec<WorkspaceWithPath>,
}

/// Workspace with optional project_path for persistence
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceWithPath {
    pub token: String,
    pub name: String,
    #[serde(default)]
    pub is_default: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_path: Option<String>,
    #[serde(default)]
    pub server_overrides: std::collections::HashMap<String, bool>,
    #[serde(default)]
    pub flatten_overrides: std::collections::HashMap<String, bool>,
}

impl From<WorkspaceWithPath> for Workspace {
    fn from(wp: WorkspaceWithPath) -> Self {
        Workspace {
            token: wp.token,
            name: wp.name,
            is_default: wp.is_default,
            server_overrides: wp.server_overrides,
            flatten_overrides: wp.flatten_overrides,
        }
    }
}

impl From<Workspace> for WorkspaceWithPath {
    fn from(w: Workspace) -> Self {
        WorkspaceWithPath {
            token: w.token,
            name: w.name,
            is_default: w.is_default,
            project_path: None,
            server_overrides: w.server_overrides,
            flatten_overrides: w.flatten_overrides,
        }
    }
}

/// Router configuration manager
pub struct RouterConfigManager {
    config_dir: PathBuf,
}

impl RouterConfigManager {
    /// Create a new manager with the default config directory
    pub fn new() -> Result<Self, PersistenceError> {
        let config_dir = ensure_config_dir()?;
        Ok(Self { config_dir })
    }

    /// Create a manager with a custom config directory (for testing)
    #[cfg(test)]
    pub fn with_dir(config_dir: PathBuf) -> Self {
        Self { config_dir }
    }

    // MARK: - Settings

    /// Load settings from file, returns default if file doesn't exist
    pub fn load_settings(&self) -> Result<AppSettings, PersistenceError> {
        let path = self.config_dir.join(SETTINGS_FILE);

        if !path.exists() {
            return Ok(AppSettings::default());
        }

        let content = fs::read_to_string(&path)?;
        let settings: AppSettings = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        Ok(settings)
    }

    /// Save settings to file
    pub fn save_settings(&self, settings: &AppSettings) -> Result<(), PersistenceError> {
        let path = self.config_dir.join(SETTINGS_FILE);
        let content = serde_json::to_string_pretty(settings)?;

        // Atomic write: write to temp file then rename
        let temp_path = path.with_extension("json.tmp");
        fs::write(&temp_path, &content)?;
        fs::rename(&temp_path, &path)?;

        Ok(())
    }

    // MARK: - Workspaces

    /// Load workspaces from file, returns empty vec if file doesn't exist
    pub fn load_workspaces(&self) -> Result<Vec<Workspace>, PersistenceError> {
        let path = self.config_dir.join(WORKSPACES_FILE);

        if !path.exists() {
            return Ok(Vec::new());
        }

        let content = fs::read_to_string(&path)?;
        let file: WorkspacesFile = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        Ok(file.workspaces.into_iter().map(Into::into).collect())
    }

    /// Load workspaces with their project paths
    pub fn load_workspaces_with_paths(&self) -> Result<Vec<WorkspaceWithPath>, PersistenceError> {
        let path = self.config_dir.join(WORKSPACES_FILE);

        if !path.exists() {
            return Ok(Vec::new());
        }

        let content = fs::read_to_string(&path)?;
        let file: WorkspacesFile = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        Ok(file.workspaces)
    }

    /// Save workspaces to file
    pub fn save_workspaces(&self, workspaces: &[Workspace]) -> Result<(), PersistenceError> {
        let path = self.config_dir.join(WORKSPACES_FILE);

        let file = WorkspacesFile {
            workspaces: workspaces.iter().cloned().map(Into::into).collect(),
        };

        let content = serde_json::to_string_pretty(&file)?;

        // Atomic write
        let temp_path = path.with_extension("json.tmp");
        fs::write(&temp_path, &content)?;
        fs::rename(&temp_path, &path)?;

        Ok(())
    }

    /// Save workspaces with project paths
    pub fn save_workspaces_with_paths(&self, workspaces: &[WorkspaceWithPath]) -> Result<(), PersistenceError> {
        let path = self.config_dir.join(WORKSPACES_FILE);

        let file = WorkspacesFile {
            workspaces: workspaces.to_vec(),
        };

        let content = serde_json::to_string_pretty(&file)?;

        // Atomic write
        let temp_path = path.with_extension("json.tmp");
        fs::write(&temp_path, &content)?;
        fs::rename(&temp_path, &path)?;

        Ok(())
    }

    /// Add or update a workspace
    pub fn upsert_workspace(&self, workspace: WorkspaceWithPath) -> Result<(), PersistenceError> {
        let mut workspaces = self.load_workspaces_with_paths()?;

        if let Some(idx) = workspaces.iter().position(|w| w.token == workspace.token) {
            workspaces[idx] = workspace;
        } else {
            workspaces.push(workspace);
        }

        self.save_workspaces_with_paths(&workspaces)
    }

    /// Remove a workspace by token
    pub fn remove_workspace(&self, token: &str) -> Result<(), PersistenceError> {
        let mut workspaces = self.load_workspaces_with_paths()?;

        let original_len = workspaces.len();
        workspaces.retain(|w| w.token != token);

        if workspaces.len() == original_len {
            return Err(PersistenceError::WorkspaceNotFound(token.to_string()));
        }

        self.save_workspaces_with_paths(&workspaces)
    }

    /// Get workspace by token
    pub fn get_workspace(&self, token: &str) -> Result<Option<WorkspaceWithPath>, PersistenceError> {
        let workspaces = self.load_workspaces_with_paths()?;
        Ok(workspaces.into_iter().find(|w| w.token == token))
    }

    /// Get workspace by project path
    pub fn get_workspace_by_path(&self, project_path: &str) -> Result<Option<WorkspaceWithPath>, PersistenceError> {
        let workspaces = self.load_workspaces_with_paths()?;
        Ok(workspaces.into_iter().find(|w| {
            w.project_path.as_deref() == Some(project_path)
        }))
    }

    // MARK: - Servers

    /// Load servers from file, returns empty vec if file doesn't exist
    pub fn load_servers(&self) -> Result<Vec<ServerConfig>, PersistenceError> {
        let path = self.config_dir.join(SERVERS_FILE);

        if !path.exists() {
            return Ok(Vec::new());
        }

        let content = fs::read_to_string(&path)?;
        let file: ServersFile = serde_json::from_str(&content)
            .map_err(|e| PersistenceError::InvalidJson(e.to_string()))?;

        Ok(file.servers)
    }

    /// Save servers to file
    pub fn save_servers(&self, servers: &[ServerConfig]) -> Result<(), PersistenceError> {
        let path = self.config_dir.join(SERVERS_FILE);

        let file = ServersFile {
            servers: servers.to_vec(),
        };

        let content = serde_json::to_string_pretty(&file)?;

        // Atomic write
        let temp_path = path.with_extension("json.tmp");
        fs::write(&temp_path, &content)?;
        fs::rename(&temp_path, &path)?;

        Ok(())
    }

    /// Add or update a server
    pub fn upsert_server(&self, server: &ServerConfig) -> Result<(), PersistenceError> {
        let mut servers = self.load_servers()?;

        if let Some(idx) = servers.iter().position(|s| s.name == server.name) {
            servers[idx] = server.clone();
        } else {
            servers.push(server.clone());
        }

        self.save_servers(&servers)
    }

    /// Remove a server by name
    pub fn remove_server(&self, name: &str) -> Result<(), PersistenceError> {
        let mut servers = self.load_servers()?;

        let original_len = servers.len();
        servers.retain(|s| s.name != name);

        if servers.len() == original_len {
            return Err(PersistenceError::ServerNotFound(name.to_string()));
        }

        self.save_servers(&servers)
    }

    /// Get a server by name
    pub fn get_server(&self, name: &str) -> Result<Option<ServerConfig>, PersistenceError> {
        let servers = self.load_servers()?;
        Ok(servers.into_iter().find(|s| s.name == name))
    }
}

impl Default for RouterConfigManager {
    fn default() -> Self {
        Self::new().expect("Failed to create RouterConfigManager")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn create_test_manager() -> (RouterConfigManager, TempDir) {
        let temp_dir = TempDir::new().unwrap();
        let manager = RouterConfigManager::with_dir(temp_dir.path().to_path_buf());
        (manager, temp_dir)
    }

    #[test]
    fn test_settings_default() {
        let (manager, _temp) = create_test_manager();
        let settings = manager.load_settings().unwrap();
        assert_eq!(settings.server_port, 19104);
        assert!(!settings.expose_management_tools);
    }

    #[test]
    fn test_settings_save_load() {
        let (manager, _temp) = create_test_manager();

        let settings = AppSettings {
            server_port: 8080,
            expose_management_tools: true,
        };

        manager.save_settings(&settings).unwrap();
        let loaded = manager.load_settings().unwrap();

        assert_eq!(loaded.server_port, 8080);
        assert!(loaded.expose_management_tools);
    }

    #[test]
    fn test_workspaces_empty() {
        let (manager, _temp) = create_test_manager();
        let workspaces = manager.load_workspaces().unwrap();
        assert!(workspaces.is_empty());
    }

    #[test]
    fn test_workspaces_save_load() {
        let (manager, _temp) = create_test_manager();

        let workspaces = vec![
            Workspace::default_workspace(),
            Workspace::new("abc123", "Project A"),
        ];

        manager.save_workspaces(&workspaces).unwrap();
        let loaded = manager.load_workspaces().unwrap();

        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].token, "default");
        assert!(loaded[0].is_default);
        assert_eq!(loaded[1].token, "abc123");
    }

    #[test]
    fn test_workspace_upsert() {
        let (manager, _temp) = create_test_manager();

        let ws1 = WorkspaceWithPath {
            token: "abc123".to_string(),
            name: "Project A".to_string(),
            is_default: false,
            project_path: Some("/path/to/project".to_string()),
            server_overrides: Default::default(),
            flatten_overrides: Default::default(),
        };

        manager.upsert_workspace(ws1.clone()).unwrap();

        let loaded = manager.get_workspace("abc123").unwrap().unwrap();
        assert_eq!(loaded.name, "Project A");

        // Update
        let ws1_updated = WorkspaceWithPath {
            name: "Project A Updated".to_string(),
            ..ws1
        };

        manager.upsert_workspace(ws1_updated).unwrap();

        let loaded = manager.get_workspace("abc123").unwrap().unwrap();
        assert_eq!(loaded.name, "Project A Updated");
    }

    #[test]
    fn test_servers_empty() {
        let (manager, _temp) = create_test_manager();
        let servers = manager.load_servers().unwrap();
        assert!(servers.is_empty());
    }

    #[test]
    fn test_servers_save_load() {
        let (manager, _temp) = create_test_manager();

        let server = ServerConfig::new_http("test-server", "http://localhost:8080");
        manager.upsert_server(&server).unwrap();

        let loaded = manager.load_servers().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].name, "test-server");
    }

    #[test]
    fn test_server_upsert_update() {
        let (manager, _temp) = create_test_manager();

        let server = ServerConfig::new_http("test-server", "http://localhost:8080");
        manager.upsert_server(&server).unwrap();

        // Update the server
        let updated = ServerConfig::new_http("test-server", "http://localhost:9090");
        manager.upsert_server(&updated).unwrap();

        let loaded = manager.load_servers().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].url, Some("http://localhost:9090".to_string()));
    }

    #[test]
    fn test_server_remove() {
        let (manager, _temp) = create_test_manager();

        let server = ServerConfig::new_http("test-server", "http://localhost:8080");
        manager.upsert_server(&server).unwrap();

        manager.remove_server("test-server").unwrap();

        let loaded = manager.load_servers().unwrap();
        assert!(loaded.is_empty());
    }

    #[test]
    fn test_server_remove_not_found() {
        let (manager, _temp) = create_test_manager();

        let result = manager.remove_server("nonexistent");
        assert!(matches!(result, Err(PersistenceError::ServerNotFound(_))));
    }

    #[test]
    fn test_server_get() {
        let (manager, _temp) = create_test_manager();

        let server = ServerConfig::new_http("test-server", "http://localhost:8080");
        manager.upsert_server(&server).unwrap();

        let loaded = manager.get_server("test-server").unwrap();
        assert!(loaded.is_some());
        assert_eq!(loaded.unwrap().name, "test-server");

        let not_found = manager.get_server("nonexistent").unwrap();
        assert!(not_found.is_none());
    }
}
