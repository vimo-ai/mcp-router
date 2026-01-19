//! SwiftData migration module
//!
//! Automatically migrates data from SwiftData (SQLite) to JSON files
//! when servers.json doesn't exist but the SwiftData database does.

use std::collections::HashMap;
use std::path::PathBuf;

use rusqlite::{Connection, OpenFlags};

use crate::config::{ServerConfig, ServerType, StdioProtocol};
use super::{ensure_config_dir, PersistenceError, RouterConfigManager};

/// Get SwiftData database path: ~/Library/Application Support/mcp-router.store
fn get_swiftdata_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| {
        home.join("Library")
            .join("Application Support")
            .join("mcp-router.store")
    })
}

/// Check if SwiftData database exists
pub fn swiftdata_exists() -> bool {
    get_swiftdata_path()
        .map(|p| p.exists())
        .unwrap_or(false)
}

/// Migrate servers from SwiftData to servers.json
/// Returns Ok(count) where count is number of servers migrated
pub fn migrate_servers_from_swiftdata() -> Result<usize, PersistenceError> {
    let db_path = get_swiftdata_path()
        .ok_or(PersistenceError::HomeDirNotFound)?;

    if !db_path.exists() {
        tracing::debug!("SwiftData database not found, skipping migration");
        return Ok(0);
    }

    // Open database read-only
    let conn = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| PersistenceError::InvalidJson(format!("Failed to open SwiftData: {}", e)))?;

    // Query servers
    let mut stmt = conn.prepare(
        "SELECT ZNAME, ZTYPE, ZURL, ZCOMMAND, ZSERVERDESCRIPTION, ZISENABLED, ZHEADERS, ZARGS, ZENV
         FROM ZSERVERCONFIG"
    ).map_err(|e| PersistenceError::InvalidJson(format!("SQL error: {}", e)))?;

    let servers: Vec<ServerConfig> = stmt.query_map([], |row| {
        let name: String = row.get(0)?;
        let type_str: Option<String> = row.get(1)?;
        let url: Option<String> = row.get(2)?;
        let command: Option<String> = row.get(3)?;
        let description: Option<String> = row.get(4)?;
        let is_enabled: i32 = row.get(5).unwrap_or(1);
        let _headers_blob: Option<Vec<u8>> = row.get(6).ok();
        let _args_blob: Option<Vec<u8>> = row.get(7).ok();
        let _env_blob: Option<Vec<u8>> = row.get(8).ok();

        let server_type = match type_str.as_deref() {
            Some("stdio") => ServerType::Stdio,
            _ => ServerType::Http,
        };

        Ok(ServerConfig {
            name,
            server_type,
            description: description.unwrap_or_default(),
            is_enabled: is_enabled != 0,
            flatten_mode: false,
            url,
            headers: HashMap::new(),
            command,
            args: Vec::new(),
            env: HashMap::new(),
            stdio_protocol: StdioProtocol::Line,
        })
    })
    .map_err(|e| PersistenceError::InvalidJson(format!("Query error: {}", e)))?
    .filter_map(|r| r.ok())
    .collect();

    if servers.is_empty() {
        tracing::info!("No servers found in SwiftData");
        return Ok(0);
    }

    // Save to servers.json
    let manager = RouterConfigManager::new()?;
    manager.save_servers(&servers)?;

    tracing::info!("Migrated {} servers from SwiftData to servers.json", servers.len());
    Ok(servers.len())
}

/// Auto-migrate if needed: checks if servers.json is missing but SwiftData exists
pub fn auto_migrate_if_needed() -> Result<usize, PersistenceError> {
    let config_dir = ensure_config_dir()?;
    let servers_file = config_dir.join("servers.json");

    // If servers.json already exists, skip migration
    if servers_file.exists() {
        tracing::debug!("servers.json exists, skipping SwiftData migration");
        return Ok(0);
    }

    // Check if SwiftData database exists
    if !swiftdata_exists() {
        tracing::debug!("No SwiftData database found, skipping migration");
        return Ok(0);
    }

    tracing::info!("servers.json not found, attempting to migrate from SwiftData...");
    migrate_servers_from_swiftdata()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_swiftdata_path() {
        let path = get_swiftdata_path();
        assert!(path.is_some());
        let p = path.unwrap();
        assert!(p.to_string_lossy().contains("mcp-router.store"));
    }
}
