# MCP Router 设计系统文档

## 概述

本项目采用**轻量级设计系统**,基于 Apple 原生组件进行适当扩展,确保在 Dark/Light/Auto 主题下都有统一的视觉体验。

## 设计原则

1. **拥抱系统默认** - 最大化使用 SwiftUI 原生样式和组件
2. **语义化命名** - 使用语义化的颜色和间距命名,而非具体值
3. **自动适配** - 所有颜色自动适配 Dark/Light 模式
4. **统一规范** - 所有视图共享同一套设计规范

## 主题系统

### 主题模式

```swift
enum AppTheme {
    case auto    // 🔄 跟随系统
    case light   // ☀️ 浅色模式
    case dark    // 🌙 深色模式
}
```

### 使用方式

用户可以在 **设置 → 外观** 中选择主题,设置会自动保存到 SwiftData 并应用到所有窗口。

## 颜色系统

### 层级结构

```
层级 0: windowBackground    // 窗口底色
层级 1: contentBackground   // 主内容区背景
层级 2: cardBackground      // 卡片/容器背景
层级 3: elevatedBackground  // 浮层/菜单背景
```

### 语义化颜色

```swift
// 背景色
DesignSystem.Colors.windowBackground
DesignSystem.Colors.contentBackground
DesignSystem.Colors.cardBackground
DesignSystem.Colors.elevatedBackground

// 文本色
DesignSystem.Colors.primaryText
DesignSystem.Colors.secondaryText

// 强调色
DesignSystem.Colors.accent

// 分割线
DesignSystem.Colors.separator

// 状态色
DesignSystem.Colors.success    // 绿色
DesignSystem.Colors.warning    // 橙色
DesignSystem.Colors.error      // 红色
DesignSystem.Colors.info       // 蓝色

// 半透明覆盖层
DesignSystem.Colors.overlay(opacity: 0.05)
```

### 使用示例

```swift
// ❌ 不推荐 - 硬编码颜色
.background(Color.black)
.foregroundColor(.secondary)

// ✅ 推荐 - 使用设计系统
.background(DesignSystem.Colors.contentBackground)
.foregroundColor(DesignSystem.Colors.secondaryText)
```

## 间距系统

基于 **8pt 网格**系统:

```swift
DesignSystem.Spacing.xs     // 4pt  - 极小间距
DesignSystem.Spacing.sm     // 8pt  - 小间距
DesignSystem.Spacing.md     // 12pt - 中等间距
DesignSystem.Spacing.lg     // 16pt - 大间距
DesignSystem.Spacing.xl     // 24pt - 超大间距
DesignSystem.Spacing.xxl    // 32pt - 特大间距
```

### 使用示例

```swift
// ❌ 不推荐 - 硬编码间距
VStack(spacing: 24) { ... }
.padding(16)

// ✅ 推荐 - 使用设计系统
VStack(spacing: DesignSystem.Spacing.xl) { ... }
.padding(DesignSystem.Spacing.lg)
```

## 圆角系统

```swift
DesignSystem.CornerRadius.sm    // 6pt  - 小圆角(按钮、标签)
DesignSystem.CornerRadius.md    // 8pt  - 中等圆角(输入框)
DesignSystem.CornerRadius.lg    // 12pt - 大圆角(卡片)
DesignSystem.CornerRadius.xl    // 16pt - 超大圆角(面板)
```

## 字体系统

### 系统字体

优先使用 SwiftUI 系统字体,自动适配用户的文本大小偏好:

```swift
DesignSystem.Typography.largeTitle
DesignSystem.Typography.title
DesignSystem.Typography.title2
DesignSystem.Typography.title3
DesignSystem.Typography.headline
DesignSystem.Typography.body
DesignSystem.Typography.callout
DesignSystem.Typography.subheadline
DesignSystem.Typography.footnote
DesignSystem.Typography.caption
DesignSystem.Typography.caption2
```

### 等宽字体

用于代码、Token 等需要等宽展示的内容:

```swift
DesignSystem.Typography.mono        // 标准等宽
DesignSystem.Typography.monoSmall   // 小号等宽
```

## 常用样式

### 卡片样式

```swift
.cardStyle()
// 等同于:
// .padding(DesignSystem.Spacing.lg)
// .background(DesignSystem.Colors.cardBackground)
// .cornerRadius(DesignSystem.CornerRadius.lg)
```

### 容器样式

```swift
.containerStyle()
// 等同于:
// .padding(DesignSystem.Spacing.lg)
// .background(DesignSystem.Colors.overlay())
// .cornerRadius(DesignSystem.CornerRadius.lg)
```

## 组件示例

### 信息行组件

```swift
InfoRow(title: "端口", value: "19104")
```

### 代码块组件

```swift
CodeBlockView(code: "npm install mcp-router")
```

## 迁移指南

### 从硬编码颜色迁移

```swift
// Before
.background(Color.black)
.background(Color(white: 0.05))
.foregroundColor(.gray)
.foregroundColor(.secondary)

// After
.background(DesignSystem.Colors.contentBackground)
.background(DesignSystem.Colors.overlay())
.foregroundColor(DesignSystem.Colors.secondaryText)
.foregroundColor(DesignSystem.Colors.secondaryText)
```

### 从硬编码间距迁移

```swift
// Before
VStack(spacing: 24) { ... }
.padding(16)

// After
VStack(spacing: DesignSystem.Spacing.xl) { ... }
.padding(DesignSystem.Spacing.lg)
```

### 从硬编码字体迁移

```swift
// Before
.font(.headline)
.font(.caption)
.font(.system(.body, design: .monospaced))

// After
.font(DesignSystem.Typography.headline)
.font(DesignSystem.Typography.caption)
.font(DesignSystem.Typography.mono)
```

## 注意事项

1. **不要过度自定义** - 优先使用系统原生组件和样式
2. **保持一致性** - 所有新增视图都应使用设计系统
3. **语义化命名** - 使用 `primaryText` 而非 `grayColor`
4. **自动适配** - 所有颜色都应支持 Dark/Light 自动切换

## 文件位置

- 设计系统定义: `mcp-router/Styles/DesignSystem.swift`
- 主题设置: `mcp-router/Models/AppSettings.swift`
- 主题应用: `mcp-router/mcp_routerApp.swift`
- 主题 UI: `mcp-router/Views/SettingsView.swift`
