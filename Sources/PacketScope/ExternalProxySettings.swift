import Darwin
import SwiftUI

struct LoopbackHTTPProxy: Codable, Equatable, Sendable {
    let host: String
    let port: UInt16

    var isLoopback: Bool {
        var address = in_addr()
        return port > 0 && !host.utf8.contains(0) && inet_pton(AF_INET, host, &address) == 1 &&
            UInt32(bigEndian: address.s_addr) >> 24 == 127
    }
    func usable(excluding listener: UInt16) -> Bool { isLoopback && port != listener }
    var label: String { "\(host):\(port)" }
}

struct ExternalProxySetting: Codable, Equatable {
    var enabled = false
    var endpoint: LoopbackHTTPProxy?
}

struct ExternalProxySettingsSheet: View {
    @ObservedObject var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var host = "127.0.0.1"
    @State private var port = ""

    private var endpoint: LoopbackHTTPProxy? {
        guard let number = UInt16(port) else { return nil }
        let address = LoopbackHTTPProxy(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: number)
        return address.usable(excluding: store.port) ? address : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("外部代理设置").font(.title2.bold())
            Toggle("通过本机 HTTP 上游转发外网请求", isOn: $enabled)
            HStack {
                TextField("本机 IPv4 回环地址", text: $host)
                TextField("端口", text: $port).frame(width: 85)
            }
            .textFieldStyle(.roundedBorder)
            Text("适用于本机无需认证的 HTTP 代理。开启后，新请求和 HTTPS 隧道可使用该出口；本机开发服务仍直连。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if enabled && endpoint == nil {
                Text("请输入 127.0.0.0/8 内的 IPv4 地址，以及与监听端口不同的有效端口。")
                    .font(.caption).foregroundStyle(WorkspaceTheme.warning)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.setExternalProxy(ExternalProxySetting(enabled: enabled, endpoint: endpoint))
                    dismiss()
                }.disabled(enabled && endpoint == nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 480)
        .onAppear {
            enabled = store.externalProxy.enabled
            if let address = store.externalProxy.endpoint ?? store.suggestedExternalProxy {
                host = address.host
                port = String(address.port)
            }
        }
    }
}
