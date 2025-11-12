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

                Spacer()
            }
            .padding(24)
        }
        .background(Color.black)
        .navigationTitle("设置")
        .onAppear {
            portInput = String(settings.serverPort)
            automaticallyChecksForUpdates = appDelegate.updaterController.updater.automaticallyChecksForUpdates
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
