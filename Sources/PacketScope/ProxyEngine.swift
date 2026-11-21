import Darwin
import Foundation
import Network
import UniformTypeIdentifiers

enum ProxyState: Equatable, Sendable {
    case stopped
    case starting
    case running(UInt16)
    case failed(String)
}

final class ProxyEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.packetscope.proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var mobileListener: NWListener?
    private var clients: [UUID: ProxyConnection] = [:]
    private var onState: (@Sendable (ProxyState) -> Void)?
    private var onMobileState: (@Sendable (ProxyState) -> Void)?
    private var onCapture: (@Sendable (CaptureSession) -> Void)?
    private var rules = ProxyRuleSet()
    private var externalProxy: LoopbackHTTPProxy?
    func setExternalProxy(_ address: LoopbackHTTPProxy?) {
        queue.async { [self] in externalProxy = address?.isLoopback == true ? address : nil }
    }
    private var collectProcesses = false
    private let processResolver = LocalClientProcessResolver()

    func setProcessCollection(_ enabled: Bool) {
        queue.async { [self] in collectProcesses = enabled }
    }
    private var ownedHTTPS: [OwnedHTTPSRoute] = []
    private var trafficOptions = ProxyTrafficOptions()

    func start(
        port: UInt16,
        onState: @escaping @Sendable (ProxyState) -> Void,
        onSession: @escaping @Sendable (CaptureSession) -> Void
    ) {
        queue.async { [self] in
            guard listener == nil else { return }
            self.onState = onState
            self.onCapture = onSession
            onState(.starting)

            do {
                let listener = try makeListener(host: "127.0.0.1", port: port)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        onState(.running(listener.port?.rawValue ?? port))
                    case let .failed(error), let .waiting(error):
                        self.shutdown()
                        onState(.failed("无法监听本地代理端口。\(error.localizedDescription)"))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self, weak listener] connection in
                    guard let self, let listener, self.listener === listener else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection, port: listener.port?.rawValue ?? port, mobile: nil)
                }
                listener.start(queue: queue)
            } catch {
                shutdown()
                onState(.failed("无法启动本地代理。\(error.localizedDescription)"))
            }
        }
    }

    func startMobile(_ configuration: MobileProxyConfiguration, port: UInt16, onState: @escaping @Sendable (ProxyState) -> Void) {
        queue.async { [self] in
            guard mobileListener == nil else { return }
            onState(.starting)
            guard let listener, case .ready = listener.state else {
                onState(.failed("请先启动本地代理。"))
                return
            }
            guard configuration.isCurrentInterfaceAvailable(),
                  let address = IPv4Address(configuration.listenAddress),
                  let peerAddress = IPv4Address(configuration.clientAddress) else {
                onState(.failed("选定的内网 IPv4 地址已不可用。"))
                return
            }

            do {
                let mobile = try makeListener(host: .ipv4(address), port: port)
                mobileListener = mobile
                onMobileState = onState
                mobile.stateUpdateHandler = { [weak self, weak mobile] state in
                    guard let self, let mobile, self.mobileListener === mobile else { return }
                    switch state {
                    case .ready:
                        onState(.running(mobile.port?.rawValue ?? port))
                    case let .failed(error), let .waiting(error):
                        self.shutdownMobile(notify: false)
                        onState(.failed("无法监听移动设备代理。\(error.localizedDescription)"))
                    default:
                        break
                    }
                }
                mobile.newConnectionHandler = { [weak self, weak mobile] connection in
                    guard let self, let mobile, self.mobileListener === mobile,
                          case let .hostPort(.ipv4(actualPeer), _) = connection.endpoint,
                          actualPeer.rawValue == peerAddress.rawValue else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection, port: mobile.port?.rawValue ?? port, mobile: configuration)
                }
                mobile.start(queue: queue)
            } catch {
                shutdownMobile(notify: false)
                onState(.failed("无法启动移动设备代理。\(error.localizedDescription)"))
            }
        }
    }

    func stopMobile() {
        queue.async { [self] in shutdownMobile() }
    }

    func updateRules(_ rules: ProxyRuleSet) {
        queue.async { [self] in self.rules = rules }
    }

    func updateOwnedHTTPS(_ routes: [OwnedHTTPSRoute]) {
        queue.async { [self] in
            ownedHTTPS = routes
            let ids = Set(routes.map(\.id))
            let removed = clients.values.filter { $0.ownedRouteID.map { !ids.contains($0) } == true }
            removed.forEach { $0.terminate() }
        }
    }

    func updateTrafficOptions(_ options: ProxyTrafficOptions) {
        queue.async { [self] in
            let shouldResume = trafficOptions.breakpointsEnabled && !options.breakpointsEnabled
            trafficOptions = options
            if shouldResume {
                Array(clients.values).forEach { $0.resolveBreakpoint(proceed: true) }
            }
        }
    }

    func resolveBreakpoint(sessionID: UUID, proceed: Bool, edit: CaptureHeader? = nil) {
        queue.async { [self] in clients[sessionID]?.resolveBreakpoint(proceed: proceed, edit: edit) }
    }

    func terminate(sessionID: UUID) {
        queue.async { [self] in clients[sessionID]?.terminate() }
    }

    func stop() {
        queue.async { [self] in
            let notify = onState
            shutdown()
            notify?(.stopped)
        }
    }

    private func shutdown() {
        shutdownMobile()
        listener?.cancel()
        listener = nil
        let active = Array(clients.values)
        clients.removeAll()
        active.forEach { $0.stop() }
        onState = nil
        onCapture = nil
    }

    private func shutdownMobile(notify: Bool = true) {
        mobileListener?.cancel()
        mobileListener = nil
        let active = clients.values.filter(\.isMobile)
        active.forEach { $0.stop() }
        if notify { onMobileState?(.stopped) }
        onMobileState = nil
    }

    private func makeListener(host: NWEndpoint.Host, port: UInt16) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: port) ?? .any)
        return try NWListener(using: parameters)
    }

    private func accept(_ connection: NWConnection, port: UInt16, mobile: MobileProxyConfiguration?,
                        verified: VerifiedHTTPSOrigin? = nil) {
        guard clients.count < 128, let onCapture else {
            connection.cancel()
            verified?.connection.cancel()
            return
        }
        let id = UUID()
        let client = ProxyConnection(
            id: id, client: connection, port: port, queue: queue, mobile: mobile,
            verified: verified,
            currentExternalProxy: { [weak self] in self?.externalProxy },
            routeForHTTPS: { [weak self] host, port in self?.ownedHTTPS.first { $0.host == host.lowercased() && $0.port == port } },
            onDecryptedClient: { [weak self] connection, origin in
                self?.accept(connection, port: port, mobile: mobile, verified: origin)
            },
            hasConnectingUpstream: { [weak self] in self?.clients.values.contains(where: \.isConnectingUpstream) == true },
            currentRules: { [weak self] in self?.rules ?? ProxyRuleSet() },
            currentTrafficOptions: { [weak self] in self?.trafficOptions ?? ProxyTrafficOptions() },
            onSession: onCapture, onClose: { [weak self] in self?.clients[id] = nil }
        )
        clients[id] = client
        if let origin = verified {
            client.processLookup = origin.processLookup
        } else if collectProcesses, mobile == nil,
                  case let .hostPort(.ipv4(address), peer) = connection.endpoint, address == .loopback {
            let lookup = ClientProcessLookup()
            client.processLookup = lookup
            processResolver.resolve(port: port, peer: peer.rawValue) { [weak self] result in
                guard let self, let result else { return }
                self.queue.async {
                    // An expired pair can be reused by another process.
                    guard self.collectProcesses, self.clients[id] != nil else { return }
                    lookup.result = result
                    for client in self.clients.values where client.processLookup === lookup {
                        client.refreshClientProcess()
                    }
                }
            }
        }
        client.start()
    }
}

