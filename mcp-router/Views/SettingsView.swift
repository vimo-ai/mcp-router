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
    @State private var isInstalledToGlobal = false
    @State private var isCheckingGlobalInstall = true

    private var settings: AppSettings {
        if let existing = settingsArray.first {
            return existing
        }
        return AppSettings.getOrCreate(context: modelContext)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection

                Divider()

                // 服务器设置
                serverSection

                Divider()

                // 更新设置
                updateSection

                Divider()

                // 全局配置
                globalConfigSection

                Spacer()
            }
            .padding(24)
        }
        .background(Color.black)
        .navigationTitle("设置")
        .onAppear {
            portInput = String(settings.serverPort)
            automaticallyChecksForUpdates = appDelegate.updaterController.updater.automaticallyChecksForUpdates

            // 同步预发布版本偏好到 Sparkle
            updatePrereleasePreference(settings.allowPrereleaseUpdates)

            checkGlobalInstallation()
        }
        .alert("提示", isPresented: $showingAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var headerSection: some View {
        HStack(spacing: 16) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            VStack(alignment: .leading, spacing: 4) {
                Text("应用设置")
                    .font(.title)
                    .fontWeight(.bold)

                Text("配置 MCP Router 的运行参数")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HTTP 服务器")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                Text("服务器端口")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
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
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("端口范围: 1024-65535。修改后需要重启服务器。")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            .padding(16)
            .background(Color(white: 0.05))
            .cornerRadius(12)
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自动更新")
                .font(.headline)

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
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color(white: 0.05))
            .cornerRadius(12)
        }
    }

    private var globalConfigSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude 全局配置")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                if isCheckingGlobalInstall {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("检查安装状态...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack(spacing: 12) {
                        if isInstalledToGlobal {
                            Button("打开配置文件") {
                                openClaudeConfig()
                            }
                            .buttonStyle(.borderedProminent)

                            Text("✓ 已安装")
                                .font(.subheadline)
                                .foregroundColor(.green)

                            Button("卸载") {
                                uninstallFromGlobal()
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.orange)
                        } else {
                            Button("安装到全局配置") {
                                installToGlobal()
                            }
                            .buttonStyle(.borderedProminent)

                            Text("未安装")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Text("将 mcp-router 安装到 ~/.claude.json 的根配置，所有 workspace 都可使用。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color(white: 0.05))
            .cornerRadius(12)
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
            alertMessage = "端口已更新为 \(port)。请重启服务器使其生效。"
            showingAlert = true
            print("✅ 端口已更新: \(port)")
        } catch {
            alertMessage = "保存失败: \(error.localizedDescription)"
            showingAlert = true
            print("❌ 保存端口失败: \(error)")
        }
    }

    // MARK: - Global Config Actions

    private func checkGlobalInstallation() {
        isCheckingGlobalInstall = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let installed = try ClaudeConfigManager.isInstalledToGlobal()

                DispatchQueue.main.async {
                    self.isInstalledToGlobal = installed
                    self.isCheckingGlobalInstall = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isInstalledToGlobal = false
                    self.isCheckingGlobalInstall = false
                    print("❌ 检查全局配置失败: \(error)")
                }
            }
        }
    }

    private func installToGlobal() {
        // 生成全局 token（固定的，用于全局配置）
        let globalToken = "global-mcp-router-token"
        let port = settings.serverPort

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ClaudeConfigManager.installToGlobal(token: globalToken, port: port)

                DispatchQueue.main.async {
                    self.isInstalledToGlobal = true
                    self.alertMessage = "✓ 已成功安装到 ~/.claude.json 的全局配置\n\n所有 workspace 现在都可以使用 mcp-router。"
                    self.showingAlert = true
                    print("✅ 已安装到全局配置")
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = "安装失败: \(error.localizedDescription)\n\n请检查 ~/.claude.json 文件权限。"
                    self.showingAlert = true
                    print("❌ 安装到全局配置失败: \(error)")
                }
            }
        }
    }

    private func uninstallFromGlobal() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ClaudeConfigManager.uninstallFromGlobal()

                DispatchQueue.main.async {
                    self.isInstalledToGlobal = false
                    self.alertMessage = "✓ 已从全局配置中卸载"
                    self.showingAlert = true
                    print("✅ 已从全局配置卸载")
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = "卸载失败: \(error.localizedDescription)"
                    self.showingAlert = true
                    print("❌ 卸载失败: \(error)")
                }
            }
        }
    }

    private func openClaudeConfig() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")

        NSWorkspace.shared.open(configPath)
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
