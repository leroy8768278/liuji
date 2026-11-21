import Darwin
import Foundation
import Network
import Security
import SwiftUI

struct MobileProxyConfiguration: Sendable {
    let listenAddress: String
    let clientAddress: String
    let username: String
    let password: String
    private let interface: MobileProxyInterface

    init(interface: MobileProxyInterface, clientAddress: String) throws {
        let client = try interface.validatedClient(clientAddress)
        var random = [UInt8](repeating: 0, count: 18)
        let status = random.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, address)
        }
        guard status == errSecSuccess else { throw MobileProxyError.randomnessUnavailable }

        self.interface = interface
        listenAddress = interface.address
        self.clientAddress = client.description
        username = "liuji"
        password = Data(random).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    func authorizes(_ headerValues: [String]) -> Bool {
        guard headerValues.count == 1, let header = headerValues.first else { return false }
        let parts = header.split { $0 == " " || $0 == "\t" }
        let expected = Data("\(username):\(password)".utf8)
        guard parts.count == 2, parts[0].lowercased() == "basic",
              parts[1].utf8.count == (expected.count + 2) / 3 * 4,
              let supplied = Data(base64Encoded: String(parts[1])), supplied.count == expected.count else { return false }
        return zip(expected, supplied).reduce(UInt8.zero) { difference, bytes in
            difference | (bytes.0 ^ bytes.1)
        } == 0
    }

    func isCurrentInterfaceAvailable() -> Bool {
        Self.availableInterfaces().contains(interface)
    }

    static func availableInterfaces() -> [MobileProxyInterface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var interfaces: Set<MobileProxyInterface> = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let needed = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
            let excluded = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
            guard entry.ifa_flags & needed == needed, entry.ifa_flags & excluded == 0,
                  let address = MobileIPv4Address(entry.ifa_addr),
                  let netmask = MobileIPv4Address.netmask(entry.ifa_netmask),
                  let privatePrefix = address.privatePrefix else { continue }

            let prefixLength = (~netmask).leadingZeroBitCount
            guard let mask = MobileIPv4Address.subnetMask(prefixLength), mask == netmask,
                  prefixLength >= privatePrefix, address.isUsable(in: mask) else { continue }
            interfaces.insert(MobileProxyInterface(
                name: String(cString: entry.ifa_name), address: address.description, prefixLength: prefixLength
            ))
        }
        return interfaces.sorted { ($0.name, $0.address) < ($1.name, $1.address) }
    }
}

struct MobileProxyInterface: Hashable, Identifiable, Sendable {
    let name: String
    let address: String
    let prefixLength: Int

    var id: String { "\(name):\(address)/\(prefixLength)" }

    func validateClientAddress(_ address: String) -> String? {
        do {
            _ = try validatedClient(address)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    fileprivate func validatedClient(_ input: String) throws -> MobileIPv4Address {
        guard let server = MobileIPv4Address(address), let privatePrefix = server.privatePrefix,
              let mask = MobileIPv4Address.subnetMask(prefixLength), prefixLength >= privatePrefix,
              server.isUsable(in: mask) else { throw MobileProxyError.interfaceUnavailable }
        guard let client = MobileIPv4Address(input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MobileProxyError.malformedClient
        }
        guard client.bits != server.bits else { throw MobileProxyError.sameAddress }
        guard client.privatePrefix != nil, client.bits & mask == server.bits & mask,
              client.isUsable(in: mask) else { throw MobileProxyError.differentSubnet }
        return client
    }
}

private struct MobileIPv4Address {
    let bits: UInt32

    init?(_ text: String) {
        guard let address = IPv4Address(text) else { return nil }
        bits = address.rawValue.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    init?(_ address: UnsafePointer<sockaddr>?) {
        guard let address, address.pointee.sa_family == UInt8(AF_INET),
              address.pointee.sa_len >= MemoryLayout<sockaddr_in>.size else { return nil }
        bits = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
    }

    static func netmask(_ address: UnsafePointer<sockaddr>?) -> UInt32? {
        guard let address, address.pointee.sa_family == UInt8(AF_INET),
              let offset = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr),
              Int(address.pointee.sa_len) > offset else { return nil }

        // Darwin can omit trailing zero bytes in an interface's netmask sockaddr.
        let addressLength = MemoryLayout<in_addr>.size
        let count = min(Int(address.pointee.sa_len) - offset, addressLength)
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(address).advanced(by: offset), count: count)
        let significant = bytes.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        return significant << ((addressLength - count) * 8)
    }

    var description: String {
        [24, 16, 8, 0].map { String((bits >> $0) & 255) }.joined(separator: ".")
    }

    var privatePrefix: Int? {
        if bits >> 24 == 10 { return 8 }
        if bits >> 20 == 0xAC1 { return 12 }
        if bits >> 16 == 0xC0A8 { return 16 }
        return nil
    }

    func isUsable(in mask: UInt32) -> Bool {
        let host = bits & ~mask
        return host != 0 && host != ~mask
    }

    static func subnetMask(_ prefixLength: Int) -> UInt32? {
        guard (8...30).contains(prefixLength) else { return nil }
        return UInt32.max << (32 - prefixLength)
    }
}

private enum MobileProxyError: LocalizedError {
    case interfaceUnavailable, malformedClient, sameAddress, differentSubnet, randomnessUnavailable

