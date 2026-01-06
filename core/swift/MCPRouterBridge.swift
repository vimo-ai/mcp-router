import Foundation

/// Swift wrapper for MCP Router Rust core
public final class MCPRouterBridge {
    
    private var handle: OpaquePointer?
    
    /// Initialize the router
    public init() {
        handle = mcp_router_create()
    }
    
    deinit {
        if let handle = handle {
            mcp_router_destroy(handle)
        }
    }
    
    /// Initialize logging (call once at app startup)
    public static func initLogging() {
        mcp_router_init_logging()
    }
    
    /// Get library version
    public static var version: String {
        guard let cStr = mcp_router_version() else {
            return "unknown"
        }
        let version = String(cString: cStr)
        mcp_router_free_string(cStr)
        return version
    }
    
    // MARK: - Server Management
    
    /// Add an HTTP server
    public func addHTTPServer(name: String, url: String, description: String = "") throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }
        
        let result = name.withCString { namePtr in
            url.withCString { urlPtr in
                description.withCString { descPtr in
                    mcp_router_add_http_server(handle, namePtr, urlPtr, descPtr)
                }
            }
        }
        
        try checkResult(result)
    }
    
    /// Add a server from JSON configuration
    public func addServerFromJSON(_ json: String) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }
        
        let result = json.withCString { jsonPtr in
            mcp_router_add_server_json(handle, jsonPtr)
        }
        
        try checkResult(result)
    }
    
    /// Load servers from JSON array
    public func loadServersFromJSON(_ json: String) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }
        
        let result = json.withCString { jsonPtr in
            mcp_router_load_servers_json(handle, jsonPtr)
        }
        
        try checkResult(result)
    }
    
    /// Load workspaces from JSON array
    public func loadWorkspacesFromJSON(_ json: String) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }
        
        let result = json.withCString { jsonPtr in
            mcp_router_load_workspaces_json(handle, jsonPtr)
        }
        
        try checkResult(result)
    }
    
    // MARK: - HTTP Server Control
    
    /// Start the HTTP server on the specified port
    public func startServer(port: UInt16) throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }
        
        let result = mcp_router_start_server(handle, port)
        try checkResult(result)
    }
    
    /// Stop the HTTP server
    public func stopServer() throws {
        guard let handle = handle else {
            throw MCPRouterError.invalidHandle
        }
        
        let result = mcp_router_stop_server(handle)
        try checkResult(result)
    }
    
    // MARK: - Private Helpers
    
    private func checkResult(_ result: FfiResult) throws {
        defer {
            mcp_router_free_result(result)
        }
        
        if !result.success {
            let message: String
            if let errorPtr = result.error_message {
                message = String(cString: errorPtr)
            } else {
                message = "Unknown error"
            }
            throw MCPRouterError.operationFailed(message)
        }
    }
}

// MARK: - Errors

public enum MCPRouterError: Error, LocalizedError {
    case invalidHandle
    case operationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidHandle:
            return "Invalid router handle"
        case .operationFailed(let message):
            return message
        }
    }
}
