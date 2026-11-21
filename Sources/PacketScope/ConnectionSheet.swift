import AppKit
import SwiftUI

enum CopyText {
    static func toPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct ConnectionSheet: View {
    @ObservedObject var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""
    @State private var copiedValue: String?

    private var editable: Bool { !store.isRunning && store.state != .starting }
    private var enteredPort: UInt16? { UInt16(portText).flatMap { $0 > 0 ? $0 : nil } }
    private var portConflictsWithUpstream: Bool {
        store.externalProxy.enabled && enteredPort != nil && enteredPort == store.externalProxy.endpoint?.port
    }
    private var endpoint: String { "http://127.0.0.1:\(store.port)" }
    private var curlCommand: String { "curl -x \(endpoint) http://example.com/" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("代理接入").font(.system(size: 22, weight: .semibold))
                Text("启动代理后，将客户端指向以下本机地址。")
                    .font(.system(size: 12))
                    .foregroundStyle(WorkspaceTheme.muted)
            }
            HStack(spacing: 15) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("地址")
                    Text("127.0.0.1")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(height: 25)
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("端口")
                    TextField("端口", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .frame(width: 76, height: 25)
                        .disabled(!editable)
                        .onSubmit(savePort)
                }
                if editable && portText != String(store.port) {
                    Button("保存端口", action: savePort)
                        .disabled(enteredPort == nil || portConflictsWithUpstream)
                }
                Spacer()
                Button {
                    copy(endpoint)
                } label: {
                    Label(copiedValue == endpoint ? "已复制" : "复制地址",
                          systemImage: copiedValue == endpoint ? "checkmark" : "doc.on.doc")
                }
            }
            .padding(12)
            .background(WorkspaceTheme.sidebar, in: RoundedRectangle(cornerRadius: 9))

            if portConflictsWithUpstream {
                Text("监听端口与已启用的本机 HTTP 上游相同，请选择不同端口。")
                    .font(.caption).foregroundStyle(WorkspaceTheme.warning)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("单个客户端").font(.system(size: 13, weight: .semibold))
                Text("在客户端的 HTTP 代理设置中填写地址和端口，或用终端发出测试请求。")
                    .font(.system(size: 12))
                    .foregroundStyle(WorkspaceTheme.muted)
                HStack(spacing: 10) {
                    Text(curlCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        copy(curlCommand)
                    } label: {
                        Image(systemName: copiedValue == curlCommand ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(copiedValue == curlCommand ? "已复制命令" : "复制命令")
                }
                .padding(9)
                .background(WorkspaceTheme.sidebar, in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("使用 macOS 系统代理").font(.system(size: 13, weight: .semibold))
                Text("在「Mac 抓包」中可查看当前系统代理、接入流迹和恢复原配置。")
                    .font(.system(size: 12))
                    .foregroundStyle(WorkspaceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }

            HStack {
                Button("Mac 抓包…") { store.presentedProxySettings = .system }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 510)
        .foregroundStyle(WorkspaceTheme.ink)
        .background(WorkspaceTheme.canvas)
        .onChange(of: store.port, initial: true) { _, port in
            portText = String(port)
            copiedValue = nil
        }
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(WorkspaceTheme.muted)
    }

    private func savePort() {
        if let enteredPort { store.setPort(enteredPort) }
    }

    private func copy(_ text: String) {
        CopyText.toPasteboard(text)
        copiedValue = text
    }
}
