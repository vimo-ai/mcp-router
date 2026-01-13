//
//  ProcessManager.swift
//  mcp-router
//
//  stdio MCP Server 进程管理器
//

import Foundation

actor ProcessManager {
    let config: ServerConfig
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var isRunning = false

    /// 使用的协议类型
    var stdioProtocol: StdioProtocol {
        config.stdioProtocol
    }

    init(config: ServerConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    /// 启动进程
    func start() throws {
        guard !isRunning else {
            print("⚠️ 进程已在运行: \(config.name)")
            return
        }

        let process = Process()

        // 解析命令
        // config.command = "npx"
        // config.args = ["-y", "chrome-devtools-mcp@latest"]
        guard let command = config.command else {
            throw MCPError.invalidURL // TODO: 更合适的错误类型
        }

        // 特殊处理: npx 需要通过 node 运行
        let executablePath: String
        var arguments: [String]

        if command == "npx" {
            // 查找 node
            guard let nodePath = findCommandInPath("node") else {
                print("❌ 找不到 node 解释器")
                throw MCPError.invalidURL
            }

            // 查找 npx
            guard let npxPath = findCommandInPath("npx") else {
                print("❌ 找不到命令: npx")
                throw MCPError.invalidURL
            }

            executablePath = nodePath
            arguments = [npxPath] + config.args

            print("🔍 使用 node 运行 npx:")
            print("   node: \(nodePath)")
            print("   npx: \(npxPath)")
            print("   参数: \(config.args.joined(separator: " "))")
        } else {
            // 其他命令直接执行
            guard let commandPath = findCommandInPath(command) else {
                print("❌ 找不到命令: \(command)")
                throw MCPError.invalidURL
            }

            executablePath = commandPath
            arguments = config.args

            print("🔍 使用可执行文件: \(executablePath)")
            print("   参数: \(config.args.joined(separator: " "))")
        }

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        // 设置环境变量
        var environment = ProcessInfo.processInfo.environment

        // 获取用户 shell 的完整环境变量
        // macOS 应用默认的 PATH 很有限,需要从 shell 加载
        if let shellPath = getShellEnvironmentPath() {
            environment["PATH"] = shellPath
        } else {
            // 回退方案:添加常用路径
            let currentPath = environment["PATH"] ?? ""
            let additionalPaths = [
                "/usr/local/bin",
                "/opt/homebrew/bin",
                "/opt/homebrew/sbin",
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
            ]
            let newPath = (additionalPaths + currentPath.split(separator: ":").map(String.init))
                .joined(separator: ":")
            environment["PATH"] = newPath
        }

        // 应用用户自定义环境变量
        for (key, value) in config.env {
            environment[key] = value
        }
        process.environment = environment

        // 设置管道
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.process = process

        // 监听进程退出
        process.terminationHandler = { [weak self] proc in
            Task { await self?.handleTermination(exitCode: proc.terminationStatus) }
        }

        do {
            try process.run()
            isRunning = true

            print("✅ 启动 stdio 进程: \(config.name) (PID: \(process.processIdentifier))")
            print("   命令: \(executablePath) \(config.args.joined(separator: " "))")
            print("   PATH: \(environment["PATH"]?.split(separator: ":").prefix(3).joined(separator: ", ") ?? "未设置")...")
            print("   进程状态: isRunning=\(process.isRunning)")
        } catch {
            print("❌ 启动进程失败: \(error)")
            throw error
        }
    }

    /// 停止进程
    func stop() async {
        guard isRunning, let process = process else {
            print("⚠️ 进程未运行: \(config.name)")
            return
        }

        // 1. 发送 graceful shutdown 请求
        do {
            let shutdownRequest = """
            {"jsonrpc":"2.0","method":"shutdown","id":9999}

            """
            try await write(shutdownRequest)

            // 等待 2 秒
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
            print("⚠️ Shutdown 请求失败: \(error)")
        }

        // 2. 终止进程
        if process.isRunning {
            process.terminate()
            print("🛑 终止进程: \(config.name)")
        }

        isRunning = false
    }

    /// 重启进程
    func restart() async throws {
        await stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try start()
    }

    /// 检查进程是否存活
    func isAlive() -> Bool {
        return isRunning && (process?.isRunning ?? false)
    }

    // MARK: - I/O Operations

    /// 写入 stdin（根据协议类型选择格式）
    func write(_ data: String) async throws {
        guard let inputPipe = inputPipe else {
            throw MCPError.processNotRunning
        }

        let trimmedData = data.trimmingCharacters(in: .whitespacesAndNewlines)
        let formattedData: String

        switch stdioProtocol {
        case .line:
            // 按行分隔：JSON + \n
            formattedData = trimmedData + "\n"
        case .contentLength:
            // Content-Length header 格式
            let contentBytes = trimmedData.utf8.count
            formattedData = "Content-Length: \(contentBytes)\r\n\r\n\(trimmedData)"
        }

        guard let utf8Data = formattedData.data(using: .utf8) else {
            throw MCPError.encodingError
        }

        try inputPipe.fileHandleForWriting.write(contentsOf: utf8Data)
    }

    /// 读取 stdout 消息（根据协议类型选择格式）
    func readMessage() async throws -> String? {
        print("📖 readMessage() 使用协议: \(stdioProtocol)")
        switch stdioProtocol {
        case .line:
            return try await readLineMessage()
        case .contentLength:
            return try await readContentLengthMessage()
        }
    }

    /// 按行读取一条消息（JSON\n 格式）
    private func readLineMessage() async throws -> String? {
        guard let outputPipe = outputPipe else {
            throw MCPError.processNotRunning
        }

        let handle = outputPipe.fileHandleForReading
        var buffer = Data()

        for try await byte in handle.bytes {
            if byte == UInt8(ascii: "\n") {
                if let line = String(data: buffer, encoding: .utf8) {
                    return line
                }
                buffer.removeAll()
            } else {
                buffer.append(byte)
            }
        }

        return nil
    }

    /// 读取 Content-Length 格式的消息（使用 AsyncBytes 逐字节读取）
    private func readContentLengthMessage() async throws -> String? {
        guard let outputPipe = outputPipe else {
            throw MCPError.processNotRunning
        }

        let handle = outputPipe.fileHandleForReading

        // 1. 逐字节读取 header 直到 \r\n\r\n
        var headerBuffer = Data()
        let headerEndSequence: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        var matchIndex = 0

        for try await byte in handle.bytes {
            headerBuffer.append(byte)

            // 匹配 \r\n\r\n 序列
            if byte == headerEndSequence[matchIndex] {
                matchIndex += 1
                if matchIndex == headerEndSequence.count {
                    // 找到 header 结束
                    break
                }
            } else {
                matchIndex = (byte == headerEndSequence[0]) ? 1 : 0
            }
        }

        // 2. 解析 Content-Length
        // 移除尾部的 \r\n\r\n
        let headerData = headerBuffer.dropLast(4)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            print("⚠️ Content-Length 协议: header 解析失败")
            return nil
        }

        // 匹配 Content-Length: N
        guard let match = headerString.range(of: #"Content-Length:\s*(\d+)"#, options: .regularExpression),
              let lengthString = headerString[match].split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
              let contentLength = Int(lengthString) else {
            print("⚠️ Content-Length 协议: 未找到有效的 Content-Length header")
            print("   收到的 header: \(headerString.prefix(100))")
            return nil
        }

        // 3. 读取指定长度的内容
        var contentBuffer = Data()
        contentBuffer.reserveCapacity(contentLength)

        var bytesRead = 0
        for try await byte in handle.bytes {
            contentBuffer.append(byte)
            bytesRead += 1
            if bytesRead >= contentLength {
                break
            }
        }

        guard let content = String(data: contentBuffer, encoding: .utf8) else {
            print("⚠️ Content-Length 协议: 内容解析失败")
            return nil
        }

        return content
    }

    /// 兼容旧 API：按行读取（不推荐，使用 readMessage() 代替）
    @available(*, deprecated, renamed: "readMessage", message: "Use readMessage() instead for protocol-aware reading")
    func readLine() async throws -> String? {
        return try await readLineMessage()
    }

    /// 读取 stderr (非阻塞)
    func readError() -> String? {
        guard let errorPipe = errorPipe else { return nil }

        let data = errorPipe.fileHandleForReading.availableData
        return data.isEmpty ? nil : String(data: data, encoding: .utf8)
    }

    // MARK: - Private

    private func handleTermination(exitCode: Int32) {
        isRunning = false

        // 读取 stderr 错误信息
        if let errorOutput = readError(), !errorOutput.isEmpty {
            print("⚠️ 进程退出: \(config.name) (exit code: \(exitCode))")
            print("   stderr: \(errorOutput)")
        } else {
            print("⚠️ 进程退出: \(config.name) (exit code: \(exitCode))")
        }

        if exitCode != 0 {
            print("❌ 进程异常退出,可能需要重启")
        }
    }

    /// 在 PATH 中查找命令的完整路径
    private func findCommandInPath(_ command: String) -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        // 基础搜索路径(作为后备)
        let searchPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(homeDir)/.local/bin",
            "/usr/bin",
            "/bin",
        ]

        // 也从动态构建的 PATH 中搜索
        if let fullPath = getShellEnvironmentPath() {
            let allPaths = fullPath.split(separator: ":").map(String.init) + searchPaths
            for path in allPaths {
                let fullCommandPath = "\(path)/\(command)"
                // 检查文件是否存在(支持符号链接)
                if FileManager.default.fileExists(atPath: fullCommandPath) {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: fullCommandPath, isDirectory: &isDirectory),
                       !isDirectory.boolValue {
                        // 解析符号链接到真实路径
                        let url = URL(fileURLWithPath: fullCommandPath)
                        if let resolvedPath = try? url.resolvingSymlinksInPath().path {
                            print("🔗 解析符号链接: \(fullCommandPath) -> \(resolvedPath)")
                            return resolvedPath
                        } else {
                            // 如果解析失败,返回原路径
                            print("⚠️ 符号链接解析失败,使用原路径: \(fullCommandPath)")
                            return fullCommandPath
                        }
                    }
                }
            }
        }

        return nil
    }

    /// 构建完整的 PATH 环境变量
    private func getShellEnvironmentPath() -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []

        // 1. Homebrew
        paths.append(contentsOf: [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ])

        // 2. NVM - 动态查找所有 Node 版本
        let nvmDir = "\(homeDir)/.nvm/versions/node"
        if let nodeVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for version in nodeVersions.sorted().reversed() { // 优先使用最新版本
                let binPath = "\(nvmDir)/\(version)/bin"
                paths.append(binPath)
            }
        }

        // 3. 其他 Node.js 工具
        paths.append(contentsOf: [
            "\(homeDir)/.npm-global/bin",
            "\(homeDir)/.yarn/bin",
            "\(homeDir)/.config/yarn/global/node_modules/.bin",
            "\(homeDir)/Library/pnpm",
        ])

        // 4. 用户本地工具
        paths.append(contentsOf: [
            "\(homeDir)/.local/bin",
            "\(homeDir)/.cargo/bin",
            "\(homeDir)/.deno/bin",
            "\(homeDir)/.bun/bin",
            "\(homeDir)/.rbenv/shims",
        ])

        // 5. 系统路径
        paths.append(contentsOf: [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ])

        // 过滤出实际存在的路径
        let existingPaths = paths.filter { path in
            FileManager.default.fileExists(atPath: path)
        }

        if !existingPaths.isEmpty {
            let fullPath = existingPaths.joined(separator: ":")
            print("✅ 构建 PATH (\(fullPath.count) 字符, \(existingPaths.count) 个路径)")
            print("   前5个路径: \(existingPaths.prefix(5).joined(separator: ", "))")

            // 验证 npx 是否存在
            if let npxPath = existingPaths.first(where: { FileManager.default.fileExists(atPath: "\($0)/npx") }) {
                print("   ✅ 找到 npx: \(npxPath)/npx")
            } else {
                print("   ⚠️ 警告: 在 PATH 中未找到 npx")
            }

            return fullPath
        }

        print("⚠️ 无法构建有效的 PATH")
        return nil
    }
}
