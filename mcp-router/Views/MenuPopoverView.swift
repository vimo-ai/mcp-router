//
//  MenuPopoverView.swift
//  mcp-router
//
//  菜单栏 Popover 内容
//

import SwiftUI

struct MenuPopoverView: View {
    @EnvironmentObject var router: MCPRouter
    @Environment(\.openWindow) private var openWindow

    let serverPort: Int
    let onRestartServer: () -> Void
    let onCheckUpdates: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 状态头部
            headerView

            Divider()

            // 操作按钮
            actionsView

            Divider()

            // 底部
            footerView
        }
        .frame(width: 240)
    }

    // MARK: - 状态头部

    private var headerView: some View {
        HStack {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)

            Text("Running")
                .font(.headline)

            Spacer()

            Text(":\(serverPort)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 操作按钮

    private var actionsView: some View {
        VStack(spacing: 0) {
            // 打开控制台
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack {
                    Image(systemName: "rectangle.3.group")
                    Text("打开控制台")
                    Spacer()
                    Text("⌘D")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 重启服务器
            Button {
                onRestartServer()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("重启服务器")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 复制 URL
            Button {
                copyURL()
            } label: {
                HStack {
                    Image(systemName: "doc.on.doc")
                    Text("复制 URL")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 检查更新
            Button {
                onCheckUpdates()
            } label: {
                HStack {
                    Image(systemName: "arrow.down.circle")
                    Text("检查更新")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 底部

    private var footerView: some View {
        HStack {
            Text("Servers: \(router.serverConfigs.count)")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // 退出按钮
            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("退出 MCP Router")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func copyURL() {
        let url = "http://localhost:\(serverPort)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }
}

#Preview {
    MenuPopoverView(
        serverPort: 19104,
        onRestartServer: {},
        onCheckUpdates: {},
        onQuit: {}
    )
    .environmentObject(MCPRouter.shared)
}
