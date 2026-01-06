//! MCP Client implementations

mod http;
mod stdio;

pub use http::HttpMcpClient;
pub use stdio::StdioMcpClient;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum ClientError {
    #[error("HTTP error: {0}")]
    Http(String),

    #[error("Invalid URL: {0}")]
    InvalidUrl(String),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("RPC error {code}: {message}")]
    Rpc { code: i32, message: String },

    #[error("Empty response")]
    EmptyResponse,

    #[error("Process error: {0}")]
    Process(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Timeout")]
    Timeout,

    #[error("Not connected")]
    NotConnected,
}
