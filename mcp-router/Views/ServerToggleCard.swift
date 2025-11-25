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
    let isFlattenEnabled: Bool  // 平铺模式是否启用
    let isFlattenCustomized: Bool  // 平铺模式是否被用户修改过
    let onToggle: (Bool) -> Void
    let onFlattenToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: 名称 + Toggle
            HStack {
                Text(server.name)
                    .font(DesignSystem.Typography.headline)
                    .foregroundColor(DesignSystem.Colors.primaryText)

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
                    .font(DesignSystem.Typography.subheadline)
                    .foregroundColor(DesignSystem.Colors.secondaryText)
            }

            // URL
            if let url = server.url {
                Label(url, systemImage: "link")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.secondaryText)
                    .lineLimit(1)
            }

            // 平铺模式控制
            if isEnabled {
                HStack {
                    Label("平铺模式", systemImage: "square.grid.2x2")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.secondaryText)

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { isFlattenEnabled },
                        set: { onFlattenToggle($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(isFlattenCustomized ? DesignSystem.Colors.overlay().opacity(0.3) : DesignSystem.Colors.overlay())
                .cornerRadius(DesignSystem.CornerRadius.sm)
            }

            // 全局禁用提示
            if !server.isEnabled {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(DesignSystem.Colors.warning)
                        .font(DesignSystem.Typography.caption)
                    Text("Server Pool 中已禁用")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.warning)
                }
            }

            Spacer()
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minHeight: 120)
        .background(DesignSystem.Colors.cardBackground)
        .cornerRadius(DesignSystem.CornerRadius.lg)
        .opacity(isEnabled ? 1.0 : 0.5)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
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
            isFlattenEnabled: true,
            isFlattenCustomized: false,
            onToggle: { _ in },
            onFlattenToggle: { _ in }
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
            isFlattenEnabled: false,
            isFlattenCustomized: true,
            onToggle: { _ in },
            onFlattenToggle: { _ in }
        )
    }
    .padding()
    .background(DesignSystem.Colors.contentBackground)
}
