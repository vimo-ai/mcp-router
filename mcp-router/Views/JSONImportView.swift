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
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
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

        guard let data = jsonText.data(using: .utf8) else {
            errorMessage = "Invalid text encoding"
            return
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Invalid JSON format"
                return
            }

            var importedCount = 0

            // 格式 1: 我们自己的导出格式 {"servers": [...]}
            if let serversArray = json["servers"] as? [[String: Any]] {
                for serverDict in serversArray {
                    if let server = parseServerDict(serverDict) {
                        modelContext.insert(server)
                        importedCount += 1
                    }
                }
            }
            // 格式 2: Claude Code 的 .mcp.json 格式 {"mcpServers": {...}}
            else if let mcpServers = json["mcpServers"] as? [String: [String: Any]] {
                for (name, config) in mcpServers {
                    if let server = parseMCPServerConfig(name: name, config: config) {
                        modelContext.insert(server)
                        importedCount += 1
                    }
                }
            } else {
                errorMessage = "Unsupported JSON format"
                return
            }

            if importedCount == 0 {
                errorMessage = "No servers found in JSON"
                return
            }

            try modelContext.save()
            dismiss()

        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    // 解析我们自己的格式
    private func parseServerDict(_ dict: [String: Any]) -> ServerConfig? {
        guard let name = dict["name"] as? String,
              let typeString = dict["type"] as? String,
              let type = ServerType(rawValue: typeString) else {
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
    private func parseMCPServerConfig(name: String, config: [String: Any]) -> ServerConfig? {
        guard let typeString = config["type"] as? String else {
            return nil
        }

        let type: ServerType
        let url: String?
        let command: String?
        let args: [String]
        let env: [String: String]
        let headers: [String: String]

        if typeString == "http" {
            type = .http
            url = config["url"] as? String
            command = nil
            args = []
            env = [:]
            headers = config["headers"] as? [String: String] ?? [:]
        } else if typeString == "stdio" {
            type = .stdio
            url = nil
            command = config["command"] as? String
            args = config["args"] as? [String] ?? []
            env = config["env"] as? [String: String] ?? [:]
            headers = [:]
        } else {
            return nil
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
