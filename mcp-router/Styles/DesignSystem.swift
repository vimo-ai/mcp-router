//
//  DesignSystem.swift
//  mcp-router
//
//  轻量级设计系统 - 统一颜色、间距、圆角等视觉规范
//

import SwiftUI

// MARK: - 主题模式

enum AppTheme: String, CaseIterable, Codable {
    case auto = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var appearance: NSAppearance? {
        switch self {
        case .auto:
            return nil // 跟随系统
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    var icon: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

// MARK: - 设计系统

struct DesignSystem {

    // MARK: - 颜色系统

    /// 颜色系统 - 基于语义化的视觉层级
    struct Colors {
        /// 层级 0: 窗口背景色
        static let windowBackground = Color(nsColor: .windowBackgroundColor)

        /// 层级 1: 主内容区背景 (TabView, ScrollView 等)
        static let contentBackground = Color(nsColor: .windowBackgroundColor)

        /// 层级 2: 卡片/容器背景 (统一使用半透明浅灰色效果)
        static let cardBackground = overlay()

        /// 层级 3: 浮层背景 (Sheet, Menu 等)
        static let elevatedBackground = Color(nsColor: .controlBackgroundColor)

        /// 主要文本
        static let primaryText = Color.primary

        /// 次要文本
        static let secondaryText = Color.secondary

        /// 强调色 (跟随系统 AccentColor)
        static let accent = Color.accentColor

        /// 分割线
        static let separator = Color(nsColor: .separatorColor)

        /// 状态色
        static let success = Color.green
        static let warning = Color.orange
        static let error = Color.red
        static let info = Color.blue

        /// 半透明覆盖层
        static func overlay(opacity: Double = 0.05) -> Color {
            return Color.primary.opacity(opacity)
        }
    }

    // MARK: - 间距系统

    /// 间距系统 - 基于 8pt 网格
    struct Spacing {
        static let xs: CGFloat = 4      // 极小间距
        static let sm: CGFloat = 8      // 小间距
        static let md: CGFloat = 12     // 中等间距
        static let lg: CGFloat = 16     // 大间距
        static let xl: CGFloat = 24     // 超大间距
        static let xxl: CGFloat = 32    // 特大间距
    }

    // MARK: - 圆角系统

    /// 圆角系统
    struct CornerRadius {
        static let sm: CGFloat = 6      // 小圆角 (按钮、标签)
        static let md: CGFloat = 8      // 中等圆角 (输入框)
        static let lg: CGFloat = 12     // 大圆角 (卡片)
        static let xl: CGFloat = 16     // 超大圆角 (面板)
    }

    // MARK: - 字体系统

    /// 字体系统 (主要使用系统默认)
    struct Typography {
        static let largeTitle = Font.largeTitle
        static let title = Font.title
        static let title2 = Font.title2
        static let title3 = Font.title3
        static let headline = Font.headline
        static let body = Font.body
        static let callout = Font.callout
        static let subheadline = Font.subheadline
        static let footnote = Font.footnote
        static let caption = Font.caption
        static let caption2 = Font.caption2

        /// 等宽字体 (用于代码、Token 等)
        static let mono = Font.system(.body, design: .monospaced)
        static let monoSmall = Font.system(.caption, design: .monospaced)
    }

    // MARK: - 阴影系统

    /// 阴影系统
    struct Shadow {
        static let sm = (radius: CGFloat(2), x: CGFloat(0), y: CGFloat(1))
        static let md = (radius: CGFloat(4), x: CGFloat(0), y: CGFloat(2))
        static let lg = (radius: CGFloat(8), x: CGFloat(0), y: CGFloat(4))
    }
}

// MARK: - View Extensions

extension View {
    /// 应用卡片样式
    func cardStyle() -> some View {
        self
            .padding(DesignSystem.Spacing.lg)
            .applyCardBackground()
    }

    /// 应用容器样式 (与卡片样式相同)
    func containerStyle() -> some View {
        self
            .padding(DesignSystem.Spacing.lg)
            .applyCardBackground()
    }

    /// 应用卡片背景 (macOS 26+ 使用 glass 效果，否则使用传统背景)
    @ViewBuilder
    private func applyCardBackground() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self
                .glassEffect(.clear, in: .rect(cornerRadius: DesignSystem.CornerRadius.lg))
                .background(DesignSystem.Colors.overlay())
        } else {
            self
                .background(DesignSystem.Colors.overlay())
                .cornerRadius(DesignSystem.CornerRadius.lg)
        }
    }

    /// 应用分组样式
    func sectionStyle() -> some View {
        self
            .padding(DesignSystem.Spacing.xl)
    }
}
