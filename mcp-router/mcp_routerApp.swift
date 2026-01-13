//
//  mcp_routerApp.swift
//  mcp-router
//
//  Created by 💻higuaifan on 2025/11/10.
//

import SwiftUI
import SwiftData
import AppKit
import Sparkle
import Combine

// MARK: - Data Migrator

/// 数据迁移器：从 SwiftData 迁移到 JSON 文件
/// 用于支持 MCPRouterKit（通过 FFI）和独立 App 之间的数据共享
struct DataMigrator {
    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vimo")
        .appendingPathComponent("mcp-router")

    static let settingsFile = configDir.appendingPathComponent("settings.json")
    static let workspacesFile = configDir.appendingPathComponent("workspaces.json")
    static let serversFile = configDir.appendingPathComponent("servers.json")

    /// 按文件检查是否需要迁移
    static var needsMigrateSettings: Bool {
        !FileManager.default.fileExists(atPath: settingsFile.path)
    }

    static var needsMigrateWorkspaces: Bool {
        !FileManager.default.fileExists(atPath: workspacesFile.path)
    }

    static var needsMigrateServers: Bool {
        !FileManager.default.fileExists(atPath: serversFile.path)
    }

    /// 执行迁移（按需迁移各个文件）
    @MainActor
    static func migrate(from context: ModelContext) {
        let needsAnyMigration = needsMigrateSettings || needsMigrateWorkspaces || needsMigrateServers

        guard needsAnyMigration else {
            print("✅ 所有配置文件已存在，跳过迁移")
            return
        }

        print("🔄 开始从 SwiftData 迁移数据...")

        do {
            // 确保目录存在
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

            // 按需迁移各个文件
            if needsMigrateSettings {
                migrateSettings(from: context)
            } else {
                print("   ⏭️ settings.json 已存在，跳过")
            }

            if needsMigrateWorkspaces {
                migrateWorkspaces(from: context)
            } else {
                print("   ⏭️ workspaces.json 已存在，跳过")
            }

            if needsMigrateServers {
                migrateServers(from: context)
            } else {
                print("   ⏭️ servers.json 已存在，跳过")
            }

            print("✅ 数据迁移完成")
        } catch {
            print("❌ 数据迁移失败: \(error)")
        }
    }

    @MainActor
    private static func migrateSettings(from context: ModelContext) {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else {
            print("   ⚠️ 未找到 AppSettings，使用默认值")
            return
        }

        // 创建 JSON 格式
        let jsonSettings: [String: Any] = [
            "server_port": settings.serverPort,
            "expose_management_tools": settings.exposeManagementTools
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: jsonSettings, options: .prettyPrinted)
            try data.write(to: settingsFile)
            print("   ✅ Settings 已迁移: port=\(settings.serverPort), fullMode=\(settings.exposeManagementTools)")
        } catch {
            print("   ❌ Settings 迁移失败: \(error)")
        }
    }

    @MainActor
    private static func migrateWorkspaces(from context: ModelContext) {
        let descriptor = FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.createdAt)])
        guard let workspaces = try? context.fetch(descriptor), !workspaces.isEmpty else {
            print("   ⚠️ 未找到 Workspaces，跳过")
            return
        }

        // 转换为 JSON 格式
        var jsonWorkspaces: [[String: Any]] = []
        for ws in workspaces {
            var dict: [String: Any] = [
                "token": ws.token,
                "name": ws.name,
                "is_default": ws.isDefault,
                "server_overrides": ws.serverOverrides,
                "flatten_overrides": ws.flattenOverrides
            ]
            if let projectPath = ws.projectPath {
                dict["project_path"] = projectPath
            }
            jsonWorkspaces.append(dict)
        }

        let jsonRoot: [String: Any] = ["workspaces": jsonWorkspaces]

        do {
            let data = try JSONSerialization.data(withJSONObject: jsonRoot, options: .prettyPrinted)
            try data.write(to: workspacesFile)
            print("   ✅ Workspaces 已迁移: \(workspaces.count) 个")
        } catch {
            print("   ❌ Workspaces 迁移失败: \(error)")
        }
    }

    @MainActor
    private static func migrateServers(from context: ModelContext) {
        let descriptor = FetchDescriptor<ServerConfig>(sortBy: [SortDescriptor(\.name)])
        guard let servers = try? context.fetch(descriptor), !servers.isEmpty else {
            print("   ⚠️ 未找到 Servers，跳过")
            return
        }

        // 转换为 JSON 格式
        var jsonServers: [[String: Any]] = []
        for server in servers {
            var dict: [String: Any] = [
                "name": server.name,
                "type": server.type.rawValue,
                "description": server.serverDescription,
                "is_enabled": server.isEnabled,
                "flatten_mode": server.flattenMode,
                "headers": server.headers,
                "args": server.args,
                "env": server.env,
                "stdio_protocol": server.stdioProtocol.rawValue
            ]
            if let url = server.url {
                dict["url"] = url
            }
            if let command = server.command {
                dict["command"] = command
            }
            jsonServers.append(dict)
        }

        let jsonRoot: [String: Any] = ["servers": jsonServers]

        do {
            let data = try JSONSerialization.data(withJSONObject: jsonRoot, options: .prettyPrinted)
            try data.write(to: serversFile)
            print("   ✅ Servers 已迁移: \(servers.count) 个")
        } catch {
            print("   ❌ Servers 迁移失败: \(error)")
        }
    }
}

