//
//  ServerEditView.swift
//  mcp-router
//
//  添加/编辑 Server 表单
//

import SwiftUI
import SwiftData

struct ServerEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let server: ServerConfig?  // nil = 添加, 非nil = 编辑

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var serverType: ServerType = .http
    @State private var url: String = ""
    @State private var headers: [HeaderPair] = []
    @State private var isEnabled: Bool = true

    var isEditing: Bool {
        server != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Information") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    TextField("Description", text: $description)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Configuration") {
                    Picker("Type", selection: $serverType) {
                        Text("HTTP").tag(ServerType.http)
                        Text("stdio").tag(ServerType.stdio)
                    }
                    .disabled(serverType == .stdio)  // stdio 暂不支持

                    if serverType == .http {
                        TextField("URL", text: $url)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Headers (Optional)") {
                    ForEach($headers) { $header in
                        HStack {
                            TextField("Key", text: $header.key)
                                .textFieldStyle(.roundedBorder)
                            TextField("Value", text: $header.value)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                removeHeader(header)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button {
                        addHeader()
                    } label: {
                        Label("Add Header", systemImage: "plus.circle")
                    }
                }

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Server" : "Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveServer()
                    }
                    .disabled(!isValidForm)
                }
            }
            .onAppear {
                loadServerData()
            }
        }
    }

    private var isValidForm: Bool {
        if name.isEmpty {
            return false
        }

        // HTTP 类型必须有 URL
        if serverType == .http {
            return !url.isEmpty
        }

        // stdio 类型不需要 URL
        return true
    }

    private func loadServerData() {
        guard let server = server else { return }

        name = server.name
        description = server.serverDescription
        serverType = server.type
        url = server.url ?? ""
        isEnabled = server.isEnabled

        headers = server.headers.map { HeaderPair(key: $0.key, value: $0.value) }
    }

    private func saveServer() {
        let headersDict = Dictionary(uniqueKeysWithValues: headers.map { ($0.key, $0.value) })
            .filter { !$0.key.isEmpty }

        if let existingServer = server {
            // 编辑
            existingServer.name = name
            existingServer.serverDescription = description
            existingServer.type = serverType
            existingServer.url = url
            existingServer.headers = headersDict
            existingServer.isEnabled = isEnabled
        } else {
            // 添加
            let newServer = ServerConfig(
                name: name,
                type: serverType,
                description: description,
                url: url,
                headers: headersDict,
                isEnabled: isEnabled
            )
            modelContext.insert(newServer)
        }

        // 保存到数据库
        try? modelContext.save()

        dismiss()
    }

    private func addHeader() {
        headers.append(HeaderPair(key: "", value: ""))
    }

    private func removeHeader(_ header: HeaderPair) {
        headers.removeAll { $0.id == header.id }
    }
}

// MARK: - Helper Types

struct HeaderPair: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

// MARK: - Preview

#Preview("Add Server") {
    ServerEditView(server: nil)
        .modelContainer(for: ServerConfig.self, inMemory: true)
}

#Preview("Edit Server") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: ServerConfig.self, configurations: config)

    let server = ServerConfig(
        name: "context7",
        type: .http,
        description: "AI 代码搜索",
        url: "https://mcp.context7.com/mcp"
    )
    container.mainContext.insert(server)

    return ServerEditView(server: server)
        .modelContainer(container)
}