private struct ProxyFailure: Error {
    let status: Int
    let message: String
    let reason: String
    var additionalHeaders: [CaptureHeader] = []

    static let badRequest = Self(status: 400, message: "请求格式无效。", reason: "Bad Request")
    static let tooLarge = Self(status: 431, message: "请求头超出大小限制。", reason: "Request Header Fields Too Large")
    static let upgrade = Self(status: 501, message: "HTTP 协议升级暂不可用。", reason: "Not Implemented")
    static let proxyLoop = Self(status: 400, message: "请求指向当前代理端口。", reason: "Bad Request")
    static let timeout = Self(status: 504, message: "连接超时。", reason: "Gateway Timeout")
    static let fileUnavailable = Self(status: 404, message: "无法读取选定的本地文件。", reason: "Not Found")
    static let fileTooLarge = Self(status: 413, message: "本地映射文件超出 2 MiB 的大小限制。", reason: "Content Too Large")
    static let breakpointCancelled = Self(status: 403, message: "已取消断点请求。", reason: "Forbidden")
    static let breakpointExpired = Self(status: 504, message: "等待断点操作超时。", reason: "Gateway Timeout")
    static let authenticationRequired = Self(
        status: 407, message: "移动设备代理需要身份验证。", reason: "Proxy Authentication Required",
        additionalHeaders: [CaptureHeader(name: "Proxy-Authenticate", value: "Basic realm=\"PacketScope\"")]
    )

    static func blocked(_ message: String) -> Self {
        Self(status: 403, message: message, reason: "Forbidden")
    }

    static func upstream(_ message: String) -> Self {
        Self(status: 502, message: message, reason: "Bad Gateway")
    }
}

private struct HTTPHeaderBlock {
    static let delimiter = Data([13, 10, 13, 10])
    static let limit = 64 * 1_024

    let startLine: String
    let headers: [CaptureHeader]
    var capturedFields: [CaptureHeader] {
        headers.filter { !["proxy-authorization", "proxy-authenticate", "proxy-authentication-info"].contains($0.name.lowercased()) }
    }

    init(_ bytes: Data) throws {
        guard let text = String(data: bytes, encoding: .isoLatin1) else { throw ProxyFailure.badRequest }
        var lines = text.components(separatedBy: "\r\n")
        startLine = lines.removeFirst()
        guard !startLine.isEmpty, Self.isFieldText(startLine) else { throw ProxyFailure.badRequest }
        headers = try lines.map { line in
            guard let separator = line.firstIndex(of: ":") else { throw ProxyFailure.badRequest }
            let name = String(line[..<separator])
            let value = line[line.index(after: separator)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard Self.isToken(name), Self.isFieldText(value) else { throw ProxyFailure.badRequest }
            return CaptureHeader(name: name, value: value)
        }
    }

    func values(_ name: String) -> [String] {
        headers.compactMap { $0.name.lowercased() == name ? $0.value : nil }
    }

    var connectionFields: Set<String> {
        Set((values("connection") + values("proxy-connection")).flatMap {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        })
    }

    func bodyMode(response: Bool) throws -> HTTPBody.Mode {
        let lengths = values("content-length").flatMap {
            $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let encodings = values("transfer-encoding").flatMap {
            $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        guard connectionFields.isDisjoint(with: ["transfer-encoding", "content-length"]) else {
            throw ProxyFailure.badRequest
        }
        if !encodings.isEmpty {
            guard lengths.isEmpty, !encodings.contains("") else { throw ProxyFailure.badRequest }
            if encodings.last == "chunked", !encodings.dropLast().contains("chunked") {
                return .chunkSize
            }
            if response, !encodings.contains("chunked") { return .untilEOF }
            throw ProxyFailure.badRequest
        }
        if let first = lengths.first {
            guard !first.isEmpty,
                  first.utf8.allSatisfy({ (48...57).contains($0) }),
                  lengths.allSatisfy({ $0 == first }),
                  let count = Int(first) else { throw ProxyFailure.badRequest }
            return count == 0 ? .complete : .length(count)
        }
        return response ? .untilEOF : .complete
    }

    func forwardedFields() -> [CaptureHeader] {
        let except = connectionFields.union([
            "connection", "proxy-connection", "proxy-authorization", "proxy-authenticate", "proxy-authentication-info", "keep-alive", "te", "upgrade"
        ])
        return headers.filter { !except.contains($0.name.lowercased()) }
    }

    static func rewritingDebugFields(_ headers: [CaptureHeader], with replacements: [CaptureHeader]) -> [CaptureHeader] {
        var rewritten = headers
        for replacement in replacements {
            let name = replacement.name.lowercased()
            guard name.hasPrefix("x-debug-"), name.count > 8, isToken(replacement.name),
                  isFieldText(replacement.value), replacement.value.data(using: .isoLatin1) != nil else { continue }
            rewritten.removeAll { $0.name.lowercased() == name }
            rewritten.append(replacement)
        }
        return rewritten
    }

    static func serialized(_ line: String, _ headers: [CaptureHeader]) -> Data {
        let lines = [line] + headers.map { "\($0.name): \($0.value)" } + ["", ""]
        return lines.joined(separator: "\r\n").data(using: .isoLatin1) ?? Data()
    }

    static func isToken(_ text: String) -> Bool {
        let punctuation = "!#$%&'*+-.^`_|~"
        return !text.isEmpty && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || punctuation.utf8.contains($0)
        }
    }

    private static func isFieldText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value == 9 || ($0.value >= 32 && $0.value != 127) }
    }
}

private struct HTTPBody {
    enum Mode {
        case length(Int)
        case untilEOF
        case chunkSize
        case chunkData(Int)
        case chunkDelimiter(Int)
        case chunkTrailer
        case complete
    }

    private static let captureLimit = 256 * 1_024
    private var mode: Mode
    private var line = Data()
    private var trailerBytes = 0
    private(set) var capture = Data()
    private(set) var count = 0

    init(_ mode: Mode) {
        self.mode = mode
    }

    var isComplete: Bool {
        if case .complete = mode { return true }
        return false
    }

    mutating func endOfStream() -> Bool {
        if case .untilEOF = mode { mode = .complete }
        return isComplete
    }

