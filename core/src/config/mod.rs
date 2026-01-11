//! Configuration types and storage

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

fn default_true() -> bool {
    true
}

/// Server type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ServerType {
    Http,
    Stdio,
}

/// Stdio protocol type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum StdioProtocol {
    /// Line-delimited JSON (JSON\n) - default
    #[default]
    Line,
    /// Content-Length header format (standard MCP/LSP protocol)
    ContentLength,
}

/// Server configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    pub name: String,
    #[serde(rename = "type")]
    pub server_type: ServerType,
    #[serde(default)]
    pub description: String,
    #[serde(default = "default_true")]
    pub is_enabled: bool,
    #[serde(default)]
    pub flatten_mode: bool,

    // HTTP type fields
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub headers: HashMap<String, String>,

    // Stdio type fields
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub env: HashMap<String, String>,

    // Stdio protocol type
    #[serde(default)]
    pub stdio_protocol: StdioProtocol,
}

impl ServerConfig {
    pub fn new_http(name: impl Into<String>, url: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            server_type: ServerType::Http,
            description: String::new(),
            is_enabled: true,
            flatten_mode: false,
            url: Some(url.into()),
            headers: HashMap::new(),
            command: None,
            args: Vec::new(),
            env: HashMap::new(),
            stdio_protocol: StdioProtocol::default(),
        }
    }

    pub fn new_stdio(
        name: impl Into<String>,
        command: impl Into<String>,
        args: Vec<String>,
    ) -> Self {
        Self {
            name: name.into(),
            server_type: ServerType::Stdio,
            description: String::new(),
            is_enabled: true,
            flatten_mode: false,
            url: None,
            headers: HashMap::new(),
            command: Some(command.into()),
            args,
            env: HashMap::new(),
            stdio_protocol: StdioProtocol::default(),
        }
    }

    pub fn with_description(mut self, desc: impl Into<String>) -> Self {
        self.description = desc.into();
        self
    }

    pub fn with_flatten_mode(mut self, enabled: bool) -> Self {
        self.flatten_mode = enabled;
        self
    }

    pub fn with_env(mut self, env: HashMap<String, String>) -> Self {
        self.env = env;
        self
    }

    pub fn with_stdio_protocol(mut self, protocol: StdioProtocol) -> Self {
        self.stdio_protocol = protocol;
        self
    }
}

/// Workspace configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Workspace {
    pub token: String,
    pub name: String,
    pub is_default: bool,
    /// Server name -> enabled override
    #[serde(default)]
    pub server_overrides: HashMap<String, bool>,
    /// Server name -> flatten mode override
    #[serde(default)]
    pub flatten_overrides: HashMap<String, bool>,
}

impl Workspace {
    pub fn new(token: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            token: token.into(),
            name: name.into(),
            is_default: false,
            server_overrides: HashMap::new(),
            flatten_overrides: HashMap::new(),
        }
    }

    pub fn default_workspace() -> Self {
        Self {
            token: "default".to_string(),
            name: "Default".to_string(),
            is_default: true,
            server_overrides: HashMap::new(),
            flatten_overrides: HashMap::new(),
        }
    }

    /// Check if a server is enabled for this workspace
    pub fn is_server_enabled(&self, server_name: &str, server_config: &ServerConfig) -> bool {
        self.server_overrides
            .get(server_name)
            .copied()
            .unwrap_or(server_config.is_enabled)
    }

    /// Check if flatten mode is enabled for a server in this workspace
    pub fn is_flatten_enabled(&self, server_name: &str, server_config: &ServerConfig) -> bool {
        self.flatten_overrides
            .get(server_name)
            .copied()
            .unwrap_or(server_config.flatten_mode)
    }
}

/// Application settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    pub server_port: u16,
    pub expose_management_tools: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            server_port: 19104,
            expose_management_tools: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_server_config_http() {
        let config = ServerConfig::new_http("test", "http://localhost:8080")
            .with_description("Test server")
            .with_flatten_mode(true);

        assert_eq!(config.name, "test");
        assert_eq!(config.server_type, ServerType::Http);
        assert_eq!(config.url, Some("http://localhost:8080".to_string()));
        assert!(config.flatten_mode);
    }

    #[test]
    fn test_workspace_overrides() {
        let config = ServerConfig::new_stdio("test", "npx", vec!["-y".to_string()]);
        let mut workspace = Workspace::new("ws1", "Workspace 1");
        workspace.server_overrides.insert("test".to_string(), false);

        assert!(!workspace.is_server_enabled("test", &config));
        assert!(workspace.is_server_enabled("other", &config));
    }
}
