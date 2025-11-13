//
//  WorkspaceDetailView.swift
//  mcp-router
//
//  Workspace 详情视图
//

import SwiftUI
import SwiftData

struct WorkspaceDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var workspace: Workspace
    @Query private var allServers: [ServerConfig]

    @State private var showingEditSheet = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                // Header
                headerSection

                Divider()

                // Token 信息
                tokenSection

                Divider()

                // Server 配置
                serverSection

                Spacer()
            }
            .padding(DesignSystem.Spacing.xl)
        }
        .background(DesignSystem.Colors.contentBackground)
        .navigationTitle(workspace.name)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        showingEditSheet = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }

                    if !workspace.isDefault {
                        Divider()

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            WorkspaceEditView(workspace: workspace)
        }
        .confirmationDialog(
            "确定删除 Workspace?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                deleteWorkspace()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将会从数据库中删除此 Workspace，并移除项目的 .mcp.json 配置")
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 16) {
            if workspace.isDefault {
                Image(systemName: "star.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.yellow)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name)
                    .font(.title)
                    .fontWeight(.bold)

                if let path = workspace.projectPath {
                    Text(path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Token")
                .font(DesignSystem.Typography.headline)

            HStack {
                Text(workspace.token)
                    .font(DesignSystem.Typography.mono)
                    .padding(DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.overlay())
                    .cornerRadius(DesignSystem.CornerRadius.sm)

                Button {
                    copyToken()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)

                Spacer()
            }

            Text("此 Token 用于 .mcp.json 配置文件中的 X-Workspace-Token Header")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(DesignSystem.Colors.secondaryText)
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Server 配置")
                    .font(.headline)

                Spacer()

                if !workspace.serverOverrides.isEmpty && !workspace.isDefault {
                    Button {
                        workspace.serverOverrides.removeAll()
                        try? modelContext.save()
                    } label: {
                        Label("重置", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Server 卡片列表 - 显示所有 Server
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 16)
            ], spacing: 16) {
                ForEach(allServers) { server in
                    ServerToggleCard(
                        server: server,
                        isEnabled: getEffectiveState(for: server),
                        isCustomized: workspace.isServerCustomized(server.name),
                        onToggle: { isOn in
                            toggleServer(server, isOn: isOn)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Server Logic

    private func getEffectiveState(for server: ServerConfig) -> Bool {
        let defaultWorkspace = try? modelContext.fetch(
            FetchDescriptor<Workspace>(
                predicate: #Predicate { $0.isDefault == true }
            )
        ).first

        return workspace.isServerEnabled(server.name, defaultWorkspace: defaultWorkspace)
    }

    private func toggleServer(_ server: ServerConfig, isOn: Bool) {
        workspace.serverOverrides[server.name] = isOn
        try? modelContext.save()
    }

    // MARK: - Actions

    private func copyToken() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(workspace.token, forType: .string)

        print("✅ Token 已复制到剪贴板")
    }

    private func deleteWorkspace() {
        // 删除 .mcp.json 配置
        if let projectPath = workspace.projectPath,
           let url = URL(string: "file://\(projectPath)") {
            try? MCPConfigManager.removeRouterConfig(at: url)
        }

        modelContext.delete(workspace)
        try? modelContext.save()
    }
}

// MARK: - Preview

#Preview {
    let container = try! ModelContainer(
        for: Workspace.self, ServerConfig.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    let workspace = Workspace(
        token: "abc123ef",
        name: "示例项目",
        projectPath: "/Users/test/project"
    )
    container.mainContext.insert(workspace)

    return NavigationStack {
        WorkspaceDetailView(workspace: workspace)
            .modelContainer(container)
    }
}