    // Return the framed byte count for forwarding, and collect decoded transfer chunks for display.
    mutating func consume(_ data: Data) throws -> Int {
        var index = data.startIndex
        while index < data.endIndex, !isComplete {
            switch mode {
            case let .length(remaining), let .chunkData(remaining):
                let size = min(remaining, data.distance(from: index, to: data.endIndex))
                let end = data.index(index, offsetBy: size)
                append(data[index..<end])
                index = end
                if case .length = mode {
                    mode = size == remaining ? .complete : .length(remaining - size)
                } else {
                    mode = size == remaining ? .chunkDelimiter(0) : .chunkData(remaining - size)
                }
            case .untilEOF:
                append(data[index...])
                index = data.endIndex
            case let .chunkDelimiter(position):
                guard data[index] == (position == 0 ? 13 : 10) else { throw ProxyFailure.badRequest }
                index = data.index(after: index)
                mode = position == 0 ? .chunkDelimiter(1) : .chunkSize
            case .chunkSize, .chunkTrailer:
                let byte = data[index]
                index = data.index(after: index)
                if case .chunkTrailer = mode {
                    trailerBytes += 1
                    guard trailerBytes <= HTTPHeaderBlock.limit else { throw ProxyFailure.badRequest }
                }
                guard byte == 10 else {
                    line.append(byte)
                    guard line.count <= 8 * 1_024 else { throw ProxyFailure.badRequest }
                    continue
                }
                guard line.popLast() == 13 else { throw ProxyFailure.badRequest }
                if case .chunkSize = mode {
                    let digits = line.prefix { $0 != 59 }
                    guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                          let size = Int(String(decoding: digits, as: UTF8.self), radix: 16) else {
                        throw ProxyFailure.badRequest
                    }
                    mode = size == 0 ? .chunkTrailer : .chunkData(size)
                } else if line.isEmpty {
                    mode = .complete
                }
                line.removeAll(keepingCapacity: true)
            case .complete:
                break
            }
        }
        return data.distance(from: data.startIndex, to: index)
    }

    private mutating func append(_ data: Data) {
        count += data.count
        if capture.count < Self.captureLimit {
            capture.append(contentsOf: data.prefix(Self.captureLimit - capture.count))
        }
    }
}

private struct HTTPUpstream {
    var host: String
    let port: UInt16
    var outboundHead: Data
    var external: LoopbackHTTPProxy?
}

private struct HTTPDestination {
    let url: String
    let host: String
    let port: UInt16
    private let parts: URLComponents
    let body: HTTPBody
    var path: String { parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath }
    var query: String? { parts.percentEncodedQuery }
    var isLocalRuleHost: Bool {
        let host = self.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return Self.loopbackSocket(host) != nil || host.hasSuffix(".test") || host.hasSuffix(".localhost")
    }

    init(block: HTTPHeaderBlock, method: String, target: String, version: String, ownedRoute: OwnedHTTPSRoute? = nil) throws {
        let tunnel = method == "CONNECT"
        let secure = tunnel || ownedRoute != nil
        let urlText: String
        let hosts = block.values("host")
        if let ownedRoute {
            let host = block.values("host")
            let expected = "\(ownedRoute.host):\(ownedRoute.port)"
            guard !tunnel, target.hasPrefix("/") || target == "*", host.count == 1,
                  let authority = host.first?.lowercased(),
                  authority == expected || (ownedRoute.port == 443 && authority == ownedRoute.host) else {
                throw ProxyFailure.badRequest
            }
            urlText = "https://\(authority)\(target == "*" ? "/" : target)"
        } else if tunnel {
            guard !target.contains(where: { "/?#@".contains($0) }) else { throw ProxyFailure.badRequest }
            urlText = "https://\(target)"
        } else if target.hasPrefix("/") || target == "*" {
            guard hosts.count == 1, let host = hosts.first, !host.contains(where: { "/?#@".contains($0) }) else {
                throw ProxyFailure.badRequest
            }
            urlText = "http://\(host)\(target == "*" ? "/" : target)"
        } else {
            urlText = target
        }
        guard hosts.count <= 1,
              let parts = URLComponents(string: urlText),
              parts.scheme?.lowercased() == (secure ? "https" : "http"),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let parsedHost = parts.url?.host, !parsedHost.isEmpty,
              let port = UInt16(exactly: parts.port ?? (secure ? 443 : 80)), port != 0 else {
            throw ProxyFailure.badRequest
        }
        self.url = urlText
        self.host = parsedHost
        self.port = port
        self.parts = parts

        let bodyMode = try block.bodyMode(response: false)
        body = HTTPBody(bodyMode)
        if tunnel {
            guard parts.port != nil, body.isComplete else { throw ProxyFailure.badRequest }
            return
        }

        guard !block.connectionFields.contains("upgrade"), block.values("upgrade").isEmpty else { throw ProxyFailure.upgrade }
        if case .chunkSize = bodyMode, version == "HTTP/1.0" { throw ProxyFailure.badRequest }
    }

    func upstream(using rules: ProxyForwardRules, block: HTTPHeaderBlock, method: String, target: String, version: String,
                  externalProxy: LoopbackHTTPProxy?) throws -> HTTPUpstream {
        let external = !isLocalRuleHost && rules.remoteURL == nil && rules.connectHost == nil ? externalProxy : nil
        if method == "CONNECT" {
            return HTTPUpstream(host: host, port: port, outboundHead: Data(), external: external)
        }

        var routedParts = parts
        if let remoteURL = rules.remoteURL {
            guard let remote = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false),
                  remote.scheme?.lowercased() == "http", remote.user == nil, remote.password == nil,
                  remote.fragment == nil, let remoteHost = remote.url?.host, Self.loopbackSocket(remoteHost) != nil else {
                throw ProxyFailure.badRequest
            }
            routedParts = remote
        }
        guard let routedHost = routedParts.url?.host,
              let routedPort = UInt16(exactly: routedParts.port ?? (routedParts.scheme == "https" ? 443 : 80)), routedPort != 0 else {
            throw ProxyFailure.badRequest
        }
        var socket = routedHost
        let hasChanges = rules.remoteURL != nil || rules.connectHost != nil || rules.replacementPath != nil ||
            !rules.requestHeaders.isEmpty || !rules.responseHeaders.isEmpty || rules.noCaching || rules.blockCookies
        if hasChanges {
            guard isLocalRuleHost, let loopback = Self.loopbackSocket(rules.connectHost ?? routedHost) else {
                throw ProxyFailure.badRequest
            }
            socket = loopback
        }

