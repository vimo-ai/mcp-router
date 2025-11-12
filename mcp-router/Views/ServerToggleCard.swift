//
//  ServerToggleCard.swift
//  mcp-router
//
//  Server 卡片组件 - 可 Toggle 开关
//

import SwiftUI

struct ServerToggleCard: View {
    let server: ServerConfig
    let isEnabled: Bool
    let isCustomized: Bool  // 是否被用户修改过
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: 名称 + Toggle
            HStack {
                Text(server.name)
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                ))
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

            // 全局禁用提示
            if !server.isEnabled {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Server Pool 中已禁用")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Spacer()
        }
        .padding(16)
        .frame(minHeight: 120)
        .background(Color(white: 0.1))
        .cornerRadius(12)
        .opacity(isEnabled ? 1.0 : 0.5)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCustomized ? Color.blue : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        // 默认状态（跟随 Default）
        ServerToggleCard(
            server: ServerConfig(
                name: "context7",
                type: .http,
                description: "AI 代码搜索和语义分析",
                url: "https://mcp.context7.com/mcp"
            ),
            isEnabled: true,
            isCustomized: false,
            onToggle: { _ in }
        )

        // 已修改状态（蓝色边框）
        ServerToggleCard(
            server: ServerConfig(
                name: "janghood",
                type: .http,
                description: "Janghood 工具集",
                url: "http://localhost:9509/mcp"
            ),
            isEnabled: false,
            isCustomized: true,
            onToggle: { _ in }
        )
    }
    .padding()
    .background(Color.black)
}