    var errorDescription: String? {
        switch self {
        case .interfaceUnavailable: "该网卡没有可用于手机代理的私有 IPv4 地址。"
        case .malformedClient: "输入手机在当前 Wi-Fi 上的 IPv4 地址。"
        case .sameAddress: "填写手机的地址，须与 Mac 地址不同。"
        case .differentSubnet: "手机须使用与选定网卡处于同一私有子网的单播地址。"
        case .randomnessUnavailable: "无法生成本次接入密码。"
        }
    }
}

struct MobileProxySheet: View {
    @ObservedObject var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var interfaces: [MobileProxyInterface] = []
    @State private var selectedInterfaceID: String?
    @State private var clientAddress = ""
    @State private var startError: String?
    @State private var lastCopied: String?

    private var selectedInterface: MobileProxyInterface? {
        interfaces.first { $0.id == selectedInterfaceID }
    }

    private var mobileRunning: Bool {
        if case .running = store.mobileState { return true }
        return false
    }

    private var editable: Bool { store.mobileState != .starting && !mobileRunning }

    private var peerError: String? {
        guard !clientAddress.isEmpty, let selectedInterface else { return nil }
        return selectedInterface.validateClientAddress(clientAddress)
    }

    private var canStart: Bool {
        store.isRunning && editable && selectedInterface != nil && !clientAddress.isEmpty && peerError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            interfaceSection
            if case let .running(port) = store.mobileState, let configuration = store.mobileConfiguration {
                credentials(configuration, port: port)
            }
            instructions
            footer
        }
        .padding(22)
        .frame(width: 540)
        .foregroundStyle(WorkspaceTheme.ink)
        .background(WorkspaceTheme.canvas)
        .tint(WorkspaceTheme.accent)
        .onAppear {
            if let configuration = store.mobileConfiguration { clientAddress = configuration.clientAddress }
            refreshInterfaces()
        }
        .onChange(of: store.mobileState) { _, _ in lastCopied = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(WorkspaceTheme.accent)
                .frame(width: 41, height: 41)
                .background(WorkspaceTheme.accentFill, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("手机接入").font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text("让手机和 Mac 连接同一个 Wi-Fi，并填写手机的 IPv4 地址。")
                    .font(.system(size: 12))
                    .foregroundStyle(WorkspaceTheme.muted)
            }
        }
    }

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Picker("Mac 网卡", selection: $selectedInterfaceID) {
                    if interfaces.isEmpty {
                        Text("未找到可接入的网卡").tag(String?.none)
                    }
                    ForEach(interfaces) { interface in
                        Text("\(interface.name) · \(interface.address)/\(interface.prefixLength)")
                            .tag(Optional(interface.id))
                    }
                }
                .disabled(!editable || interfaces.isEmpty)
                Button(action: refreshInterfaces) {
                    Label("刷新网卡", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .disabled(!editable)
                .help("刷新网卡")
            }

            HStack(spacing: 9) {
                Text("手机 IPv4")
                TextField("手机 IPv4", text: $clientAddress, prompt: Text("例如 192.168.1.25"))
                    .labelsHidden()
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .disabled(!editable)
                    .onChange(of: clientAddress) { _, _ in startError = nil }
            }

            if let error = startError ?? peerError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(WorkspaceTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(WorkspaceTheme.sidebar, in: RoundedRectangle(cornerRadius: 9))
    }

    private func credentials(_ configuration: MobileProxyConfiguration, port: UInt16) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            copyable("代理地址", value: "\(configuration.listenAddress):\(port)")
            copyable("用户名", value: configuration.username)
            copyable("本次密码", value: configuration.password)
        }
        .padding(12)
        .background(WorkspaceTheme.accentFill, in: RoundedRectangle(cornerRadius: 9))
    }

    private func copyable(_ title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                CopyText.toPasteboard(value)
                lastCopied = title
            } label: {
                Label(lastCopied == title ? "已复制" : "复制\(title)",
                      systemImage: lastCopied == title ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(lastCopied == title ? "已复制" : "复制\(title)")
        }
        .font(.system(size: 12))
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("在手机上配置手动 HTTP 代理").font(.system(size: 13, weight: .semibold))
            Text("iPhone 上打开设置 → Wi-Fi → 当前网络详情 → 配置代理 → 手动。填写 Mac 地址和端口，再启用认证并输入本次用户名和密码。")
            Text("Android 上编辑当前 Wi-Fi → 高级选项 → 代理 → 手动。填写地址和端口，并在支持代理认证的客户端中输入用户名和密码。")
            Text("HTTPS 以加密隧道转发。结束后在手机的 Wi-Fi 设置中关闭代理。")
        }
        .font(.system(size: 12))
        .foregroundStyle(WorkspaceTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            switch store.mobileState {
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(WorkspaceTheme.failure)
                    .fixedSize(horizontal: false, vertical: true)
            case .starting:
                ProgressView().controlSize(.small)
                Text("正在开启")
            case .running:
                Label("正在监听", systemImage: "circle.fill").foregroundStyle(WorkspaceTheme.good)
            case .stopped:
                if case let .failed(message) = store.state {
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(WorkspaceTheme.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            if mobileRunning {
                Button("停止手机代理", action: store.stopMobile)
            } else if !store.isRunning {
                Button("开启本机代理", action: store.start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.state == .starting)
            } else {
                Button("开启手机代理", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .font(.system(size: 12))
    }

    private func refreshInterfaces() {
        interfaces = MobileProxyConfiguration.availableInterfaces()
        let activeAddress = store.mobileConfiguration?.listenAddress
        if let active = interfaces.first(where: { $0.address == activeAddress }) {
            selectedInterfaceID = active.id
        } else if selectedInterface == nil {
            selectedInterfaceID = interfaces.first?.id
        }
        startError = nil
    }

    private func start() {
        guard let selectedInterface else { return }
        do {
            let configuration = try MobileProxyConfiguration(interface: selectedInterface, clientAddress: clientAddress)
            store.startMobile(configuration)
        } catch {
            startError = error.localizedDescription
        }
    }
}