        var path = routedParts.percentEncodedPath.isEmpty ? "/" : routedParts.percentEncodedPath
        if let replacementPath = rules.replacementPath {
            guard replacementPath.hasPrefix("/"),
                  URLComponents(string: "http://localhost\(replacementPath)")?.percentEncodedPath == replacementPath else {
                throw ProxyFailure.badRequest
            }
            path = replacementPath
        }
        let hostname = routedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let headerHost = hostname.contains(":") ? "[\(hostname)]" : hostname
        let authority = routedParts.port.map { "\(headerHost):\($0)" } ?? headerHost
        let useAsterisk = target == "*" && rules.replacementPath == nil && rules.remoteURL == nil
        let origin = useAsterisk ? "*" : routedParts.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        let fields = rules.requestFields(block.forwardedFields(), method: method)
        let headers = fields.filter { $0.name.lowercased() != "host" } + [
            CaptureHeader(name: "Host", value: authority),
            CaptureHeader(name: "Connection", value: "close")
        ]
        let requestTarget = external == nil ? origin : "http://\(authority)\(useAsterisk ? "" : origin)"
        let head = HTTPHeaderBlock.serialized("\(method) \(requestTarget) \(version)", headers)
        return HTTPUpstream(host: socket, port: routedPort, outboundHead: head, external: external)
    }

    static func loopbackSocket(_ host: String) -> String? {
        let clean = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let name = clean.hasSuffix(".") ? String(clean.dropLast()) : clean
        if name.caseInsensitiveCompare("localhost") == .orderedSame { return "127.0.0.1" }
        if let ipv4 = IPv4Address(name), ipv4.rawValue.first == 127 { return ipv4.debugDescription }
        if let ipv6 = IPv6Address(name) {
            if ipv6 == .loopback { return "::1" }
            if ipv6.isIPv4Mapped, let mapped = IPv4Address(Data(ipv6.rawValue.suffix(4))),
               mapped.rawValue.first == 127 { return mapped.debugDescription }
        }
        return nil
    }
}

private extension ProxyForwardRules {
    func requestFields(_ headers: [CaptureHeader], method: String) -> [CaptureHeader] {
        var fields = HTTPHeaderBlock.rewritingDebugFields(headers, with: requestHeaders)
        if blockCookies { fields.removeAll { ["cookie", "cookie2"].contains($0.name.lowercased()) } }
        if noCaching {
            var removed = ["cache-control", "pragma"]
            if method == "GET" || method == "HEAD" { removed += ["if-modified-since", "if-none-match"] }
            fields.removeAll { removed.contains($0.name.lowercased()) }
            fields += [
                CaptureHeader(name: "Cache-Control", value: "no-cache"),
                CaptureHeader(name: "Pragma", value: "no-cache")
            ]
        }
        return fields
    }

    func responseFields(_ headers: [CaptureHeader]) -> [CaptureHeader] {
        var fields = HTTPHeaderBlock.rewritingDebugFields(headers, with: responseHeaders)
        if blockCookies { fields.removeAll { ["set-cookie", "set-cookie2"].contains($0.name.lowercased()) } }
        if noCaching {
            fields.removeAll { $0.name.lowercased() == "cache-control" }
            fields.append(CaptureHeader(name: "Cache-Control", value: "no-store"))
        }
        return fields
    }
}

private struct MappedFile {
    static let queue = DispatchQueue(label: "app.packetscope.local-files", qos: .utility)
    private static let limit = 2 * 1_024 * 1_024

    let length: Int
    let mimeType: String
    let body: Data

    init(url: URL, headOnly: Bool) throws {
        guard url.isFileURL, url.host == nil || url.host == "localhost" else {
            throw ProxyFailure.fileUnavailable
        }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else { throw ProxyFailure.fileUnavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else {
            throw ProxyFailure.fileUnavailable
        }
        guard metadata.st_size <= Self.limit else { throw ProxyFailure.fileTooLarge }
        mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if headOnly {
            length = Int(metadata.st_size)
            body = Data()
        } else {
            let data = try file.read(upToCount: Self.limit + 1) ?? Data()
            guard data.count <= Self.limit else { throw ProxyFailure.fileTooLarge }
            length = data.count
            body = data
        }
    }
}

private struct VerifiedHTTPSOrigin {
    let processLookup: ClientProcessLookup?
    let route: OwnedHTTPSRoute
    let connection: NWConnection
}

private final class ProxyConnection {
    private struct PausedRequest {
        let upstream: HTTPUpstream
        let remainder: Data
        let clientEOF: Bool
    }

    private let id: UUID
    private let client: NWConnection
    private let port: UInt16
    private let queue: DispatchQueue
    private let mobile: MobileProxyConfiguration?
    private let hasConnectingUpstream: () -> Bool
    private let verified: VerifiedHTTPSOrigin?
    private let currentExternalProxy: () -> LoopbackHTTPProxy?
    private let routeForHTTPS: (String, UInt16) -> OwnedHTTPSRoute?
    private let onDecryptedClient: (NWConnection, VerifiedHTTPSOrigin) -> Void
    private var localTLSListener: NWListener?
    private var localTLSCandidates = [NWConnection]()
    private var pendingOrigin: NWConnection?
    private(set) var ownedRouteID: UUID?
    private let currentRules: () -> ProxyRuleSet
    private let currentTrafficOptions: () -> ProxyTrafficOptions
    private let onSession: @Sendable (CaptureSession) -> Void
    private let onClose: () -> Void
    private let startedAt = Date()
    private var timer: DispatchSourceTimer?
    private var upstream: NWConnection?
    private var session: CaptureSession?
    var processLookup: ClientProcessLookup?
    func refreshClientProcess() { if !closed { publish() } }
    private var requestHead = Data()
    private var responseHead = Data()
    private var requestBody = HTTPBody(.complete)
    private var responseBody = HTTPBody(.complete)
    private var forwardRules: ProxyForwardRules?
    private var responseStarted = false
    private var viaExternalProxy = false
    private var tunnelBytes = 0
    private var tunnelUploadBytes = 0
    private var tunnelProgressPending = false
    private var tunnelDirectionsEnded = 0
    private var appliedUploadLatency = false
    private var appliedDownloadLatency = false
    private var pausedRequest: PausedRequest?
    private var pausedResponse: ((CaptureHeader?) -> Void)?
    private var isPaused: Bool { pausedRequest != nil || pausedResponse != nil }
    private var ending = false
    private var closed = false
    var isMobile: Bool { mobile != nil }
    var isConnectingUpstream: Bool {
        guard !ending, let upstream else { return false }
        switch upstream.state {
        case .setup, .preparing, .waiting: return true
        default: return false
        }
    }

