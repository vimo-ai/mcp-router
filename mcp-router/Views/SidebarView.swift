//
//  SidebarView.swift
//  mcp-router
//
//  侧边栏 - Workspace 列表
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workspace.createdAt) private var workspaces: [Workspace]
    @Query private var appSettings: [AppSettings]

    @Binding var selection: AppRoute?
    @State private var showingAddWorkspace = false
    @State private var isDragging = false

    // 获取当前端口
    private var serverPort: Int {
        appSettings.first?.serverPort ?? 19104
    }

    var body: some View {
        List(selection: $selection) {
            Section("Workspaces") {
                ForEach(workspaces) { workspace in
                    NavigationLink(value: AppRoute.workspace(workspace)) {
                        WorkspaceRowView(workspace: workspace)
                    }
                }
            }

            Section("管理") {
                NavigationLink(value: AppRoute.servers) {
                    Label("Server Pool", systemImage: "server.rack")
                }

                NavigationLink(value: AppRoute.settings) {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("MCP Router")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showingAddWorkspace = true
                } label: {
                    Label("新建 Workspace", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddWorkspace) {
            WorkspaceEditView(workspace: nil)
        }
        .overlay {
            if isDragging {
                dragOverlay
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Drag Overlay

    private var dragOverlay: some View {
        ZStack {
            Color.blue.opacity(0.1)

            VStack(spacing: 16) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)

                Text("拖入项目文件夹")
                    .font(.headline)
                    .foregroundColor(.blue)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Drop Handler

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            // 确保是文件夹
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }

            DispatchQueue.main.async {
                createWorkspaceFromFolder(url: url)
            }
        }

        return true
    }

    private func createWorkspaceFromFolder(url: URL) {
        // 检查是否已有此路径的 Workspace
        if workspaces.contains(where: { $0.projectPath == url.path }) {
            print("⚠️ 此项目已存在 Workspace")
            return
        }

        do {
            // 检查是否已有 mcp-router 配置
            let (exists, existingToken) = try MCPConfigManager.hasRouterConfig(at: url)

            if exists, let token = existingToken {
                // 导入现有配置
                importExistingWorkspace(projectPath: url, token: token)
            } else {
                // 创建新 Workspace
                createNewWorkspace(projectPath: url)
            }
        } catch {
            print("❌ 处理项目文件夹失败: \(error)")
        }
    }

    private func importExistingWorkspace(projectPath: URL, token: String) {
        // 检查 Token 是否已存在
        if workspaces.contains(where: { $0.token == token }) {
            print("⚠️ Token 冲突")
            return
        }

        let projectName = projectPath.lastPathComponent
        let workspace = Workspace(
            token: token,
            name: projectName,
            projectPath: projectPath.path
        )

        modelContext.insert(workspace)
        try? modelContext.save()

        print("✅ 导入现有 Workspace: \(projectName) (Token: \(token))")

        // 自动选中新创建的 Workspace
        selection = .workspace(workspace)
    }

    private func createNewWorkspace(projectPath: URL) {
        let token = Workspace.generateToken()
        let projectName = projectPath.lastPathComponent

        // 写入 .mcp.json
        do {
            try MCPConfigManager.mergeRouterConfig(at: projectPath, token: token, port: serverPort)

            let workspace = Workspace(
                token: token,
                name: projectName,
                projectPath: projectPath.path
            )

            modelContext.insert(workspace)
            try? modelContext.save()

            print("✅ 创建新 Workspace: \(projectName) (Token: \(token))")

            // 自动选中新创建的 Workspace
            selection = .workspace(workspace)
        } catch {
            print("❌ 创建 Workspace 失败: \(error)")
        }
    }
}

// MARK: - Workspace Row

struct WorkspaceRowView: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            if workspace.isDefault {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
            } else {
                Image(systemName: "folder.fill")
                    .foregroundColor(.blue)
                    .font(.caption)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.body)

                Text(workspace.token)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationSplitView {
        SidebarView(selection: .constant(nil))
            .modelContainer(for: [Workspace.self, ServerConfig.self], inMemory: true)
    } detail: {
        Text("选择一个 Workspace")
    }
}
