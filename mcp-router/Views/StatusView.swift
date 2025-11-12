//
//  StatusView.swift
//  mcp-router
//
//  状态监控页面
//

import SwiftUI

struct StatusView: View {
    @EnvironmentObject var router: MCPRouter

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 服务状态卡片
                    serviceStatusCard

                    // 统计信息
                    statsCard

                    // 使用说明
                    usageCard
                }
                .padding()
            }
            .navigationTitle("Status")
        }
    }

    private var serviceStatusCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 50))
                .foregroundColor(.blue)

            VStack(spacing: 8) {
                HStack {
                    Circle()
                        .fill(router.servers.isEmpty ? Color.red : Color.green)
                        .frame(width: 10, height: 10)

                    Text("HTTP Server")
                        .font(.headline)
                }

                Text("http://localhost:3000")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.headline)

            Divider()

            InfoRow(title: "Total Servers", value: "\(router.serverConfigs.count)")
            InfoRow(title: "Active Servers", value: "\(router.servers.count)")
            InfoRow(title: "Meta Tools", value: "3 (list, describe, call)")
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage")
                .font(.headline)

            Divider()

            Text("Add this configuration to your project's .mcp.json:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            CodeBlockView(code: """
            {
              "mcpServers": {
                "mcp-router": {
                  "type": "http",
                  "url": "http://localhost:3000"
                }
              }
            }
            """)

            Button("Copy Configuration") {
                copyConfiguration()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func copyConfiguration() {
        let config = """
        {
          "mcpServers": {
            "mcp-router": {
              "type": "http",
              "url": "http://localhost:3000"
            }
          }
        }
        """

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(config, forType: .string)
    }
}

#Preview {
    StatusView()
        .environmentObject(MCPRouter.shared)
}
