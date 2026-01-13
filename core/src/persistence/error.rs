//! Persistence error types

use std::io;
use thiserror::Error;

/// Errors that can occur during configuration persistence
#[derive(Error, Debug)]
pub enum PersistenceError {
    #[error("Home directory not found")]
    HomeDirNotFound,

    #[error("Config file not found: {0}")]
    FileNotFound(String),

    #[error("Invalid JSON format: {0}")]
    InvalidJson(String),

    #[error("Invalid config format: {0}")]
    InvalidFormat(String),

    #[error("IO error: {0}")]
    Io(#[from] io::Error),

    #[error("JSON serialization error: {0}")]
    JsonError(#[from] serde_json::Error),

    #[error("Backup file not found")]
    BackupNotFound,

    #[error("Server '{0}' not found")]
    ServerNotFound(String),

    #[error("Server '{0}' already exists")]
    ServerAlreadyExists(String),

    #[error("Workspace '{0}' not found")]
    WorkspaceNotFound(String),
}
