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

@main
struct mcp_routerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ServerConfig.self,
            Workspace.self,
            AppSettings.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        // 直接通过静态变量传递
        AppDelegate.sharedModelContainer = sharedModelContainer
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appDelegate)
                .environmentObject(appDelegate.router)
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static var sharedModelContainer: ModelContainer!

    var statusItem: NSStatusItem!
    var httpServer: HTTPServer?
    let router = MCPRouter.shared

    // Sparkle 更新控制器
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // 防抖定时器：避免频繁重启
    private var restartDebounceTimer: Timer?

    // 应用设置
    private var appSettings: AppSettings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0. 初始化应用设置
        initializeAppSettings()

        // 1. 初始化默认 Servers 和 Default Workspace
        initializeDefaultServers()
        initializeDefaultWorkspace()

        // 2. 设置为菜单栏应用（不在 Dock 显示）
        NSApp.setActivationPolicy(.accessory)

        // 3. 创建菜单栏图标
        setupMenuBar()

        // 4. 启动 HTTP Server
        Task {
            await startHTTPServer()
        }

        // 5. 监听 SwiftData 变化
        setupDataChangeObserver()
    }

    // MARK: - Data Change Observer

    private func setupDataChangeObserver() {
        guard let modelContainer = Self.sharedModelContainer else {
            print("⚠️ ModelContainer not available for observer")
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDataChange(_:)),
            name: .NSManagedObjectContextDidSave,
            object: modelContainer.mainContext
        )

        print("✅ 已启用 ServerConfig 变化自动重启")
    }

    @objc private func handleDataChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        // 检查是否有 ServerConfig 变化
        let hasServerConfigChange = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSDeletedObjectsKey
        ].contains { key in
            if let objects = userInfo[key] as? Set<NSManagedObject> {
                return objects.contains { object in
                    String(describing: type(of: object)).contains("ServerConfig")
                }
            }
            return false
        }

        guard hasServerConfigChange else { return }

        print("📡 检测到 ServerConfig 变化，准备重启 Server...")

        // 使用防抖：1秒内的多次变化只触发一次重启
        restartDebounceTimer?.invalidate()
        restartDebounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.autoRestartServer()
        }
    }

    private func autoRestartServer() {
        Task {
            await httpServer?.stop()
            await startHTTPServer()

            await MainActor.run {
                print("🔄 Server 已自动重启")
            }
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "MCP Router")
        }

        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()

        let port = appSettings?.serverPort ?? 19104
        menu.addItem(NSMenuItem(title: "● Running (port \(port))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Restart Server", action: #selector(restartServer), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Copy URL", action: #selector(copyURL), keyEquivalent: "c"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit MCP Router", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Initialization

    func initializeAppSettings() {
        guard let modelContainer = Self.sharedModelContainer else {
            print("⚠️ ModelContainer not available")
            return
        }

        let context = modelContainer.mainContext
        appSettings = AppSettings.getOrCreate(context: context)

        print("✅ 应用设置已加载，端口: \(appSettings?.serverPort ?? 19104)")
    }

    func initializeDefaultServers() {
        // 不再初始化默认 Servers，用户可以通过 UI 手动添加
        print("✅ Server 初始化已跳过，用户可通过 UI 添加")
    }

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
        let configs = loadServerConfigs()
        await router.loadServers(configs)

        let workspaces = loadWorkspaces()
        await router.loadWorkspaces(workspaces)

        // 使用配置的端口
        let port = UInt16(appSettings?.serverPort ?? 19104)
        let server = HTTPServer(port: port, router: router)
        self.httpServer = server

        do {
            try await server.start()
        } catch {
            await MainActor.run {
                print("❌ 启动 HTTP 服务器失败: \(error)")
                showAlert(title: "启动失败", message: "无法启动 HTTP 服务器：\(error.localizedDescription)")
            }
        }
    }

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
            return enabledServers
        } catch {
            print("❌ 加载 Servers 失败: \(error)")
            return []
        }
    }

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

    @objc func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        // 打开主窗口
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // 如果窗口不存在，创建一个新的
            if let url = URL(string: "mcprouter://main") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc func restartServer() {
        Task {
            await httpServer?.stop()
            await startHTTPServer()

            await MainActor.run {
                showAlert(title: "服务已重启", message: "HTTP 服务器已成功重启")
            }
        }
    }

    @objc func copyURL() {
        let port = appSettings?.serverPort ?? 19104
        let url = "http://localhost:\(port)"

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)

        showAlert(title: "已复制", message: "URL 已复制到剪贴板")
    }

    @objc func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }

    @objc func quit() {
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