@main
struct mcp_routerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ServerConfig.self,
            Workspace.self,
            AppSettings.self,
        ])

        // 指定专属的数据库路径，避免和其他 App 冲突
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let storeURL = appSupportURL.appendingPathComponent("mcp-router.store")

        // 确保目录存在
        try? FileManager.default.createDirectory(
            at: appSupportURL,
            withIntermediateDirectories: true
        )

        // 迁移旧数据：如果新数据库不存在，但旧的 default.store 存在，则复制过来
        let oldStoreURL = appSupportURL.appendingPathComponent("default.store")
        if !FileManager.default.fileExists(atPath: storeURL.path) &&
           FileManager.default.fileExists(atPath: oldStoreURL.path) {
            print("🔄 检测到旧数据库，开始迁移...")
            print("   旧路径: \(oldStoreURL.path)")
            print("   新路径: \(storeURL.path)")

            do {
                // 复制主数据库文件
                try FileManager.default.copyItem(at: oldStoreURL, to: storeURL)
                print("   ✅ 主数据库文件复制成功")

                // 复制 WAL 文件（如果存在）
                let oldWAL = appSupportURL.appendingPathComponent("default.store-wal")
                let newWAL = appSupportURL.appendingPathComponent("mcp-router.store-wal")
                if FileManager.default.fileExists(atPath: oldWAL.path) {
                    try? FileManager.default.copyItem(at: oldWAL, to: newWAL)
                    print("   ✅ WAL 文件复制成功")
                }

                // 复制 SHM 文件（如果存在）
                let oldSHM = appSupportURL.appendingPathComponent("default.store-shm")
                let newSHM = appSupportURL.appendingPathComponent("mcp-router.store-shm")
                if FileManager.default.fileExists(atPath: oldSHM.path) {
                    try? FileManager.default.copyItem(at: oldSHM, to: newSHM)
                    print("   ✅ SHM 文件复制成功")
                }

                print("✅ 数据迁移完成")
            } catch {
                print("❌ 数据迁移失败: \(error.localizedDescription)")
                print("   应用将创建新的空数据库")
                // 不抛出错误，让应用继续运行（会创建新的空数据库）
            }
        }

        let modelConfiguration = ModelConfiguration(
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            print("✅ SwiftData 数据库路径: \(storeURL.path)")
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        // 直接通过静态变量传递
        AppDelegate.sharedModelContainer = sharedModelContainer
    }

    var body: some Scene {
        Window("MCP Router", id: "main") {
            ContentView()
                .environmentObject(appDelegate)
                .environmentObject(appDelegate.router)
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 900, height: 600)
        .defaultLaunchBehavior(.presented)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static var sharedModelContainer: ModelContainer!

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    // 使用 Rust Core 替代 Swift 实现
    let routerCore = MCPRouterCore()
    // 保留 Swift Router 用于 UI 兼容（后续可以逐步迁移）
    let router = MCPRouter.shared
    // 标记是否使用 Rust Core
    private var useRustCore = true

    // Sparkle 更新 delegate
    private lazy var sparkleDelegate = SparkleUpdaterDelegate()

    // Sparkle 更新控制器
    lazy var updaterController: SPUStandardUpdaterController = {
        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: sparkleDelegate,
            userDriverDelegate: nil
        )
    }()

    // 防抖定时器：避免频繁重启
    private var restartDebounceTimer: Timer?

    // 应用设置
    private var appSettings: AppSettings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0. 执行数据迁移（从 SwiftData 到 JSON）
        if let container = Self.sharedModelContainer {
            DataMigrator.migrate(from: container.mainContext)
        }

        // 0.5 初始化应用设置
        initializeAppSettings()

        // 1. 注入 ModelContainer 到 Router（启用动态 Server 管理）
        if let container = Self.sharedModelContainer {
            router.setModelContainer(container)
        }

        // 2. 初始化默认 Servers 和 Default Workspace
        initializeDefaultServers()
        initializeDefaultWorkspace()

        // 2. 设置为菜单栏应用（不在 Dock 显示）
        NSApp.setActivationPolicy(.accessory)

        // 3. 创建菜单栏图标和 Popover
        setupStatusItem()
        setupPopover()

        // 3. 启动 HTTP Server
        Task {
            await startHTTPServer()
        }

        // 4. 监听 SwiftData 变化
        setupDataChangeObserver()
    }

    /// 关闭窗口时不退出应用，保持菜单栏运行
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Data Change Observer

    @MainActor
    private func setupDataChangeObserver() {
        // 监听自定义的 ServerConfig 变化通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleServerConfigChange),
            name: .serverConfigDidChange,
            object: nil
        )

        // 监听 Workspace 变化通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWorkspaceChange),
            name: .workspaceDidChange,
            object: nil
        )

        print("✅ 已启用配置变化自动重启")
    }

    @objc private func handleServerConfigChange() {
        print("📡 检测到 ServerConfig 变化，准备重启 Server...")
        scheduleServerRestart()
    }

    @objc private func handleWorkspaceChange() {
        print("📡 检测到 Workspace 变化，准备重启 Server...")
        scheduleServerRestart()
    }

    private func scheduleServerRestart() {
        // 使用防抖：1秒内的多次变化只触发一次重启
        restartDebounceTimer?.invalidate()
        restartDebounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.autoRestartServer()
        }
    }

    private func autoRestartServer() {
        Task {
            if useRustCore {
                do {
                    try routerCore.stopServer()
                } catch {
                    print("⚠️ 停止服务器时出错: \(error)")
                }
            }

            await startHTTPServer()

            await MainActor.run {
                print("🔄 Server 已自动重启")
            }
        }
    }

    // MARK: - Status Item & Popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "MCP Router")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 240, height: 280)
        popover.behavior = .transient
        popover.animates = true

        let port = appSettings?.serverPort ?? 19104
        let menuView = MenuPopoverView(
            serverPort: port,
            onRestartServer: { [weak self] in
                self?.restartServer()
            },
            onCheckUpdates: { [weak self] in
                self?.checkForUpdates()
            },
            onQuit: { [weak self] in
                self?.quit()
            }
        )
        .environmentObject(router)

        popover.contentViewController = NSHostingController(rootView: menuView)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Initialization

    @MainActor
    func initializeAppSettings() {
        guard let modelContainer = Self.sharedModelContainer else {
            print("⚠️ ModelContainer not available")
            return
        }

        let context = modelContainer.mainContext
        appSettings = AppSettings.getOrCreate(context: context)

        print("✅ 应用设置已加载，端口: \(appSettings?.serverPort ?? 19104)")

        // 应用保存的主题设置
        applyTheme(appSettings?.appTheme ?? .auto)
    }

    /// 应用主题到整个应用
    /// 使用应用级设置而不是窗口级设置，确保主题在窗口焦点切换时保持稳定
    private func applyTheme(_ theme: AppTheme) {
        NSApp.appearance = theme.appearance
        print("🎨 主题已应用: \(theme.rawValue)")
    }

    func initializeDefaultServers() {
        // 不再初始化默认 Servers，用户可以通过 UI 手动添加
        print("✅ Server 初始化已跳过，用户可通过 UI 添加")
    }

    @MainActor
    func initializeDefaultWorkspace() {
        guard let modelContainer = Self.sharedModelContainer else {
            print("⚠️ ModelContainer not available")
            return
        }

        let context = modelContainer.mainContext

        // 检查是否已有 Default Workspace
        let descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.isDefault == true }
        )

        let existingDefault = try? context.fetch(descriptor)
        if let existing = existingDefault, !existing.isEmpty {
            print("✅ 已有 Default Workspace: \(existing[0].name)")
            return
        }

        print("🔧 创建 Default Workspace...")

        // 创建空的 Default Workspace
        let defaultWorkspace = Workspace(
            token: "default",  // 特殊 Token
            name: "Default",
            isDefault: true,
            serverOverrides: [:]  // 初始为空
        )
        context.insert(defaultWorkspace)

        do {
            try context.save()
            print("✅ 成功创建 Default Workspace")
        } catch {
            print("❌ 创建 Default Workspace 失败: \(error)")
        }
    }

    // MARK: - HTTP Server

    private func startHTTPServer() async {
        // 加载 Servers 和 Workspaces
        let configs = await MainActor.run { loadServerConfigs() }
        let workspaces = await MainActor.run { loadWorkspaces() }

        // 使用配置的端口和工具模式
        let port = UInt16(appSettings?.serverPort ?? 19104)
        let exposeManagementTools = appSettings?.exposeManagementTools ?? false

        if useRustCore {
            // 使用 Rust Core
            do {
                try routerCore.loadServers(configs)
                print("✅ [Rust Core] 已加载 \(configs.count) 个 Servers")

                // 加载 Workspaces (转换为 JSON)
                let encoder = JSONEncoder()
                let workspacesData = try encoder.encode(workspaces.map { $0.toRustWorkspace() })
                if let json = String(data: workspacesData, encoding: .utf8) {
                    try routerCore.loadWorkspaces(json: json)
                    print("✅ [Rust Core] 已加载 \(workspaces.count) 个 Workspaces")
                }

                // 设置管理工具模式
                routerCore.exposeManagementTools = exposeManagementTools

                // 启动 HTTP 服务器
                try routerCore.startServer(port: port)
                print("✅ [Rust Core] HTTP 服务器已启动，端口: \(port)")
                print("📦 [Rust Core] 版本: \(routerCore.version)")

            } catch {
                await MainActor.run {
                    print("❌ [Rust Core] 启动失败: \(error)")
                    showAlert(title: "启动失败", message: "无法启动 HTTP 服务器：\(error.localizedDescription)")
                }
            }
        } else {
            // 回退到 Swift 实现
            await router.loadServers(configs)
            router.loadWorkspaces(workspaces)

            let server = HTTPServer(port: port, router: router, exposeManagementTools: exposeManagementTools)

            do {
                try await server.start()
            } catch {
                await MainActor.run {
                    print("❌ 启动 HTTP 服务器失败: \(error)")
                    showAlert(title: "启动失败", message: "无法启动 HTTP 服务器：\(error.localizedDescription)")
                }
            }
        }
    }

    @MainActor
    private func loadServerConfigs() -> [ServerConfig] {
        guard let modelContainer = Self.sharedModelContainer else {
            print("⚠️ ModelContainer not available")
            return []
        }

        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<ServerConfig>(
            predicate: #Predicate { $0.isEnabled == true },
            sortBy: [SortDescriptor(\.name)]
        )

        do {
            let enabledServers = try context.fetch(descriptor)
            print("✅ 从 SwiftData 加载了 \(enabledServers.count) 个已启用的 Servers")

            // 如果没有加载到任何 Server，提示用户可能需要导入配置
            if enabledServers.isEmpty {
                print("⚠️ 未找到任何启用的 Server 配置")
                print("   如果您是从旧版本升级，可能需要：")
                print("   1. 检查数据迁移是否成功（查看上方日志）")
                print("   2. 或通过设置界面的「导入配置」功能恢复数据")
            }

            return enabledServers
        } catch {
            print("❌ 加载 Servers 失败: \(error)")
            return []
        }
    }

    @MainActor
    private func loadWorkspaces() -> [Workspace] {
        guard let modelContainer = Self.sharedModelContainer else {
            print("⚠️ ModelContainer not available")
            return []
        }

        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Workspace>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        do {
            let workspaces = try context.fetch(descriptor)
            print("✅ 从 SwiftData 加载了 \(workspaces.count) 个 Workspaces")
            return workspaces
        } catch {
            print("❌ 加载 Workspaces 失败: \(error)")
            return []
        }
    }

    // MARK: - Menu Actions

    func restartServer() {
        Task {
            if useRustCore {
                do {
                    try routerCore.stopServer()
                } catch {
                    print("⚠️ 停止服务器时出错: \(error)")
                }
            }

            await startHTTPServer()

            await MainActor.run {
                showAlert(title: "服务已重启", message: "HTTP 服务器已成功重启")
            }
        }
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Sparkle Updater Delegate

// MARK: - Notification Names

extension Notification.Name {
    /// ServerConfig 数据变化通知（新增、修改、删除）
    static let serverConfigDidChange = Notification.Name("serverConfigDidChange")

    /// Workspace 数据变化通知（新增、修改、删除）
    static let workspaceDidChange = Notification.Name("workspaceDidChange")
}

class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// 返回允许的更新 channels
    /// 根据用户设置决定是否包含 beta channel
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // 读取用户设置
        let allowPrerelease = UserDefaults.standard.bool(forKey: "mcp-router.allowPrereleaseUpdates")

        if allowPrerelease {
            // 允许 beta channel
            print("🔔 Sparkle: 允许 beta channel 更新")
            return Set(["beta"])
        } else {
            // 只允许默认 channel（稳定版）
            print("🔔 Sparkle: 仅允许稳定版更新")
            return Set()
        }
    }

    /// Sparkle 加载完 appcast 后调用
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        print("📦 Sparkle 成功加载 appcast，共 \(appcast.items.count) 个更新项:")
        for item in appcast.items {
            print("   - \(item.displayVersionString) (channel: \(item.channel ?? "default"))")
        }
    }

    /// Sparkle 找到有效更新时调用
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("✅ Sparkle 找到有效更新: \(item.displayVersionString)")
    }

    /// Sparkle 没有找到更新时调用
    func updater(_ updater: SPUUpdater, didNotFindUpdateWithError error: Error) {
        print("❌ Sparkle 没有找到更新，错误: \(error.localizedDescription)")
    }
}
