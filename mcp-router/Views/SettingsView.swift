//
//  SettingsView.swift
//  mcp-router
//
//  应用设置视图
//

import SwiftUI
import SwiftData
import Sparkle

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var appDelegate: AppDelegate
    @Query private var settingsArray: [AppSettings]

    @State private var portInput: String = ""
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var automaticallyChecksForUpdates = false
    @State private var providerStates: [GlobalProviderState] = GlobalConfigProviders.all.map {
        GlobalProviderState(provider: $0)
    }

    private var settings: AppSettings {
        if let existing = settingsArray.first {
            return existing
        }
        return AppSettings.getOrCreate(context: modelContext)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                // Header
                headerSection

                Divider()

                // 服务器设置
                serverSection

                Divider()

                // 外观设置
                appearanceSection

                Divider()

                // 更新设置
                updateSection

                Divider()

                // 全局配置
                globalConfigSection

                Spacer()
            }
            .padding(DesignSystem.Spacing.xl)
        }
        .background(DesignSystem.Colors.contentBackground)
        .navigationTitle("设置")
        .onAppear {
            portInput = String(settings.serverPort)
            automaticallyChecksForUpdates = appDelegate.updaterController.updater.automaticallyChecksForUpdates

            // 同步预发布版本偏好到 Sparkle
            updatePrereleasePreference(settings.allowPrereleaseUpdates)

            checkGlobalInstallations()
        }
        .alert("提示", isPresented: $showingAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var headerSection: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 48))
                .foregroundColor(DesignSystem.Colors.secondaryText)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("应用设置")
                    .font(DesignSystem.Typography.title)
                    .fontWeight(.bold)

                Text("配置 MCP Router 的运行参数")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.secondaryText)
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("外观")
                .font(DesignSystem.Typography.headline)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("主题")
                    .font(DesignSystem.Typography.subheadline)
                    .foregroundColor(DesignSystem.Colors.secondaryText)

                Picker("主题", selection: Binding(
                    get: { settings.appTheme },
                    set: { newTheme in
                        settings.appTheme = newTheme
                        settings.updatedAt = Date()
                        try? modelContext.save()
                        applyTheme(newTheme)
                    }
                )) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Image(systemName: theme.icon)
                            .tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // 显示当前主题文字说明
                Text("当前: \(settings.appTheme.rawValue)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.secondaryText)

                Text("选择应用的显示主题,跟随系统将自动适配明暗模式")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.secondaryText)
            }
            .containerStyle()
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("HTTP 服务器")
                .font(DesignSystem.Typography.headline)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("服务器端口")
                    .font(DesignSystem.Typography.subheadline)
                    .foregroundColor(DesignSystem.Colors.secondaryText)

                HStack(spacing: DesignSystem.Spacing.md) {
                    TextField("端口号", text: $portInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: portInput) { oldValue, newValue in
                            // 只允许输入数字
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered != newValue {
                                portInput = filtered
                            }
                        }

                    Button("应用") {
                        applyPortChange()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(portInput == String(settings.serverPort))

                    Text("当前: \(settings.serverPort)")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.secondaryText)
                }

                Text("端口范围: 1024-65535。修改后需要重启服务器。")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.warning)
            }
            .containerStyle()

            Divider()

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("MCP 工具模式")
                    .font(DesignSystem.Typography.subheadline)
                    .foregroundColor(DesignSystem.Colors.secondaryText)

                Toggle("暴露服务器管理工具 (Full 模式)", isOn: Binding(
                    get: { settings.exposeManagementTools },
                    set: { newValue in
                        settings.exposeManagementTools = newValue
                        settings.updatedAt = Date()
                        try? modelContext.save()
                        // 通知配置变化，触发工具列表更新
                        NotificationCenter.default.post(name: .serverConfigDidChange, object: nil)
                    }
                ))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(settings.exposeManagementTools ? "📝 Full 模式" : "🔒 Light 模式")
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(settings.exposeManagementTools ? .blue : .green)
                    }

                    Text(settings.exposeManagementTools
                         ? "暴露 add_server、remove_server、update_server 工具，允许 AI 动态管理服务器配置"
                         : "仅暴露 list、describe、call 工具，节省 token 并提高安全性（推荐）")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.secondaryText)
                }
            }
            .containerStyle()
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("自动更新")
                .font(DesignSystem.Typography.headline)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("自动检查更新", isOn: $automaticallyChecksForUpdates)
                    .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                        appDelegate.updaterController.updater.automaticallyChecksForUpdates = newValue
                    }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("接收预发布版本（Beta/RC）", isOn: Binding(
                        get: { settings.allowPrereleaseUpdates },
                        set: { newValue in
                            settings.allowPrereleaseUpdates = newValue
                            settings.updatedAt = Date()
                            try? modelContext.save()
                            updatePrereleasePreference(newValue)
                        }
                    ))

                    Text("开启后可以接收 beta、alpha、rc 等测试版本的更新通知")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Divider()

                Button("立即检查更新") {
                    appDelegate.updaterController.updater.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)

                Text("应用会定期检查更新并在后台下载。支持增量更新以节省带宽。")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.secondaryText)
            }
            .containerStyle()
        }
    }

    private var globalConfigSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("客户端全局配置")
                .font(DesignSystem.Typography.headline)

            ForEach(providerStates) { state in
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.provider.displayName)
                                .font(DesignSystem.Typography.subheadline)
                            Text(state.provider.configPath.path)
                                .font(DesignSystem.Typography.caption)
                                .foregroundColor(DesignSystem.Colors.secondaryText)
                        }
                        Spacer()

                        if state.isChecking || state.isProcessing {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(state.isChecking ? "检查安装状态..." : "处理中...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            if state.isInstalled {
                                Button("打开配置文件") {
                                    openConfig(for: state.provider)
                                }
                                .buttonStyle(.borderedProminent)

                                Text("✓ 已安装")
                                    .font(.subheadline)
                                    .foregroundColor(.green)

                                Button("卸载") {
                                    uninstall(provider: state.provider)
                                }
                                .buttonStyle(.bordered)
                                .foregroundColor(.orange)
                            } else {
                                Button("安装到全局配置") {
                                    install(provider: state.provider)
                                }
                                .buttonStyle(.borderedProminent)

                                Text("未安装")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Text(state.provider.descriptionText)
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.secondaryText)
                }
                .containerStyle()
            }
        }
    }

    // MARK: - Actions

    private func applyPortChange() {
        guard let port = Int(portInput) else {
            alertMessage = "请输入有效的端口号"
            showingAlert = true
            return
        }

        guard AppSettings.validatePort(port) else {
            alertMessage = "端口号必须在 1024-65535 之间"
            showingAlert = true
            return
        }

        settings.serverPort = port
        settings.updatedAt = Date()

        do {
            try modelContext.save()
            // 通知配置变化，触发服务器自动重启
            NotificationCenter.default.post(name: .serverConfigDidChange, object: nil)
            alertMessage = "端口已更新为 \(port)，服务器正在重启..."
            showingAlert = true
            print("✅ 端口已更新: \(port)")
        } catch {
            alertMessage = "保存失败: \(error.localizedDescription)"
            showingAlert = true
            print("❌ 保存端口失败: \(error)")
        }
    }

    // MARK: - Global Config Actions

    private func checkGlobalInstallations() {
        let providers = providerStates.map { $0.provider }

        for provider in providers {
            updateProviderState(id: provider.id) { state in
                state.isChecking = true
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let installed = try provider.isInstalled()
                    DispatchQueue.main.async {
                        self.updateProviderState(id: provider.id) { state in
                            state.isInstalled = installed
                            state.isChecking = false
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.updateProviderState(id: provider.id) { state in
                            state.isInstalled = false
                            state.isChecking = false
                        }
                        print("❌ 检查 \(provider.displayName) 全局配置失败: \(error)")
                    }
                }
            }
        }
    }

    private func install(provider: any GlobalConfigProvider) {
        let providerID = provider.id
        let port = settings.serverPort

        updateProviderState(id: providerID) { state in
            state.isProcessing = true
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try provider.install(port: port)
                DispatchQueue.main.async {
                    self.updateProviderState(id: providerID) { state in
                        state.isInstalled = true
                        state.isProcessing = false
                    }
                    self.alertMessage = "✓ 已成功安装到 \(provider.displayName) 的全局配置\n\n所有 workspace 现在都可以使用 mcp-router。"
                    self.showingAlert = true
                    print("✅ 已安装到 \(provider.displayName) 全局配置")
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateProviderState(id: providerID) { state in
                        state.isProcessing = false
                    }
                    self.alertMessage = "安装到 \(provider.displayName) 失败: \(error.localizedDescription)"
                    self.showingAlert = true
                    print("❌ 安装到 \(provider.displayName) 失败: \(error)")
                }
            }
        }
    }

    private func uninstall(provider: any GlobalConfigProvider) {
        let providerID = provider.id

        updateProviderState(id: providerID) { state in
            state.isProcessing = true
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try provider.uninstall()
                DispatchQueue.main.async {
                    self.updateProviderState(id: providerID) { state in
                        state.isInstalled = false
                        state.isProcessing = false
                    }
                    self.alertMessage = "✓ 已从 \(provider.displayName) 全局配置中卸载"
                    self.showingAlert = true
                    print("✅ 已从 \(provider.displayName) 全局配置卸载")
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateProviderState(id: providerID) { state in
                        state.isProcessing = false
                    }
                    self.alertMessage = "卸载 \(provider.displayName) 失败: \(error.localizedDescription)"
                    self.showingAlert = true
                    print("❌ 卸载 \(provider.displayName) 失败: \(error)")
                }
            }
        }
    }

    private func openConfig(for provider: any GlobalConfigProvider) {
        NSWorkspace.shared.open(provider.configPath)
    }

    private func updateProviderState(id: String, mutation: (inout GlobalProviderState) -> Void) {
        if let index = providerStates.firstIndex(where: { $0.id == id }) {
            mutation(&providerStates[index])
        }
    }

    /// 更新 Sparkle 的预发布版本偏好
    private func updatePrereleasePreference(_ allowed: Bool) {
        // Sparkle 2.x+ 支持通过 UserDefaults 控制是否接收预发布版本
        // 键名：SUEnableAutomaticUpdateChecks (legacy) 或使用新的自定义逻辑

        // 简单方案：存储到我们自己的 UserDefaults，在检查更新时读取
        UserDefaults.standard.set(allowed, forKey: "mcp-router.allowPrereleaseUpdates")
        UserDefaults.standard.synchronize()

        print(allowed ? "✅ 已开启预发布版本更新（Beta/RC）" : "📦 已关闭预发布版本更新（仅正式版）")
    }

    /// 应用主题到整个应用
    /// 使用应用级设置而不是窗口级设置，避免焦点切换时主题被重置
    private func applyTheme(_ theme: AppTheme) {
        NSApp.appearance = theme.appearance
        print("🎨 主题已切换为: \(theme.rawValue)")
    }
}

// MARK: - Preview

#Preview {
    let container = try! ModelContainer(
        for: AppSettings.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    let settings = AppSettings()
    container.mainContext.insert(settings)

    return NavigationStack {
        SettingsView()
            .modelContainer(container)
    }
}

// MARK: - Models

private struct GlobalProviderState: Identifiable {
    let provider: any GlobalConfigProvider
    var isChecking: Bool = true
    var isInstalled: Bool = false
    var isProcessing: Bool = false

    var id: String {
        provider.id
    }
}
