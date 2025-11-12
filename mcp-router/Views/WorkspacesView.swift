//
//  WorkspacesView.swift
//  mcp-router
//
//  Workspace 管理界面 - 支持拖放文件夹
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct WorkspacesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var workspaces: [Workspace]
    @Query private var servers: [ServerConfig]

    @State private var showingAddWorkspace = false
    @State private var editingWorkspace: Workspace?
    @State private var isDragging = false

    var body: some View {
        NavigationStack {
            ZStack {
                if workspaces.isEmpty {
                    emptyState
                } else {
                    workspaceList
                }

                // 拖放提示层
                if isDragging {
                    dragOverlay
                }
            }
            .background(Color.black)
            .navigationTitle("Workspaces")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingAddWorkspace = true
                    } label: {
                        Label("Add Workspace", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddWorkspace) {
                WorkspaceEditView(workspace: nil)
            }
            .sheet(item: $editingWorkspace) { workspace in
                WorkspaceEditView(workspace: workspace)
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                handleDrop(providers: providers)
            }
        }
    }

    // MARK: - Views

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Workspaces")
                .font(.title2)
                .fontWeight(.semibold)

            Text("拖入项目文件夹或手动创建 Workspace")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showingAddWorkspace = true
            } label: {
                Label("Create Workspace", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    private var workspaceList: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 16)
            ], spacing: 16) {
                ForEach(workspaces) { workspace in
                    WorkspaceCardView(workspace: workspace) {
                        editingWorkspace = workspace
                    } onDelete: {
                        deleteWorkspace(workspace)
                    }
                }
            }
            .padding()
        }
    }

    private var dragOverlay: some View {
        ZStack {
            Color.blue.opacity(0.1)

            VStack(spacing: 16) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                Text("拖入项目文件夹以创建 Workspace")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Actions

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
    }

    private func createNewWorkspace(projectPath: URL) {
        let token = Workspace.generateToken()
        let projectName = projectPath.lastPathComponent

        // 写入 .mcp.json
        do {
            try MCPConfigManager.mergeRouterConfig(at: projectPath, token: token)

            let workspace = Workspace(
                token: token,
                name: projectName,
                projectPath: projectPath.path
            )

            modelContext.insert(workspace)
            try? modelContext.save()

            print("✅ 创建新 Workspace: \(projectName) (Token: \(token))")

            // 打开编辑界面
            editingWorkspace = workspace
        } catch {
            print("❌ 创建 Workspace 失败: \(error)")
        }
    }

    private func deleteWorkspace(_ workspace: Workspace) {
        // 不能删除默认 Workspace
        guard !workspace.isDefault else {
            print("⚠️ 不能删除默认 Workspace")
            return
        }

        // 可选:删除 .mcp.json 中的配置
        if let projectPath = workspace.projectPath,
           let url = URL(string: "file://\(projectPath)") {
            try? MCPConfigManager.removeRouterConfig(at: url)
        }

        modelContext.delete(workspace)
    }
}

// MARK: - Workspace Card

struct WorkspaceCardView: View {
    @Bindable var workspace: Workspace
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                if workspace.isDefault {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                }

                Text(workspace.name)
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()
            }

            // Token
            HStack {
                Text("Token:")
                    .font(.caption)
                    .foregroundColor(.gray)

                Text(workspace.token)
                    .font(.caption.monospaced())
                    .foregroundColor(.blue)

                Button {
                    copyToken()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            // 项目路径
            if let path = workspace.projectPath {
                Label(path, systemImage: "folder")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }

            // Servers
            HStack {
                let customizedCount = workspace.serverOverrides.count
                if customizedCount > 0 {
                    Text("\(customizedCount) 项自定义")
                        .font(.caption)
                        .foregroundColor(.blue)
                } else {
                    Text("跟随默认")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            // 操作按钮
            if !workspace.isDefault {
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
        }
        .padding(16)
        .frame(minHeight: 150)
        .background(workspace.isDefault ? Color.blue.opacity(0.1) : Color(white: 0.1))
        .cornerRadius(12)
    }

    private func copyToken() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(workspace.token, forType: .string)
    }
}

// MARK: - Preview

#Preview {
    WorkspacesView()
        .modelContainer(for: [Workspace.self, ServerConfig.self], inMemory: true)
}
