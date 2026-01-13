//
//  ServersView.swift
//  mcp-router
//
//  Server 管理界面 - 卡片式展示
//  数据源: Rust Core (servers.json)
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ServersView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var servers: [ServerItem] = []
    @State private var showingAddServer = false
    @State private var editingServerName: String?
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
                        ForEach($servers) { $server in
                            ServerCardView(server: $server) {
                                editingServerName = server.name
                            } onDelete: {
                                deleteServer(server)
                            }
                        }
                    }
                    .padding()
                }
            }
            .background(DesignSystem.Colors.contentBackground)
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
            .sheet(item: $editingServerName) { name in
                // 从 SwiftData 找到对应的 ServerConfig 用于编辑
                // TODO: 后续改成纯 Rust 编辑
                ServerEditViewWrapper(serverName: name)
            }
            .sheet(isPresented: $showingImport) {
                JSONImportView()
            }
            .onAppear {
                loadServers()
            }
            .onReceive(NotificationCenter.default.publisher(for: .serverConfigDidChange)) { _ in
                loadServers()
            }
        }
    }

    private func loadServers() {
        servers = appDelegate.routerCore.listServers()
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

    private func deleteServer(_ server: ServerItem) {
        do {
            try appDelegate.routerCore.removeServerAndPersist(name: server.name)
            NotificationCenter.default.post(name: .serverConfigDidChange, object: nil)
        } catch {
            // 静默处理删除失败
        }
    }

    private func exportToJSON() {
        // 转换为 Claude Code .mcp.json 格式: {"mcpServers": {...}}
        var mcpServers: [String: [String: Any]] = [:]

        for server in servers {
            var config: [String: Any] = [
                "type": server.type
            ]

            // 根据类型添加对应字段
            if server.type == "http" {
                if let url = server.url {
                    config["url"] = url
                }
                if let headers = server.headers, !headers.isEmpty {
                    config["headers"] = headers
                }
            } else if server.type == "stdio" {
                if let command = server.command {
                    config["command"] = command
                }
                if let args = server.args, !args.isEmpty {
                    config["args"] = args
                }
                if let env = server.env, !env.isEmpty {
                    config["env"] = env
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

// MARK: - Server Edit Wrapper (临时兼容 SwiftData)

struct ServerEditViewWrapper: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allServers: [ServerConfig]
    let serverName: String

    var body: some View {
        if let server = allServers.first(where: { $0.name == serverName }) {
            ServerEditView(server: server)
        } else {
            Text("Server not found")
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Server Card

struct ServerCardView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @Binding var server: ServerItem
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: 名称 + Toggle
            HStack {
                Text(server.name)
                    .font(DesignSystem.Typography.headline)
                    .foregroundColor(DesignSystem.Colors.primaryText)

                Spacer()

                Toggle("", isOn: $server.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: server.isEnabled) { _, newValue in
                        // 通过 Rust FFI 持久化到 servers.json
                        try? appDelegate.routerCore.setServerEnabled(name: server.name, enabled: newValue)
                        NotificationCenter.default.post(name: .serverConfigDidChange, object: nil)
                    }
            }

            // 描述
            if !server.description.isEmpty {
                Text(server.description)
                    .font(DesignSystem.Typography.subheadline)
                    .foregroundColor(DesignSystem.Colors.secondaryText)
            }

            // URL 或 Command
            if let url = server.url {
                Label(url, systemImage: "link")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.secondaryText)
                    .lineLimit(1)
            } else if let command = server.command {
                Label(command, systemImage: "terminal")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.secondaryText)
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
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minHeight: 150)
        .background(DesignSystem.Colors.cardBackground)
        .cornerRadius(DesignSystem.CornerRadius.lg)
        .opacity(server.isEnabled ? 1.0 : 0.5)
    }
}

// MARK: - Preview

#Preview {
    ServersView()
}