    init(
        id: UUID,
        client: NWConnection,
        port: UInt16,
        queue: DispatchQueue,
        mobile: MobileProxyConfiguration?,
        verified: VerifiedHTTPSOrigin?,
        currentExternalProxy: @escaping () -> LoopbackHTTPProxy?,
        routeForHTTPS: @escaping (String, UInt16) -> OwnedHTTPSRoute?,
        onDecryptedClient: @escaping (NWConnection, VerifiedHTTPSOrigin) -> Void,
        hasConnectingUpstream: @escaping () -> Bool,
        currentRules: @escaping () -> ProxyRuleSet,
        currentTrafficOptions: @escaping () -> ProxyTrafficOptions,
        onSession: @escaping @Sendable (CaptureSession) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.id = id
        self.client = client
        self.port = port
        self.queue = queue
        self.mobile = mobile
        self.verified = verified
        self.ownedRouteID = verified?.route.id
        self.currentExternalProxy = currentExternalProxy
        self.routeForHTTPS = routeForHTTPS
        self.onDecryptedClient = onDecryptedClient
        self.hasConnectingUpstream = hasConnectingUpstream
        self.currentRules = currentRules
        self.currentTrafficOptions = currentTrafficOptions
        self.onSession = onSession
        self.onClose = onClose
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.fail(self.isPaused ? .breakpointExpired : .timeout)
        }
        self.timer = timer
        touch()
        timer.resume()
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequestHead()
            case let .failed(error):
                guard let self, !self.isRelayingTunnel else { return }
                self.finish(error.localizedDescription)
            default:
                break
            }
        }
        client.start(queue: queue)
    }

    func stop() {
        finish(isMobile ? "移动设备代理已停止。" : "本地代理已停止。")
    }

    func terminate() {
        finish("连接已手动终止。")
    }

    func resolveBreakpoint(proceed: Bool, edit: CaptureHeader? = nil) {
        guard isPaused, !ending else { return }
        let request = pausedRequest
        let response = pausedResponse
        pausedRequest = nil
        pausedResponse = nil
        session?.isPausedAtBreakpoint = false
        guard proceed else {
            fail(.breakpointCancelled)
            return
        }
        touch()
        publish()
        let field = session?.allowsBreakpointHeaderEdit == true ? edit?.validatedBreakpointHeader : nil
        if let request {
            var target = request.upstream
            if let field, let block = try? HTTPHeaderBlock(Data(target.outboundHead.dropLast(HTTPHeaderBlock.delimiter.count))) {
                target.outboundHead = HTTPHeaderBlock.serialized(block.startLine, HTTPHeaderBlock.rewritingDebugFields(block.headers, with: [field]))
                if let original = session?.requestHeaders {
                    session?.requestHeaders = HTTPHeaderBlock.rewritingDebugFields(original, with: [field])
                }
            }
            connect(target, remainder: request.remainder, clientEOF: request.clientEOF)
        } else { response?(field) }
    }

    private func pause(at phase: BreakpointPhase) {
        session?.isPausedAtBreakpoint = true
        session?.breakpointPhase = phase
        timer?.schedule(deadline: .now() + .seconds(60))
        publish()
    }

    private func touch() {
        guard !isPaused else { return }
        let idleSeconds = session?.isTunnel == true && responseStarted ? 300 : 30
        timer?.schedule(deadline: .now() + .seconds(idleSeconds))
    }

    private func receiveRequestHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: HTTPHeaderBlock.limit) { [weak self] data, _, complete, error in
            guard let self, !self.ending else { return }
            if let error {
                self.finish(error.localizedDescription)
                return
            }
            self.touch()
            if let data { self.requestHead.append(data) }
            guard let separator = self.requestHead.range(of: HTTPHeaderBlock.delimiter) else {
                if self.requestHead.count > HTTPHeaderBlock.limit {
                    self.fail(.tooLarge)
                } else if complete {
                    self.finish()
                } else {
                    self.receiveRequestHead()
                }
                return
            }
            guard separator.lowerBound <= HTTPHeaderBlock.limit else {
                self.fail(.tooLarge)
                return
            }
            let head = Data(self.requestHead[..<separator.lowerBound])
            let remainder = Data(self.requestHead[separator.upperBound...])
            self.requestHead.removeAll()
            self.beginRequest(head: head, remainder: remainder, clientEOF: complete)
        }
    }

    private func beginRequest(head: Data, remainder: Data, clientEOF: Bool) {
        do {
            let block = try HTTPHeaderBlock(head)
            if let mobile, verified == nil, !mobile.authorizes(block.values("proxy-authorization")) {
                fail(.authenticationRequired)
                return
            }
            let parts = block.startLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, HTTPHeaderBlock.isToken(parts[0]), !parts[1].isEmpty,
                  parts[1].utf8.allSatisfy({ (33...126).contains($0) }),
                  ["HTTP/1.1", "HTTP/1.0"].contains(parts[2]) else { throw ProxyFailure.badRequest }
            let (method, target, version) = (parts[0], parts[1], parts[2])
            let destination = try HTTPDestination(block: block, method: method, target: target, version: version, ownedRoute: verified?.route)
            let isTunnel = method == "CONNECT"
            if isTunnel, !isMobile, hasConnectingUpstream(), Self.isOwnLoopbackConnection(client, port: port) {
                throw ProxyFailure.proxyLoop
            }
            let decision = currentRules().decide(
                host: destination.host, path: destination.path, query: destination.query, method: method, isTunnel: isTunnel || verified != nil
            )
            var headers = block.capturedFields
            let notes: [String]
            switch decision {
            case let .blocked(message):
                notes = [message]
            case let .localFile(url):
                notes = ["本地映射 · \(url.lastPathComponent)"]
            case let .forward(rules):
                notes = isTunnel ? [] : rules.notes
                if !isTunnel { headers = rules.requestFields(headers, method: method) }
            }
            session = CaptureSession(
                id: id, startedAt: startedAt, method: method, url: destination.url,
                requestHeaders: headers, isTunnel: isTunnel
            )
            session?.ruleNotes = verified == nil ? notes : notes + ["自有服务 HTTPS · 已验证源站身份"]
            session?.device = mobile == nil ? .mac : .phone
            session?.requestHTTPVersion = version
            requestBody = destination.body
            publish()

            switch decision {
            case let .blocked(message):
                fail(.blocked(message))
            case let .localFile(url):
                guard !isTunnel, destination.isLocalRuleHost, method == "GET" || method == "HEAD" else {
                    throw ProxyFailure.badRequest
                }
                serveLocalFile(url, headOnly: method == "HEAD")
            case let .forward(rules):
                let external = verified == nil ? currentExternalProxy() : nil
                var upstream = try destination.upstream(using: rules, block: block, method: method, target: target,
                                                        version: version, externalProxy: external)
                let host = upstream.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let localAddress = host.hasPrefix("127.") || host.hasPrefix("::ffff:127.") || ["localhost", "::1", "0.0.0.0"].contains(host)
                if upstream.port == port, localAddress { throw ProxyFailure.proxyLoop }
                if !isTunnel { forwardRules = rules }
                let options = currentTrafficOptions()
                let localDestination = HTTPDestination.loopbackSocket(upstream.host)
                session?.allowsBreakpointHeaderEdit = verified != nil || (HTTPDestination.loopbackSocket(destination.host) != nil && localDestination != nil)
                let legacyMatch = options.breakpointsEnabled && options.matchesLocalPath && options.hasValidBreakpointPath &&
                    destination.path == options.breakpointPath && HTTPDestination.loopbackSocket(destination.host) != nil && localDestination != nil
                if !isTunnel, target != "*", legacyMatch || options.shouldPause(session, phase: .request) {
                    if legacyMatch, let localDestination { upstream.host = localDestination }
                    pausedRequest = PausedRequest(upstream: upstream, remainder: remainder, clientEOF: clientEOF)
                    pause(at: .request)
                } else {
                    connect(upstream, remainder: remainder, clientEOF: clientEOF)
                }
            }
        } catch {
            fail(error as? ProxyFailure ?? .badRequest)
        }
    }

    private func serveLocalFile(_ url: URL, headOnly: Bool) {
        MappedFile.queue.async { [weak self, queue] in
            let result = Result { try MappedFile(url: url, headOnly: headOnly) }
            queue.async { [weak self] in
                guard let self, !self.ending else { return }
                switch result {
                case let .success(file):
                    let headers = [
                        CaptureHeader(name: "Content-Type", value: file.mimeType),
                        CaptureHeader(name: "Content-Length", value: String(file.length)),
                        CaptureHeader(name: "Cache-Control", value: "no-store"),
                        CaptureHeader(name: "X-Content-Type-Options", value: "nosniff"),
                        CaptureHeader(name: "Connection", value: "close")
                    ]
                    self.respond(status: 200, reason: "OK", headers: headers, body: file.body)
                case let .failure(error):
                    self.fail(error as? ProxyFailure ?? .fileUnavailable)
                }
            }
        }
    }

    // Network.framework may fall back to an HTTP proxy even when direct connections
    // are preferred. Match the outgoing half of the local TCP pair in this process
    // so another browser connection to the same host can still proceed.
    private static func isOwnLoopbackConnection(_ client: NWConnection, port: UInt16) -> Bool {
        guard case let .hostPort(.ipv4(address), peerPort) = client.endpoint, address == .loopback else { return false }
        let pid = getpid()
        let size = MemoryLayout<proc_fdinfo>.stride
        let bytes = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
        guard bytes > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: bytes / size + 16)
        let count = descriptors.withUnsafeMutableBytes {
            Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))) / size
        }
        let loopback = INADDR_LOOPBACK.bigEndian
        for entry in descriptors.prefix(max(0, count)) where entry.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let length = Int32(MemoryLayout.size(ofValue: socket))
            guard proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDSOCKETINFO, &socket, length) == length,
                  socket.psi.soi_kind == SOCKINFO_TCP, socket.psi.soi_family == AF_INET else { continue }
            let ip = socket.psi.soi_proto.pri_tcp.tcpsi_ini
            if ip.insi_lport == Int32(peerPort.rawValue.bigEndian), ip.insi_fport == Int32(port.bigEndian),
               ip.insi_laddr.ina_46.i46a_addr4.s_addr == loopback, ip.insi_faddr.ina_46.i46a_addr4.s_addr == loopback {
                return true
            }
        }
        return false
    }

    private func connect(_ destination: HTTPUpstream, remainder: Data, clientEOF: Bool) {
        if let verified {
            guard destination.host.lowercased() == verified.route.host, destination.port == verified.route.port else {
                fail(.badRequest)
                return
            }
            upstream = verified.connection
            sendRequest(destination.outboundHead, to: verified.connection, remainder: remainder, clientEOF: clientEOF)
            return
        }
        let route = session?.isTunnel == true ? routeForHTTPS(destination.host, destination.port) : nil
        let external = route == nil ? destination.external : nil
        if let external, !external.usable(excluding: self.port) {
            fail(.upstream("本机 HTTP 上游不能使用当前监听端口。"))
            return
        }
        guard let port = NWEndpoint.Port(rawValue: external?.port ?? destination.port) else {
            fail(.badRequest)
            return
        }
        if let external {
            viaExternalProxy = true
            session?.ruleNotes.append("本机 HTTP 上游 · \(external.label)")
            publish()
        }
        ownedRouteID = route?.id
        let parameters = route?.originParameters() ?? NWParameters.tcp
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(external?.host ?? destination.host), port: port, using: parameters)
        upstream = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.ending else { return }
            switch state {
            case .ready:
                self.touch()
                if let route {
                    self.prepareOwnedTLS(route, origin: connection, remainder: remainder, clientEOF: clientEOF)
                } else if self.session?.isTunnel == true, external != nil {
                    self.negotiateExternalTunnel(connection, target: destination, remainder: remainder, clientEOF: clientEOF)
                } else if self.session?.isTunnel == true {
                    self.beginTunnel(connection, remainder: remainder, clientEOF: clientEOF)
                } else {
                    self.sendRequest(destination.outboundHead, to: connection, remainder: remainder, clientEOF: clientEOF)
                }
            case let .failed(error), let .waiting(error):
                if !self.isRelayingTunnel {
                    let detail = external != nil ? "无法连接所选本机 HTTP 上游。" : (route == nil ? "无法连接目标服务器。" : "无法验证或连接自有 HTTPS 源站，请核对域名、系统信任及叶证书。")
                    self.fail(.upstream(detail + error.localizedDescription))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendRequest(_ head: Data, to connection: NWConnection, remainder: Data, clientEOF: Bool) {
        send(head, to: connection) {
            self.receiveResponse()
            self.forwardRequestBody(remainder, eof: clientEOF)
        }
    }

    // CONNECT starts on plain TCP. Pass the encrypted bytes to a one-connection
    // TLS listener only after the real origin has proved possession of this
    // identity. The inner HTTP request reuses that same verified origin socket.
    private func prepareOwnedTLS(_ route: OwnedHTTPSRoute, origin: NWConnection, remainder: Data, clientEOF: Bool) {
        pendingOrigin = origin
        origin.stateUpdateHandler = nil
        let parameters = route.serverParameters()
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do {
            let listener = try NWListener(using: parameters)
            localTLSListener = listener
            // Accept and outbound ready callbacks can arrive in either order.
            // Admit only the peer port belonging to this specific relay socket.
            let matchRelay = { [weak self, weak listener] in
                guard let self, !self.ending, let listener, let origin = self.pendingOrigin,
                      let relay = self.upstream, relay !== origin, case .ready = relay.state else { return }
                guard case let .hostPort(.ipv4(address), port) = relay.currentPath?.localEndpoint,
                      address == .loopback else {
                    self.fail(.upstream("无法确认本机 TLS 通道的端点。"))
                    return
                }
                let candidates = self.localTLSCandidates
                self.localTLSCandidates.removeAll()
                var accepted: NWConnection?
                for candidate in candidates {
                    if case let .hostPort(.ipv4(peer), sourcePort) = candidate.endpoint,
                       peer == address, sourcePort == port, accepted == nil {
                        accepted = candidate
                    } else {
                        candidate.cancel()
                    }
                }
                guard let accepted else { return }
                self.pendingOrigin = nil
                self.localTLSListener = nil
                listener.cancel()
                self.onDecryptedClient(accepted, VerifiedHTTPSOrigin(processLookup: self.processLookup, route: route, connection: origin))
                self.session?.ruleNotes.append("自有服务 HTTPS · 已验证源站身份")
                self.beginTunnel(relay, remainder: remainder, clientEOF: clientEOF)
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, !self.ending, self.pendingOrigin != nil, let port = listener?.port,
                      self.localTLSCandidates.count < 128, Self.isOwnLoopbackConnection(connection, port: port.rawValue) else {
                    connection.cancel()
                    return
                }
                self.localTLSCandidates.append(connection)
                matchRelay()
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, !self.ending, let listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { self.fail(.upstream("无法建立本机 TLS 通道。")); return }
                    let local = NWParameters.tcp
                    local.preferNoProxies = true
                    let relay = NWConnection(host: "127.0.0.1", port: port, using: local)
                    self.upstream = relay
                    relay.stateUpdateHandler = { [weak self] state in
                        guard let self, !self.ending else { return }
                        switch state {
                        case .ready:
                            matchRelay()
                        case let .failed(error), let .waiting(error): self.fail(.upstream(error.localizedDescription))
                        default: break
                        }
                    }
                    relay.start(queue: self.queue)
                case let .failed(error), let .waiting(error): self.fail(.upstream(error.localizedDescription))
                default: break
                }
            }
            listener.start(queue: queue)
        } catch {
            fail(.upstream("无法创建本机 TLS 通道。\(error.localizedDescription)"))
        }
    }

    private func forwardRequestBody(_ data: Data, eof: Bool) {
        guard !ending, !requestBody.isComplete, let upstream else { return }
        do {
            let used = try requestBody.consume(data)
            if eof, !requestBody.endOfStream() { throw ProxyFailure.badRequest }
            let continueReading = { [weak self] in
                guard let self, !self.ending, !self.requestBody.isComplete else { return }
                self.client.receive(minimumIncompleteLength: 1, maximumLength: HTTPHeaderBlock.limit) { [weak self] data, _, complete, error in
                    guard let self, !self.ending else { return }
                    if let error {
                        self.fail(.upstream("客户端连接已中断。\(error.localizedDescription)"))
                        return
                    }
                    self.touch()
                    self.forwardRequestBody(data ?? Data(), eof: complete)
                }
            }
            if used == 0 {
                continueReading()
            } else {
                send(Data(data.prefix(used)), to: upstream, then: continueReading)
            }
        } catch {
            fail(.badRequest)
        }
    }

    private func receiveResponse() {
        guard !ending, let upstream else { return }
        upstream.receive(minimumIncompleteLength: 1, maximumLength: HTTPHeaderBlock.limit) { [weak self] data, _, complete, error in
            guard let self, !self.ending else { return }
            if let error {
                self.fail(.upstream("读取服务器响应失败。\(error.localizedDescription)"))
                return
            }
            self.touch()
            if self.responseStarted {
                self.forwardResponseBody(data ?? Data(), eof: complete)
            } else {
                if let data { self.responseHead.append(data) }
                self.processResponseHead(eof: complete)
            }
        }
    }

    private func processResponseHead(eof: Bool) {
        guard let separator = responseHead.range(of: HTTPHeaderBlock.delimiter) else {
            if responseHead.count > HTTPHeaderBlock.limit || eof {
                fail(.upstream("服务器未返回完整的 HTTP 响应头。"))
            } else {
                receiveResponse()
            }
            return
        }
        guard separator.lowerBound <= HTTPHeaderBlock.limit else {
            fail(.upstream("服务器响应头超出大小限制。"))
            return
        }

        do {
            let block = try HTTPHeaderBlock(Data(responseHead[..<separator.lowerBound]))
            let parts = block.startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(String(parts[0])),
                  parts[1].count == 3, let status = Int(parts[1]), (100...599).contains(status) else {
                throw ProxyFailure.badRequest
            }
            if viaExternalProxy && status == 407 {
                fail(.upstream("所选本机 HTTP 上游要求认证。请改用无需认证的本机代理。"))
                return
            }
            if status == 101 { throw ProxyFailure.upgrade }
            var headers = block.forwardedFields()
            let remainder = Data(responseHead[separator.upperBound...])
            if status < 200 {
                responseHead = remainder
                headers = forwardRules?.responseFields(headers) ?? headers
                send(HTTPHeaderBlock.serialized(block.startLine, headers), to: client) { [weak self] in
                    self?.processResponseHead(eof: eof)
                }
                return
            }

            responseHead.removeAll()
            let mode = try block.bodyMode(response: true)
            let noBody = session?.method == "HEAD" || status == 204 || status == 304
            responseBody = HTTPBody(noBody ? .complete : mode)
            session?.responseHeaders = forwardRules?.responseFields(block.capturedFields) ?? block.capturedFields
            session?.statusCode = status
            session?.responseHTTPVersion = String(parts[0])
            session?.responseStatusText = parts.count > 2 ? String(parts[2]) : ""
            publish()
            headers = forwardRules?.responseFields(headers) ?? headers
            headers.append(CaptureHeader(name: "Connection", value: "close"))
            let headFields = headers
            let forward = { [weak self] (edit: CaptureHeader?) in
                guard let self, !self.ending else { return }
                var outgoing = headFields
                if let edit {
                    outgoing = HTTPHeaderBlock.rewritingDebugFields(outgoing, with: [edit])
                    if let original = self.session?.responseHeaders {
                        self.session?.responseHeaders = HTTPHeaderBlock.rewritingDebugFields(original, with: [edit])
                    }
                }
                let head = HTTPHeaderBlock.serialized(block.startLine, outgoing)
                self.responseStarted = true
                self.send(head, to: self.client) { [weak self] in self?.forwardResponseBody(remainder, eof: eof) }
            }
            if currentTrafficOptions().shouldPause(session, phase: .response) {
                pausedResponse = forward
                pause(at: .response)
            } else {
                forward(nil)
            }
        } catch {
            fail(.upstream("服务器返回了无效或暂不支持的 HTTP 响应。"))
        }
    }

    private func forwardResponseBody(_ data: Data, eof: Bool) {
        do {
            let used = try responseBody.consume(data)
            let prematureEnd = eof && !responseBody.endOfStream()
            let next = { [weak self] in
                guard let self else { return }
                if prematureEnd {
                    self.finish("服务器连接在响应完成前关闭。")
                } else if self.responseBody.isComplete {
                    self.finish()
                } else {
                    self.receiveResponse()
                }
            }
            if used == 0 {
                next()
            } else {
                send(Data(data.prefix(used)), to: client, then: next)
            }
        } catch {
            finish("服务器返回了无效的 HTTP 响应正文。")
        }
    }

    private func negotiateExternalTunnel(_ connection: NWConnection, target: HTTPUpstream, remainder: Data, clientEOF: Bool) {
        let hostname = target.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let authority = hostname.contains(":") ? "[\(hostname)]:\(target.port)" : "\(hostname):\(target.port)"
        let head = HTTPHeaderBlock.serialized("CONNECT \(authority) HTTP/1.1", [CaptureHeader(name: "Host", value: authority)])
        // Only the target authority is part of the upstream proxy negotiation.
        send(head, to: connection) { [weak self] in
            self?.readExternalHandshake(connection, accumulated: Data(), remainder: remainder, clientEOF: clientEOF)
        }
    }

    private func readExternalHandshake(_ connection: NWConnection, accumulated: Data, remainder: Data, clientEOF: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPHeaderBlock.limit) { [weak self] data, _, eof, error in
            guard let self, !self.ending else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard error == nil else { self.fail(.upstream("读取本机 HTTP 上游的隧道响应失败。")); return }
            while let separator = buffer.range(of: HTTPHeaderBlock.delimiter) {
                guard separator.lowerBound - buffer.startIndex <= HTTPHeaderBlock.limit,
                      let block = try? HTTPHeaderBlock(Data(buffer[..<separator.lowerBound])) else {
                    self.fail(.upstream("本机 HTTP 上游返回了无效的隧道响应。")); return
                }
                let parts = block.startLine.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2, parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0",
                      parts[1].count == 3, let status = Int(parts[1]), (100...599).contains(status) else {
                    self.fail(.upstream("本机 HTTP 上游返回了无效状态。")); return
                }
                buffer = Data(buffer[separator.upperBound...])
                if status < 200 && status != 101 { continue }
                guard (200..<300).contains(status) else {
                    let message = status == 407 ? "所选本机 HTTP 上游要求认证。请改用无需认证的本机代理。" : "本机 HTTP 上游拒绝隧道连接（HTTP \(status)）。"
                    self.fail(.upstream(message)); return
                }
                self.beginTunnel(connection, remainder: remainder, clientEOF: clientEOF,
                                 downstream: buffer, upstreamEOF: eof)
                return
            }
            if eof || buffer.count > HTTPHeaderBlock.limit {
                self.fail(.upstream("本机 HTTP 上游返回的隧道响应不完整。"))
            } else {
                self.readExternalHandshake(connection, accumulated: buffer, remainder: remainder, clientEOF: clientEOF)
            }
        }
    }

    private func beginTunnel(_ connection: NWConnection, remainder: Data, clientEOF: Bool,
                             downstream: Data = Data(), upstreamEOF: Bool = false) {
        responseStarted = true
        session?.statusCode = 200
        session?.responseHTTPVersion = "HTTP/1.1"
        session?.responseStatusText = "Connection Established"
        publish()
        let head = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        send(head, to: client) { [weak self] in
            guard let self else { return }
            self.forwardTunnelData(downstream, eof: upstreamEOF, from: connection, to: self.client, countBytes: true)
            self.forwardTunnelData(remainder, eof: clientEOF, from: self.client, to: connection, countBytes: false)
        }
    }

    private func pumpTunnel(from source: NWConnection, to destination: NWConnection, countBytes: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: HTTPHeaderBlock.limit) { [weak self] data, _, complete, error in
            guard let self, !self.ending else { return }
            if let error {
                self.finish(error.localizedDescription)
            } else {
                self.touch()
                self.forwardTunnelData(data ?? Data(), eof: complete, from: source, to: destination, countBytes: countBytes)
            }
        }
    }

    private func forwardTunnelData(_ data: Data, eof: Bool, from source: NWConnection, to destination: NWConnection, countBytes: Bool) {
        if !data.isEmpty { recordTunnelBytes(data.count, downloaded: countBytes) }
        if eof {
            let endWriting: () -> Void = { [weak self] in
                self?.send(Data(), to: destination, final: true) { [weak self] in
                    guard let self else { return }
                    self.tunnelDirectionsEnded += 1
                    if self.tunnelDirectionsEnded == 2 { self.finish() }
                }
            }
            if data.isEmpty {
                endWriting()
            } else {
                send(data, to: destination, then: endWriting)
            }
        } else if data.isEmpty {
            pumpTunnel(from: source, to: destination, countBytes: countBytes)
        } else {
            send(data, to: destination) { [weak self] in
                self?.pumpTunnel(from: source, to: destination, countBytes: countBytes)
            }
        }
    }

    // State failures can arrive before receive callbacks drain an established TCP tunnel.
    private var isRelayingTunnel: Bool { session?.isTunnel == true && responseStarted }

    private func recordTunnelBytes(_ bytes: Int, downloaded: Bool) {
        if downloaded {
            tunnelBytes += bytes
        } else {
            tunnelUploadBytes += bytes
        }
        session?.tunnelActivity = downloaded ? .download : .upload
        guard !tunnelProgressPending else { return }
        tunnelProgressPending = true
        queue.asyncAfter(deadline: .now() + .milliseconds(125)) { [weak self] in
            guard let self, !self.ending else { return }
            self.tunnelProgressPending = false
            self.publish()
        }
    }

    private func send(_ data: Data, to connection: NWConnection, final: Bool = false, then: @escaping () -> Void) {
        let transfer = { [weak self, weak connection] in
            guard let self, !self.ending, let connection else { return }
            self.deliver(data, to: connection, final: final, then: then)
        }
        let options = currentTrafficOptions()
        if options.throttleEnabled, !data.isEmpty {
            let downloading = connection === client
            let didApplyLatency = downloading ? appliedDownloadLatency : appliedUploadLatency
            if downloading { appliedDownloadLatency = true } else { appliedUploadLatency = true }
            let delay = Double(data.count) / options.bandwidthBytesPerSecond + (didApplyLatency ? 0 : options.latency)
            queue.asyncAfter(deadline: .now() + delay) { transfer() }
        } else {
            transfer()
        }
    }

    private func deliver(_ data: Data, to connection: NWConnection, final: Bool, then: @escaping () -> Void) {
        connection.send(content: final && data.isEmpty ? nil : data,
                        contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, !self.ending else { return }
            if let error {
                self.finish(error.localizedDescription)
            } else {
                self.touch()
                then()
            }
        })
    }

    private func fail(_ failure: ProxyFailure) {
        guard !ending else { return }
        if responseStarted {
            finish(failure.message)
            return
        }
        let body = Data(failure.message.utf8)
        let headers = failure.additionalHeaders + [
            CaptureHeader(name: "Content-Type", value: "text/plain; charset=utf-8"),
            CaptureHeader(name: "Content-Length", value: String(body.count)),
            CaptureHeader(name: "Connection", value: "close")
        ]
        respond(status: failure.status, reason: failure.reason, headers: headers, body: body, error: failure.message)
    }

    private func respond(status: Int, reason: String, headers: [CaptureHeader], body: Data, error: String? = nil) {
        ending = true
        timer?.cancel()
        upstream?.cancel()
        session?.statusCode = status
        session?.responseHeaders = headers
        session?.responseHTTPVersion = "HTTP/1.1"
        session?.responseStatusText = reason
        let payload = session?.method == "HEAD" ? Data() : body
        responseBody = HTTPBody(payload.isEmpty ? .complete : .length(payload.count))
        _ = try? responseBody.consume(payload)
        let head = HTTPHeaderBlock.serialized("HTTP/1.1 \(status) \(reason)", headers)
        client.send(content: head + payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] sendError in
            self?.finish(error ?? sendError?.localizedDescription)
        })
    }

    private func publish() {
        guard var session else { return }
        session.clientProcessChecked = processLookup != nil ? true : nil
        session.clientProcess = processLookup?.result
        session.requestBody = requestBody.capture
        session.requestBodyBytes = requestBody.isComplete ? requestBody.count : nil
        session.responseBody = responseBody.capture
        session.responseBytes = session.isTunnel && responseStarted ? tunnelBytes : responseBody.count
        if session.isTunnel, responseStarted { session.tunnelUploadBytes = tunnelUploadBytes }
        onSession(session)
    }

    private func finish(_ error: String? = nil) {
        guard !closed else { return }
        ending = true
        closed = true
        if isPaused { session?.isPausedAtBreakpoint = false }
        pausedRequest = nil
        pausedResponse = nil
        timer?.cancel()
        timer = nil
        localTLSListener?.cancel()
        localTLSCandidates.forEach { $0.cancel() }
        localTLSCandidates.removeAll()
        pendingOrigin?.cancel()
        verified?.connection.cancel()
        upstream?.cancel()
        client.cancel()
        session?.elapsed = Date().timeIntervalSince(startedAt)
        session?.error = error
        session?.finished = true
        publish()
        onClose()
    }
}
