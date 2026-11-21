import Foundation
import Network

enum LocalRequestMode {
    case new, compose, repeatRequest
    var title: String {
        switch self {
        case .new: "新建本机请求"
        case .compose: "编写本机请求"
        case .repeatRequest: "重复本机请求"
        }
    }
}

struct LocalRequestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct LocalRequestDraft: Identifiable {
    static let methods = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    let id = UUID()
    let mode: LocalRequestMode
    var method = "GET"
    var url = "http://127.0.0.1:8080/"
    var headers = ""
    var body = ""

    init() { mode = .new }

    init?(session: CaptureSession, mode: LocalRequestMode) {
        guard !session.isTunnel, Self.methods.contains(session.method), session.finished,
              (try? Self.loopbackURL(session.url)) != nil,
              session.requestHeaders.allSatisfy({ $0.name.caseInsensitiveCompare("Content-Encoding") != .orderedSame || $0.value.lowercased() == "identity" }),
              let text = String(data: session.requestBody, encoding: .utf8), !text.contains("\0") else { return nil }
        let framing = session.requestHeaders.first { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
        let length = session.requestBodyBytes ?? framing.flatMap { Int($0.value) }
        guard length == session.requestBody.count ||
                (length == nil && framing == nil && session.requestBody.isEmpty &&
                 !session.requestHeaders.contains(where: { $0.name.lowercased() == "transfer-encoding" })) else { return nil }
        self.mode = mode
        method = session.method
        url = session.url
        body = text
        headers = session.requestHeaders.compactMap { header in
            guard Self.allowedHeader(header.name), Self.allowedValue(header.value) else { return nil }
            return "\(header.name): \(header.value)"
        }.joined(separator: "\n")
    }

    static func loopbackURL(_ text: String) throws -> URL {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= 8192, !input.contains("\\"), !input.utf8.contains(where: { $0 < 33 || $0 == 127 }),
              var parts = URLComponents(string: input), parts.scheme?.lowercased() == "http",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let host = parts.url?.host?.lowercased(), let port = UInt16(exactly: parts.port ?? 80), port > 0 else {
            throw LocalRequestError("请输入含有效端口的本机 HTTP 地址。")
        }
        if host == "localhost" {
            parts.host = "127.0.0.1"
        } else if let address = IPv4Address(host), address.rawValue.first == 127 {
            parts.host = address.debugDescription
        } else if IPv6Address(host) == .loopback {
            parts.host = "[::1]"
        } else {
            throw LocalRequestError("目的主机可填写 localhost、127.x.x.x 或 [::1]。")
        }
        guard let url = parts.url else { throw LocalRequestError("HTTP 地址无效。") }
        return url
    }

    private static func allowedHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["accept", "accept-language", "content-type"].contains(lower) ||
            (lower.hasPrefix("x-debug-") && lower.count > 8 && lower.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            })
    }

    private static func allowedValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { (32...126).contains($0) }
    }

    func prepared() throws -> LocalHTTPRequest {
        guard Self.methods.contains(method) else { throw LocalRequestError("不支持此请求方法。") }
        let destination = try Self.loopbackURL(url)
        guard body.utf8.count <= 256 * 1024, !body.contains("\0") else { throw LocalRequestError("正文最多可发送 256 KiB UTF-8 文本。") }
        guard method != "HEAD" || body.isEmpty else { throw LocalRequestError("HEAD 请求应使用空正文。") }
        guard headers.utf8.count <= 16 * 1024 else { throw LocalRequestError("请求头超过 16 KiB。") }
        let authority = destination.host == "::1" ? "[::1]" : (destination.host ?? "")
        let port = destination.port.map { ":\($0)" } ?? ""
        var lines = ["\(method) \(destination.absoluteString) HTTP/1.1", "Host: \(authority)\(port)", "Connection: close"]
        for line in headers.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { throw LocalRequestError("每行请求头应包含名称、冒号和值。") }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard Self.allowedHeader(name), Self.allowedValue(value) else { throw LocalRequestError("可填写 Accept、Accept-Language、Content-Type 和 X-Debug- 请求头，值需为单行 ASCII 文本。") }
            lines.append("\(name): \(value)")
        }
        if !body.isEmpty || ["POST", "PUT", "PATCH"].contains(method) { lines.append("Content-Length: \(body.utf8.count)") }
        let bytes = Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
        return LocalHTTPRequest(destination: destination, data: bytes)
    }
}

struct LocalHTTPRequest {
    let destination: URL
    let data: Data
}

// Connect to the app's own HTTP listener. A 3xx is a captured response and ends this exchange.
@MainActor
final class LocalRequestSender {
    private var connection: NWConnection?
    private var timeout: DispatchWorkItem?
    private var completion: ((Result<Void, Error>) -> Void)?

    func send(_ request: LocalHTTPRequest, via port: UInt16, completion: @escaping (Result<Void, Error>) -> Void) {
        guard connection == nil, let proxyPort = NWEndpoint.Port(rawValue: port), port != 0,
              Int(port) != (request.destination.port ?? 80) else {
            completion(.failure(LocalRequestError("请求目标应与流迹监听端口不同。")))
            return
        }
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        let link = NWConnection(host: .ipv4(.loopback), port: proxyPort, using: parameters)
        self.connection = link
        self.completion = completion
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 75, execute: deadline)
        link.stateUpdateHandler = { [weak self, weak link] state in
            MainActor.assumeIsolated {
                guard let self, let link, self.connection === link else { return }
                self.update(state, link: link, data: request.data)
            }
        }
        link.start(queue: .main)
    }

    private func update(_ state: NWConnection.State, link: NWConnection, data: Data) {
        switch state {
        case .ready:
            link.send(content: data, completion: .contentProcessed { [weak self, weak link] error in
                MainActor.assumeIsolated {
                    guard let self, let link, self.connection === link else { return }
                    if let error { self.finish(.failure(error)) } else { self.drain(link, received: false) }
                }
            })
        case let .failed(error): finish(.failure(error))
        default: break
        }
    }

    private func drain(_ link: NWConnection, received: Bool) {
        link.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self, weak link] data, _, end, error in
            MainActor.assumeIsolated {
                guard let self, let link, self.connection === link else { return }
                let hasResponse = received || data?.isEmpty == false
                if let error { self.finish(.failure(error)) }
                else if end { self.finish(hasResponse ? .success(()) : .failure(URLError(.zeroByteResource))) }
                else { self.drain(link, received: hasResponse) }
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let callback = completion
        completion = nil
        callback?(result)
    }
}
