//
//  ServersView.swift
//  mcp-router
//
//  Server 管理界面 - 卡片式展示
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ServersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [ServerConfig]
    @State private var showingAddServer = false
    @State private var editingServer: ServerConfig?
    @State private var showingImport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if servers.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 16)
                    ], spacing: 16) {
                        ForEach(servers) { server in
                            ServerCardView(server: server) {
                                editingServer = server
                            } onDelete: {
                                deleteServer(server)
                            }
                        }
                    }
                    .padding()
                }
            }
            .background(Color.black)
            .navigationTitle("MCP Servers")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button {
                            showingAddServer = true
                        } label: {
                            Label("Add Manually", systemImage: "plus")
                        }

                        Button {
                            showingImport = true
                        } label: {
                            Label("Import from JSON", systemImage: "doc.badge.arrow.up")
                        }

                        Divider()

                        Button {
                            exportToJSON()
                        } label: {
                            Label("Export to JSON", systemImage: "square.and.arrow.up")
                        }
                        .disabled(servers.isEmpty)
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddServer) {
                ServerEditView(server: nil)
            }
            .sheet(item: $editingServer) { server in
                ServerEditView(server: server)
            }
            .sheet(isPresented: $showingImport) {
                JSONImportView()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Servers")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add your first MCP server to get started")
                .font(.body)
                .foregroundColor(.secondary)

            Button {
                showingAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    private func deleteServer(_ server: ServerConfig) {
        modelContext.delete(server)
    }

    private func exportToJSON() {
        // 转换为 Claude Code .mcp.json 格式: {"mcpServers": {...}}
        var mcpServers: [String: [String: Any]] = [:]

        for server in servers {
            var config: [String: Any] = [
                "type": server.type.rawValue
            ]

            // 根据类型添加对应字段
            if server.type == .http {
                if let url = server.url {
                    config["url"] = url
                }
                if !server.headers.isEmpty {
                    config["headers"] = server.headers
                }
            } else if server.type == .stdio {
                if let command = server.command {
                    config["command"] = command
                }
                if !server.args.isEmpty {
                    config["args"] = server.args
                }
                if !server.env.isEmpty {
                    config["env"] = server.env
                }
            }

            mcpServers[server.name] = config
        }

        let jsonObject = ["mcpServers": mcpServers]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        // 保存到文件
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ".mcp.json"
        panel.allowedContentTypes = [.json]

        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? jsonString.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Server Card

struct ServerCardView: View {
    @Bindable var server: ServerConfig
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: 名称 + Toggle
            HStack {
                Text(server.name)
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Toggle("", isOn: $server.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            // 描述
            if !server.serverDescription.isEmpty {
                Text(server.serverDescription)
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }

            // URL
            if let url = server.url {
                Label(url, systemImage: "link")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }

            Spacer()

            // 操作按钮
            HStack {
                Spacer()

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(minHeight: 150)
        .background(Color(white: 0.1))
        .cornerRadius(12)
        .opacity(server.isEnabled ? 1.0 : 0.5)
    }
}

// MARK: - Preview

#Preview {
    ServersView()
        .modelContainer(for: ServerConfig.self, inMemory: true)
}
