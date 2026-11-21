import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HTTPSContextActions: View {
    let url: String
    @ObservedObject var settings: OwnedHTTPSSettings
    let open: () -> Void

    @ViewBuilder var body: some View {
        if let parts = URLComponents(string: url), parts.scheme?.lowercased() == "https",
           let host = parts.host, let port = UInt16(exactly: parts.port ?? 443) {
            if let route = settings.routes.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame && $0.port == port }) {
                Text(settings.enabled ? "HTTPS 调试已启用" : "HTTPS 调试已暂停")
                if !settings.enabled {
                    Button("恢复 HTTPS 调试") { settings.setEnabled(true) }
                }
                Button("关闭此服务的 HTTPS 调试") { settings.remove(id: route.id) }
            } else {
                Text("HTTPS 调试未启用")
                Button("启用此服务的 HTTPS 调试…", action: open)
            }
        }
    }
}

struct OwnedHTTPSSettingsSheet: View {
    @ObservedObject var settings: OwnedHTTPSSettings
    let initialHost: String?
    let initialPort: UInt16
    @State private var host = ""
    @State private var portText = "443"
    @State private var file: URL?
    @State private var password = ""
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自有服务 HTTPS 调试").font(.title2.bold())
            Text("为主机和端口选择该服务实际使用的 PKCS#12 身份文件。流迹会验证源站证书，再显示新连接中的 HTTP/1.1 请求和响应。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !settings.routes.isEmpty {
                Toggle("启用已配置的服务", isOn: Binding(get: { settings.enabled }, set: settings.setEnabled))
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(settings.routes, id: \.id) { route in
                            HStack {
                                Text("\(route.host):\(route.port)").font(.body.monospaced()).textSelection(.enabled)
                                Spacer()
                                Button("关闭") { settings.remove(id: route.id) }
                            }
                        }
                    }
                }.frame(maxHeight: 116)
                Divider()
            }
            HStack {
                TextField("服务主机名", text: $host)
                TextField("端口", text: $portText).frame(width: 70)
            }
            HStack {
                Button("选择身份文件…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = ["p12", "pfx"].compactMap { UTType(filenameExtension: $0) }
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK {
                        file = panel.url
                        password = ""
                        message = nil
                    }
                }
                Text(file?.lastPathComponent ?? "未选文件").lineLimit(1).truncationMode(.middle)
            }
            SecureField("身份文件密码", text: $password)
            Text("证书私钥仅在本次运行中使用。").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).foregroundStyle(WorkspaceTheme.failure).textSelection(.enabled) }
            HStack {
                Button("启用此服务") {
                    guard let file, let port = UInt16(portText) else { return }
                    do {
                        try settings.add(host: host, port: port, file: file, password: password)
                        password = ""
                        self.file = nil
                        message = nil
                    } catch {
                        message = error.localizedDescription
                    }
                }.disabled(host.isEmpty || file == nil || (UInt16(portText) ?? 0) == 0)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24).frame(width: 496)
        .onAppear { host = initialHost ?? ""; portText = String(initialPort) }
    }
}


struct HTTPSProxyCommand: View {
    @ObservedObject var settings: OwnedHTTPSSettings
    let configure: () -> Void

    var body: some View {
        Button(settings.enabled && !settings.routes.isEmpty ? "暂停 HTTPS 调试" : "开始 HTTPS 调试") {
            if settings.routes.isEmpty { configure() } else { settings.setEnabled(!settings.enabled) }
        }.keyboardShortcut("l", modifiers: .command)
    }
}
