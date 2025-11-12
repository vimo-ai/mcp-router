//
//  ContentView.swift
//  mcp-router
//
//  主视图 - 侧边栏 + 详情区域布局
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selection: AppRoute?

    var body: some View {
        NavigationSplitView {
            // 侧边栏
            SidebarView(selection: $selection)
        } detail: {
            // 主内容区
            if let route = selection {
                detailView(for: route)
            } else {
                emptyDetailView
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    // MARK: - Detail Views

    @ViewBuilder
    private func detailView(for route: AppRoute) -> some View {
        switch route {
        case .workspace(let workspace):
            WorkspaceDetailView(workspace: workspace)

        case .servers:
            ServersView()

        case .settings:
            SettingsView()
        }
    }

    private var emptyDetailView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("从侧边栏选择一个 Workspace")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [ServerConfig.self, Workspace.self], inMemory: true)
}
