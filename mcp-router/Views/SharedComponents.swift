//
//  SharedComponents.swift
//  mcp-router
//
//  共享 UI 组件
//

import SwiftUI

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(DesignSystem.Colors.secondaryText)
            Spacer()
            Text(value)
                .font(DesignSystem.Typography.mono)
                .fontWeight(.medium)
        }
    }
}

struct CodeBlockView: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(DesignSystem.Typography.monoSmall)
                .padding(DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.overlay())
                .cornerRadius(DesignSystem.CornerRadius.sm)
        }
    }
}
