//
//  WorkspaceEditView.swift
//  mcp-router
//
//  Workspace 编辑界面 - 仅编辑基本信息
//

import SwiftUI
import SwiftData

struct WorkspaceEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var appSettings: [AppSettings]

    let workspace: Workspace?

    @State private var name: String
    @State private var token: String
    @State private var projectPath: String

    // 获取当前端口
    private var serverPort: Int {
        appSettings.first?.serverPort ?? 19104
    }

    init(workspace: Workspace?) {
        self.workspace = workspace

        _name = State(initialValue: workspace?.name ?? "")
        _token = State(initialValue: workspace?.token ?? Workspace.generateToken())
        _projectPath = State(initialValue: workspace?.projectPath ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("Workspace 名称", text: $name)

                    HStack {
                        TextField("Token", text: $token)
                            .font(.system(.body, design: .monospaced))
                            .disabled(workspace != nil)  // 已存在的不能修改 Token

                        Button {
                            copyToken()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }

                    if !projectPath.isEmpty {
                        TextField("项目路径", text: $projectPath)
                            .disabled(true)
                    }
                }

                Section("配置预览") {
                    Text(MCPConfigManager.generateConfigPreview(token: token, port: serverPort))
                        .font(DesignSystem.Typography.monoSmall)
                        .textSelection(.enabled)
                        .padding(DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.overlay())
                        .cornerRadius(DesignSystem.CornerRadius.md)
                }
            }
            .navigationTitle(workspace == nil ? "新建 Workspace" : "编辑 Workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveWorkspace()
                    }
                    .disabled(name.isEmpty || token.isEmpty)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Actions

    private func saveWorkspace() {
        do {
            if let existing = workspace {
                // 更新现有 Workspace
                existing.name = name
                try modelContext.save()
            } else {
                // 创建新 Workspace
                _ = try Workspace.validateTokenUnique(token, context: modelContext)

                let newWorkspace = Workspace(
                    token: token,
                    name: name,
                    projectPath: projectPath.isEmpty ? nil : projectPath
                )

                modelContext.insert(newWorkspace)
                try modelContext.save()
            }

            // 通知配置变化
            NotificationCenter.default.post(name: .workspaceDidChange, object: nil)

            dismiss()
        } catch {
            print("❌ 保存 Workspace 失败: \(error)")
        }
    }

    private func copyToken() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
    }
}

// MARK: - Preview

#Preview {
    WorkspaceEditView(workspace: nil)
        .modelContainer(for: [Workspace.self, ServerConfig.self], inMemory: true)
}
