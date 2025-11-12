//
//  JSONImportView.swift
//  mcp-router
//
//  JSON 导入界面
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct JSONImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var jsonText = ""
    @State private var errorMessage: String?
    @State private var importWarnings: [String] = []  // 导入警告信息

    var body: some View {
        NavigationStack {
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
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }

                if !importWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("导入警告", systemImage: "exclamationmark.circle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                            .fontWeight(.semibold)

                        ForEach(importWarnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .foregroundColor(.orange)
                                .font(.caption2)
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
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
                    Text("Format 1: Our export format")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    CodeBlockView(code: """
                    {
                      "servers": [
                        {
                          "name": "context7",
                          "type": "http",
                          "url": "https://mcp.context7.com/mcp"
                        }
                      ]
                    }
                    """)

                    Text("Format 2: Claude Code .mcp.json")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)

                    CodeBlockView(code: """
                    {
                      "mcpServers": {
                        "chrome-devtools": {
                          "type": "stdio",
                          "command": "npx",
                          "args": ["chrome-devtools-mcp@latest"]
                        }
                      }
                    }
                    """)
                }
            }
            .padding()
            .navigationTitle("Import from JSON")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importJSON()
                    }
                    .disabled(jsonText.isEmpty)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }

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

    private func importJSON() {
        errorMessage = nil
        importWarnings = []

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

            var importedCount = 0
            var totalCount = 0
            var skippedServers: [(name: String?, reason: String)] = []

            // 格式 1: 我们自己的导出格式 {"servers": [...]}
            if let serversArray = json["servers"] as? [[String: Any]] {
                totalCount = serversArray.count

                if totalCount == 0 {
                    errorMessage = "servers 数组为空，没有可导入的服务器"
                    return
                }

                for (index, serverDict) in serversArray.enumerated() {
                    let serverName = serverDict["name"] as? String ?? "未命名 #\(index + 1)"

                    if let server = parseServerDict(serverDict, skippedReason: { reason in
                        skippedServers.append((name: serverName, reason: reason))
                    }) {
                        modelContext.insert(server)
                        importedCount += 1
                    }
                }
            }
            // 格式 2: Claude Code 的 .mcp.json 格式 {"mcpServers": {...}}
            else if let mcpServers = json["mcpServers"] as? [String: [String: Any]] {
                totalCount = mcpServers.count

                if totalCount == 0 {
                    errorMessage = "mcpServers 对象为空，没有可导入的服务器"
                    return
                }

                for (name, config) in mcpServers {
                    if let server = parseMCPServerConfig(name: name, config: config, skippedReason: { reason in
                        skippedServers.append((name: name, reason: reason))
                    }) {
                        modelContext.insert(server)
                        importedCount += 1
                    }
                }
            } else {
                errorMessage = """
                不支持的 JSON 格式

                支持的格式：
                1. {"servers": [...]} - 我们的导出格式
                2. {"mcpServers": {...}} - Claude Code .mcp.json 格式

                当前 JSON 的顶层 key: \(json.keys.joined(separator: ", "))
                """
                return
            }

            // 3. 生成警告信息
            if !skippedServers.isEmpty {
                for skipped in skippedServers {
                    let serverInfo = skipped.name ?? "未知服务器"
                    importWarnings.append("\(serverInfo): \(skipped.reason)")
                }
            }

            // 4. 检查导入结果
            if importedCount == 0 {
                errorMessage = """
                所有服务器配置都无法导入（共 \(totalCount) 个）

                请检查上方的警告信息了解详情
                """
                return
            }

            // 5. 保存并提示结果
            try modelContext.save()

            if importedCount < totalCount {
                // 部分成功，显示警告后自动关闭
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    dismiss()
                }
            } else {
                // 全部成功，立即关闭
                dismiss()
            }

        } catch let error as NSError {
            // 解析 JSON 错误的详细信息
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

    // 解析我们自己的格式
    private func parseServerDict(_ dict: [String: Any], skippedReason: (String) -> Void) -> ServerConfig? {
        // 检查必需字段: name
        guard let name = dict["name"] as? String else {
            skippedReason("缺少必需字段 'name'")
            return nil
        }

        // 智能推断类型：优先使用显式的 type 字段，否则根据配置内容推断
        let type: ServerType
        if let typeString = dict["type"] as? String {
            if let explicitType = ServerType(rawValue: typeString) {
                type = explicitType
            } else {
                skippedReason("不支持的 type 值 '\(typeString)'，仅支持 'http' 或 'stdio'")
                return nil
            }
        } else if dict["command"] != nil {
            // 有 command 字段 → stdio 类型
            type = .stdio
        } else if dict["url"] != nil {
            // 有 url 字段 → http 类型
            type = .http
        } else {
            // 既没有 type，也无法推断
            skippedReason("无法推断服务器类型，请提供 'type' 字段或 'url'/'command' 字段")
            return nil
        }

        // 类型特定字段验证
        if type == .http && dict["url"] == nil {
            skippedReason("HTTP 类型服务器缺少 'url' 字段")
            return nil
        }

        if type == .stdio && dict["command"] == nil {
            skippedReason("stdio 类型服务器缺少 'command' 字段")
            return nil
        }

        return ServerConfig(
            name: name,
            type: type,
            description: dict["description"] as? String ?? "",
            url: dict["url"] as? String,
            headers: dict["headers"] as? [String: String] ?? [:],
            command: dict["command"] as? String,
            args: dict["args"] as? [String] ?? [],
            env: dict["env"] as? [String: String] ?? [:],
            isEnabled: dict["isEnabled"] as? Bool ?? true
        )
    }

    // 解析 Claude Code 的 .mcp.json 格式
    private func parseMCPServerConfig(name: String, config: [String: Any], skippedReason: (String) -> Void) -> ServerConfig? {
        // 智能推断类型：优先使用显式的 type 字段，否则根据配置内容推断
        let type: ServerType
        if let typeString = config["type"] as? String {
            if typeString == "http" {
                type = .http
            } else if typeString == "stdio" {
                type = .stdio
            } else {
                skippedReason("不支持的 type 值 '\(typeString)'，仅支持 'http' 或 'stdio'")
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
            skippedReason("无法推断服务器类型，请提供 'type' 字段或 'url'/'command' 字段")
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
                skippedReason("HTTP 类型服务器缺少 'url' 字段")
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
                skippedReason("stdio 类型服务器缺少 'command' 字段")
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
