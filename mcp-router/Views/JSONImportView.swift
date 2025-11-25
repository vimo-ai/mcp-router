//
//  JSONImportView.swift
//  mcp-router
//
//  JSON 导入界面
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - 数据模型

/// 导入状态
enum ImportState {
    case editing          // 编辑 JSON
    case duplicateCheck   // 检测到重复，选择策略
    case importing        // 导入中
    case completed        // 完成，显示报告
}

/// 重复处理策略
enum DuplicateStrategy: String, CaseIterable {
    case skip = "跳过重复项"
    case replace = "覆盖已存在的"
    case rename = "重命名导入"

    var description: String {
        switch self {
        case .skip:
            return "保留现有配置，不导入重复的服务器"
        case .replace:
            return "用新配置覆盖已存在的服务器"
        case .rename:
            return "自动重命名（如：context7 → context7-2）"
        }
    }

    var icon: String {
        switch self {
        case .skip: return "arrow.forward.circle"
        case .replace: return "arrow.triangle.2.circlepath"
        case .rename: return "doc.on.doc"
        }
    }
}

/// 导入结果统计
struct ImportResult {
    var added: [String] = []        // 新增的服务器
    var skipped: [String] = []      // 跳过的服务器（重复）
    var replaced: [String] = []     // 覆盖的服务器
    var failed: [(name: String, reason: String)] = []  // 失败的服务器

    var totalProcessed: Int {
        added.count + skipped.count + replaced.count + failed.count
    }

    var successCount: Int {
        added.count + replaced.count
    }
}

