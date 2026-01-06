//
//  MCPRouterCore.swift
//  mcp-router
//
//  Swift wrapper for Rust FFI mcp-router-core
//

import Foundation
import mcp_router_core

/// Swift wrapper for the Rust MCP Router Core
final class MCPRouterCore {
    private var handle: OpaquePointer?

    init() {
        handle = mcp_router_create()
        mcp_router_init_logging()
    }

    deinit {
        if let handle = handle {
            mcp_router_destroy(handle)
        }
    }

    // MARK: - Version

    var version: String {
        guard let ptr = mcp_router_version() else { return "unknown" }
        defer { mcp_router_free_string(ptr) }
        return String(cString: ptr)
    }

    // MARK: - Server Management

    /// Load servers from JSON array
    func loadServers(json: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = json.withCString { jsonPtr in
            mcp_router_load_servers_json(handle, jsonPtr, &error)
        }
        if !success, let error = error {
            defer { mcp_router_free_string(error) }
            throw MCPRouterCoreError.loadFailed(String(cString: error))
        }
    }

    /// Load servers from ServerConfig array
    func loadServers(_ configs: [ServerConfig]) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(configs.map { $0.toRustConfig() })
        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPRouterCoreError.encodingFailed
        }
        try loadServers(json: json)
    }

    /// Load workspaces from JSON array
    func loadWorkspaces(json: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = json.withCString { jsonPtr in
            mcp_router_load_workspaces_json(handle, jsonPtr, &error)
        }
        if !success, let error = error {
            defer { mcp_router_free_string(error) }
            throw MCPRouterCoreError.loadFailed(String(cString: error))
        }
    }

    /// List all servers as JSON
    func listServersJSON() -> String? {
        guard let ptr = mcp_router_list_servers(handle) else { return nil }
        defer { mcp_router_free_string(ptr) }
        return String(cString: ptr)
    }

    /// Add HTTP server
    func addHTTPServer(name: String, url: String, description: String = "") throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = name.withCString { namePtr in
            url.withCString { urlPtr in
                description.withCString { descPtr in
                    mcp_router_add_http_server(handle, namePtr, urlPtr, descPtr, &error)
                }
            }
        }
        if !success, let error = error {
            defer { mcp_router_free_string(error) }
            throw MCPRouterCoreError.addServerFailed(String(cString: error))
        }
    }

    /// Add server from JSON
    func addServerJSON(_ json: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = json.withCString { jsonPtr in
            mcp_router_add_server_json(handle, jsonPtr, &error)
        }
        if !success, let error = error {
            defer { mcp_router_free_string(error) }
            throw MCPRouterCoreError.addServerFailed(String(cString: error))
        }
    }

    /// Remove server by name
    func removeServer(name: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = name.withCString { namePtr in
            mcp_router_remove_server(handle, namePtr, &error)
        }
        if !success, let error = error {
            defer { mcp_router_free_string(error) }
            throw MCPRouterCoreError.removeServerFailed(String(cString: error))
        }
    }

    /// Set server enabled/disabled
    func setServerEnabled(name: String, enabled: Bool) throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = name.withCString { namePtr in
            mcp_router_set_server_enabled(handle, namePtr, enabled, &error)
        }
        if !success, let error = error {
            defer { mcp_router_free_string(error) }
            throw MCPRouterCoreError.updateFailed(String(cString: error))
        }
    }

    /// Set server flatten mode
    func setServerFlattenMode(name: String, flatten: Bool) throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = name.withCString { namePtr in
            mcp_router_set_server_flatten_mode(handle, namePtr, flatten, &error)
        }
        if !success, let error = error {
            defer { mcp_router_free_string(error) }
            throw MCPRouterCoreError.updateFailed(String(cString: error))
        }
    }

    // MARK: - Management Tools Mode

    /// Set expose management tools (Light/Full mode)
    var exposeManagementTools: Bool {
        get {
            mcp_router_get_expose_management_tools(handle)
        }
        set {
            var error: UnsafeMutablePointer<CChar>?
            _ = mcp_router_set_expose_management_tools(handle, newValue, &error)
            if let error = error {
                mcp_router_free_string(error)
            }
        }
    }

    // MARK: - HTTP Server Control

    /// Start the HTTP server on specified port
    func startServer(port: UInt16) throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = mcp_router_start_server(handle, port, &error)
        if !success, let error = error {
            defer { mcp_router_free_string(error) }
            throw MCPRouterCoreError.serverStartFailed(String(cString: error))
        }
    }

    /// Stop the HTTP server
    func stopServer() throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = mcp_router_stop_server(handle, &error)
        if !success, let error = error {
            defer { mcp_router_free_string(error) }
            throw MCPRouterCoreError.serverStopFailed(String(cString: error))
        }
    }

    // MARK: - Status

    /// Get router status
    func getStatus() -> RouterStatus? {
        guard let ptr = mcp_router_get_status(handle) else { return nil }
        defer { mcp_router_free_string(ptr) }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RouterStatus.self, from: data)
    }
}

// MARK: - Error Types

enum MCPRouterCoreError: LocalizedError {
    case loadFailed(String)
    case encodingFailed
    case addServerFailed(String)
    case removeServerFailed(String)
    case updateFailed(String)
    case serverStartFailed(String)
    case serverStopFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let msg): return "Load failed: \(msg)"
        case .encodingFailed: return "JSON encoding failed"
        case .addServerFailed(let msg): return "Add server failed: \(msg)"
        case .removeServerFailed(let msg): return "Remove server failed: \(msg)"
        case .updateFailed(let msg): return "Update failed: \(msg)"
        case .serverStartFailed(let msg): return "Server start failed: \(msg)"
        case .serverStopFailed(let msg): return "Server stop failed: \(msg)"
        }
    }
}

// MARK: - Status Model

struct RouterStatus: Codable {
    let isRunning: Bool
    let serverCount: Int
    let enabledServerCount: Int

    enum CodingKeys: String, CodingKey {
        case isRunning = "is_running"
        case serverCount = "server_count"
        case enabledServerCount = "enabled_server_count"
    }
}

// MARK: - ServerConfig Extension for Rust

extension ServerConfig {
    /// Convert to Rust-compatible JSON format
    func toRustConfig() -> RustServerConfig {
        RustServerConfig(
            name: name,
            type: type.rawValue,
            description: serverDescription,
            url: url,
            headers: headers,
            command: command,
            args: args,
            env: env,
            is_enabled: isEnabled,
            flatten_mode: flattenMode
        )
    }
}

/// Rust-compatible server config for JSON serialization
struct RustServerConfig: Encodable {
    let name: String
    let type: String  // Rust expects "type" not "server_type"
    let description: String
    let url: String?
    let headers: [String: String]
    let command: String?
    let args: [String]
    let env: [String: String]
    let is_enabled: Bool
    let flatten_mode: Bool
}