struct JSONImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var existingServers: [ServerConfig]

    @State private var jsonText = ""
    @State private var errorMessage: String?
    @State private var importWarnings: [String] = []  // 导入警告信息

    // 新增状态
    @State private var importState: ImportState = .editing
    @State private var duplicateNames: [String] = []
    @State private var selectedStrategy: DuplicateStrategy = .skip
    @State private var importResult = ImportResult()

    var body: some View {
        NavigationStack {
            Group {
                switch importState {
                case .editing:
                    editingView
                case .duplicateCheck:
                    duplicateCheckView
                case .importing:
                    importingView
                case .completed:
                    completedView
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importState == .completed ? "关闭" : "取消") {
                        dismiss()
                    }
                }

                if importState == .editing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入") {
                            startImport()
                        }
                        .disabled(jsonText.isEmpty)
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    private var navigationTitle: String {
        switch importState {
        case .editing:
            return "Import from JSON"
        case .duplicateCheck:
            return "处理重复项"
        case .importing:
            return "导入中..."
        case .completed:
            return "导入完成"
        }
    }

    // MARK: - 编辑视图

    private var editingView: some View {
        VStack(spacing: 16) {
            Text("Paste JSON configuration or drag a file")
                .font(.headline)
                .foregroundColor(.secondary)

            TextEditor(text: $jsonText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 300)
                .border(Color.gray.opacity(0.3))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                    return true
                }

            if let errorMessage = errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.error.opacity(0.1))
                .cornerRadius(DesignSystem.CornerRadius.sm)
            }

            HStack {
                Button("Load from File") {
                    selectFile()
                }

                Spacer()

                Text("Expected format:")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("支持的格式: Claude Code .mcp.json")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                CodeBlockView(code: """
                {
                  "mcpServers": {
                    "chrome-devtools": {
                      "type": "stdio",
                      "command": "npx",
                      "args": ["chrome-devtools-mcp@latest"]
                    },
                    "context7": {
                      "type": "http",
                      "url": "https://mcp.context7.com/mcp"
                    }
                  }
                }
                """)
            }
        }
        .padding()
    }

    // MARK: - 重复检查视图

    private var duplicateCheckView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.orange)

            Text("检测到重复的服务器")
                .font(.title2)
                .fontWeight(.semibold)

            Text("以下服务器已存在：")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(duplicateNames, id: \.self) { name in
                        HStack {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundColor(.orange)
                            Text(name)
                                .font(.body)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(DesignSystem.Colors.warning.opacity(0.1))
                .cornerRadius(DesignSystem.CornerRadius.md)
            }
            .frame(maxHeight: 150)

            Divider()

            Text("如何处理这些重复项？")
                .font(.headline)

            VStack(spacing: 12) {
                ForEach(DuplicateStrategy.allCases, id: \.self) { strategy in
                    Button {
                        selectedStrategy = strategy
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: strategy.icon)
                                .font(.title3)
                                .frame(width: 30)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(strategy.rawValue)
                                    .font(.headline)
                                Text(strategy.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if selectedStrategy == strategy {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding()
                        .background(selectedStrategy == strategy ? Color.blue.opacity(0.1) : Color.clear)
                        .cornerRadius(DesignSystem.CornerRadius.md)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                                .stroke(selectedStrategy == strategy ? Color.blue : DesignSystem.Colors.separator, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            HStack {
                Button("返回编辑") {
                    importState = .editing
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("继续导入") {
                    performImport()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - 导入中视图

    private var importingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("正在导入...")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 完成视图

    private var completedView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)

                Text("导入完成")
                    .font(.title)
                    .fontWeight(.bold)

                // 统计摘要
                HStack(spacing: 40) {
                    VStack {
                        Text("\(importResult.totalProcessed)")
                            .font(.title)
                            .fontWeight(.bold)
                        Text("总计")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack {
                        Text("\(importResult.successCount)")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                        Text("成功")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !importResult.failed.isEmpty {
                        VStack {
                            Text("\(importResult.failed.count)")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.red)
                            Text("失败")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(DesignSystem.Colors.overlay())
                .cornerRadius(DesignSystem.CornerRadius.lg)

                // 详细列表
                VStack(alignment: .leading, spacing: 16) {
                    if !importResult.added.isEmpty {
                        resultSection(
                            title: "✅ 新增：\(importResult.added.count) 个",
                            items: importResult.added,
                            color: .green
                        )
                    }

                    if !importResult.replaced.isEmpty {
                        resultSection(
                            title: "🔄 覆盖：\(importResult.replaced.count) 个",
                            items: importResult.replaced,
                            color: .blue
                        )
                    }

                    if !importResult.skipped.isEmpty {
                        resultSection(
                            title: "⏭️ 跳过：\(importResult.skipped.count) 个",
                            items: importResult.skipped,
                            color: .orange
                        )
                    }

                    if !importResult.failed.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("❌ 失败：\(importResult.failed.count) 个")
                                .font(.headline)
                                .foregroundColor(.red)

                            ForEach(importResult.failed, id: \.name) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("• \(item.name)")
                                        .font(.body)
                                    Text(item.reason)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 12)
                                }
                            }
                        }
                        .padding()
                        .background(DesignSystem.Colors.error.opacity(0.1))
                        .cornerRadius(DesignSystem.CornerRadius.md)
                    }
                }

                Button {
                    dismiss()
                } label: {
                    Text("完成")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
    }

    private func resultSection(title: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(color)

            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .font(.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(DesignSystem.CornerRadius.md)
    }

    // MARK: - 文件操作

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    jsonText = content
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, error in
            if let data = data as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                DispatchQueue.main.async {
                    jsonText = content
                }
            }
        }
    }

    // MARK: - 导入流程

    /// 开始导入流程
    private func startImport() {
        errorMessage = nil

        // 1. 检查文本编码
        guard let data = jsonText.data(using: .utf8) else {
            errorMessage = "文本编码无效，请确保使用 UTF-8 编码"
            return
        }

        do {
            // 2. 解析 JSON
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "JSON 格式无效，根节点必须是对象 {}"
                return
            }

            guard let mcpServers = json["mcpServers"] as? [String: [String: Any]] else {
                errorMessage = """
                不支持的 JSON 格式

                支持的格式：
                {"mcpServers": {...}} - Claude Code .mcp.json 格式

                当前 JSON 的顶层 key: \(json.keys.joined(separator: ", "))
                """
                return
            }

            if mcpServers.isEmpty {
                errorMessage = "mcpServers 对象为空，没有可导入的服务器"
                return
            }

            // 3. 检测重复
            let existingNames = Set(existingServers.map { $0.name })
            let importingNames = Set(mcpServers.keys)
            duplicateNames = Array(importingNames.intersection(existingNames)).sorted()

            // 4. 如果有重复，显示策略选择界面
            if !duplicateNames.isEmpty {
                importState = .duplicateCheck
            } else {
                // 没有重复，直接导入
                performImport()
            }

        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == 3840 {
                let userInfo = error.userInfo
                if let debugDescription = userInfo["NSDebugDescription"] as? String {
                    errorMessage = """
                    JSON 解析失败

                    错误详情: \(debugDescription)
                    """
                } else {
                    errorMessage = "JSON 格式错误，请检查语法是否正确（逗号、引号、括号等）"
                }
            } else {
                errorMessage = "导入失败: \(error.localizedDescription)"
            }
        }
    }

    /// 执行实际的导入操作
    private func performImport() {
        importState = .importing
        importResult = ImportResult()

        // 异步执行导入，避免阻塞 UI
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            do {
                guard let data = jsonText.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let mcpServers = json["mcpServers"] as? [String: [String: Any]] else {
                    return
                }

                let existingServersDict = Dictionary(uniqueKeysWithValues: existingServers.map { ($0.name, $0) })

                for (name, config) in mcpServers {
                    // 检查是否重复
                    let isDuplicate = existingServersDict[name] != nil

                    if isDuplicate {
                        switch selectedStrategy {
                        case .skip:
                            importResult.skipped.append(name)
                            continue

                        case .replace:
                            // 删除旧的
                            if let oldServer = existingServersDict[name] {
                                modelContext.delete(oldServer)
                            }
                            // 继续插入新的
                            if let server = parseMCPServerConfig(name: name, config: config) {
                                modelContext.insert(server)
                                importResult.replaced.append(name)
                            } else {
                                importResult.failed.append((name: name, reason: "配置解析失败"))
                            }

                        case .rename:
                            // 生成新名称
                            var newName = name
                            var suffix = 2
                            while existingServers.contains(where: { $0.name == newName }) {
                                newName = "\(name)-\(suffix)"
                                suffix += 1
                            }

                            if let server = parseMCPServerConfig(name: newName, config: config) {
                                modelContext.insert(server)
                                importResult.added.append(newName)
                            } else {
                                importResult.failed.append((name: name, reason: "配置解析失败"))
                            }
                        }
                    } else {
                        // 不重复，直接添加
                        if let server = parseMCPServerConfig(name: name, config: config) {
                            modelContext.insert(server)
                            importResult.added.append(name)
                        } else {
                            importResult.failed.append((name: name, reason: "配置解析失败"))
                        }
                    }
                }

                // 保存
                try modelContext.save()

                // 通知配置变化
                NotificationCenter.default.post(name: .serverConfigDidChange, object: nil)

                // 切换到完成状态
                importState = .completed

            } catch {
                errorMessage = "导入失败: \(error.localizedDescription)"
                importState = .editing
            }
        }
    }

    // 解析 Claude Code 的 .mcp.json 格式
    private func parseMCPServerConfig(name: String, config: [String: Any], skippedReason: ((String) -> Void)? = nil) -> ServerConfig? {
        // 智能推断类型：优先使用显式的 type 字段，否则根据配置内容推断
        let type: ServerType
        if let typeString = config["type"] as? String {
            if typeString == "http" {
                type = .http
            } else if typeString == "stdio" {
                type = .stdio
            } else {
                skippedReason?("不支持的 type 值 '\(typeString)'，仅支持 'http' 或 'stdio'")
                return nil
            }
        } else if config["command"] != nil {
            // 有 command 字段 → stdio 类型
            type = .stdio
        } else if config["url"] != nil {
            // 有 url 字段 → http 类型
            type = .http
        } else {
            // 既没有 type，也无法推断
            skippedReason?("无法推断服务器类型，请提供 'type' 字段或 'url'/'command' 字段")
            return nil
        }

        let url: String?
        let command: String?
        let args: [String]
        let env: [String: String]
        let headers: [String: String]

        if type == .http {
            url = config["url"] as? String
            if url == nil {
                skippedReason?("HTTP 类型服务器缺少 'url' 字段")
                return nil
            }
            command = nil
            args = []
            env = [:]
            headers = config["headers"] as? [String: String] ?? [:]
        } else {  // .stdio
            url = nil
            command = config["command"] as? String
            if command == nil {
                skippedReason?("stdio 类型服务器缺少 'command' 字段")
                return nil
            }
            args = config["args"] as? [String] ?? []
            env = config["env"] as? [String: String] ?? [:]
            headers = [:]
        }

        return ServerConfig(
            name: name,
            type: type,
            description: "",  // .mcp.json 没有 description 字段
            url: url,
            headers: headers,
            command: command,
            args: args,
            env: env,
            isEnabled: true
        )
    }
}

#Preview {
    JSONImportView()
        .modelContainer(for: ServerConfig.self, inMemory: true)
}
