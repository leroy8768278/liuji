import Foundation
import Network

enum ProxyToolKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case noCaching, blockCookies
    case mapRemote, mapLocal, rewrite, dnsOverride, blockList, allowList

    var id: Self { self }

    var title: String {
        switch self {
        case .noCaching: "禁用缓存"
        case .blockCookies: "阻止 Cookie"
        case .mapRemote: "远程映射"
        case .mapLocal: "本地映射"
        case .rewrite: "改写"
        case .dnsOverride: "域名覆盖"
        case .blockList: "黑名单"
        case .allowList: "白名单"
        }
    }

    var icon: String {
        switch self {
        case .noCaching: "externaldrive.badge.xmark"
        case .blockCookies: "lock.shield"
        case .mapRemote: "arrow.triangle.branch"
        case .mapLocal: "doc"
        case .rewrite: "pencil.line"
        case .dnsOverride: "globe"
        case .blockList: "hand.raised"
        case .allowList: "checkmark.shield"
        }
    }

    var description: String {
        switch self {
        case .noCaching: "为匹配的本机 HTTP 请求停用缓存，便于检查后端的实际响应。"
        case .blockCookies: "移除匹配的本机 HTTP 请求和响应中的 Cookie 标头。"
        case .mapRemote: "将匹配的本机 HTTP 开发地址转发到另一个本机后端。"
        case .mapLocal: "用选定的本地文件回答匹配的 GET 和 HEAD 请求。"
        case .rewrite: "修改本机 HTTP 请求的路径，或设置请求或响应的 X-Debug- 标头。"
        case .dnsOverride: "将开发域名连接到 127.0.0.1，保留原始主机名和端口。"
        case .blockList: "拒绝匹配主机的 HTTP 请求和 HTTPS 隧道。"
        case .allowList: "启用后，仅允许匹配主机的 HTTP 请求和 HTTPS 隧道。"
        }
    }
}

enum ProxyRewriteField: String, CaseIterable, Codable, Identifiable, Sendable {
    case path, requestHeader, responseHeader

    var id: Self { self }

    var title: String {
        switch self {
        case .path: "请求路径"
        case .requestHeader: "请求标头"
        case .responseHeader: "响应标头"
        }
    }
}

struct ProxyRule: Identifiable, Codable, Sendable {
    var id = UUID()
    var kind: ProxyToolKind
    var isEnabled = true
    var host = ""
    var path = ""
    var value = ""
    var rewriteField: ProxyRewriteField = .path
    var headerName = ""

    private var normalizedHost: String { RuleLocation.normalizedHost(host) }

    var validationError: String? {
        if kind == .allowList || kind == .blockList {
            let wildcard = normalizedHost.hasPrefix("*.")
            let pattern = wildcard ? String(normalizedHost.dropFirst(2)) : normalizedHost
            let isValid = RuleLocation.isHostname(pattern) && (!wildcard || !pattern.contains(":"))
            return isValid ? nil : "输入主机名或 *.example.test 形式的子域名通配符。"
        }

        if kind == .dnsOverride {
            guard RuleLocation.isDevelopmentAlias(normalizedHost) else { return "输入以 .test 或 .localhost 结尾的开发域名。" }
            return value == "127.0.0.1" ? nil : "域名覆盖使用 127.0.0.1。"
        }

        guard RuleLocation.loopbackAddress(normalizedHost) != nil || RuleLocation.isDevelopmentAlias(normalizedHost) else {
            return "输入 localhost、回环 IP 或以 .test、.localhost 结尾的开发域名。"
        }
        guard RuleLocation.isPath(path, prefixAllowed: kind != .mapLocal) else {
            return kind == .mapLocal ? "输入以 / 开头的完整请求路径。" : "输入以 / 开头的路径，或使用 /* 匹配路径前缀。"
        }

        switch kind {
        case .mapRemote:
            return RuleLocation.remoteTarget(value) == nil ? "输入本机 HTTP 目标，例如 http://127.0.0.1:8080/api。" : nil
        case .mapLocal:
            return value.hasPrefix("/") && !value.contains("\0") ? nil : "请选择本地文件。"
        case .rewrite:
            if rewriteField == .path {
                return RuleLocation.isPath(value, prefixAllowed: false) ? nil : "输入以 / 开头的替换路径。"
            }
            let prefix = "x-debug-"
            guard headerName.lowercased().hasPrefix(prefix), headerName.count > prefix.count,
                  headerName.utf8.allSatisfy({ RuleLocation.headerToken.contains($0) }) else {
                return "输入以 X-Debug- 开头的有效标头名。"
            }
            return value.utf8.allSatisfy({ (32...126).contains($0) }) ? nil : "标头值需使用单行 ASCII 文本。"
        default:
            return nil
        }
    }

    fileprivate func matches(host: String) -> Bool {
        if normalizedHost.hasPrefix("*.") {
            return host.hasSuffix(String(normalizedHost.dropFirst()))
        }
        return normalizedHost == host
    }

    fileprivate func matches(path requestPath: String) -> Bool {
        if path.hasSuffix("/*") { return requestPath.hasPrefix(path.dropLast()) }
        return requestPath == path
    }
}

struct ProxyRuleSet: Codable, Sendable {
    var rules: [ProxyRule] = []
    var allowListEnabled = false

    func decide(host: String, path: String, query: String?, method: String, isTunnel: Bool) -> ProxyRuleDecision {
        let host = RuleLocation.normalizedHost(host)
        let path = path.isEmpty ? "/" : path
        let matching = rules.filter { $0.isEnabled && $0.matches(host: host) && $0.validationError == nil }

        if matching.contains(where: { $0.kind == .blockList }) {
            return .blocked("连接已被黑名单拦截。")
        }
        if allowListEnabled && !matching.contains(where: { $0.kind == .allowList }) {
            return .blocked("主机未列入启用的白名单。")
        }
        guard !isTunnel else { return .forward(ProxyForwardRules()) }

        let pathRules = matching.filter { $0.matches(path: path) }
        if method == "GET" || method == "HEAD", let mapping = pathRules.first(where: { $0.kind == .mapLocal }) {
            return .localFile(URL(fileURLWithPath: mapping.value))
        }

        var forward = ProxyForwardRules()
        if let mapping = pathRules.first(where: { $0.kind == .mapRemote }),
           var target = RuleLocation.remoteTarget(mapping.value),
           let targetHost = target.host, let address = RuleLocation.loopbackAddress(RuleLocation.normalizedHost(targetHost)) {
            if target.percentEncodedPath.isEmpty {
                target.percentEncodedPath = path
            } else if mapping.path.hasSuffix("/*") {
                let suffix = path.dropFirst(mapping.path.count - 1)
                if !suffix.isEmpty {
                    let separator = target.percentEncodedPath.hasSuffix("/") ? "" : "/"
                    target.percentEncodedPath += separator + suffix
                }
            }
            target.percentEncodedQuery = query
            forward.remoteURL = target.url
            forward.connectHost = address
            forward.notes.append("远程映射至 \(target.host ?? address)\(target.port.map { ":\($0)" } ?? "")\(target.percentEncodedPath)")
        } else if matching.contains(where: { $0.kind == .dnsOverride }) {
            forward.connectHost = "127.0.0.1"
            forward.notes.append("域名覆盖至 127.0.0.1")
        }

        let noCaching = pathRules.contains { $0.kind == .noCaching }
        let blockCookies = pathRules.contains { $0.kind == .blockCookies }
        let rewrites = pathRules.filter { $0.kind == .rewrite }
        if noCaching || blockCookies || !rewrites.isEmpty,
           let address = forward.connectHost ?? RuleLocation.loopbackAddress(host) {
            forward.connectHost = address
            forward.noCaching = noCaching
            forward.blockCookies = blockCookies
            if noCaching { forward.notes.append("禁用缓存") }
            if blockCookies { forward.notes.append("阻止 Cookie") }
            for rule in rewrites { forward.apply(rule) }
        }
        return .forward(forward)
    }
}

enum ProxyRuleDecision: Sendable {
    case blocked(String)
    case localFile(URL)
    case forward(ProxyForwardRules)
}

struct ProxyForwardRules: Sendable {
    var remoteURL: URL?
    var connectHost: String?
    var noCaching = false
    var blockCookies = false
    var replacementPath: String?
    var requestHeaders: [CaptureHeader] = []
    var responseHeaders: [CaptureHeader] = []
    var notes: [String] = []

    fileprivate mutating func apply(_ rule: ProxyRule) {
        switch rule.rewriteField {
        case .path:
            replacementPath = rule.value
            notes.append("请求路径改写为 \(rule.value)")
        case .requestHeader:
            Self.setHeader(rule, in: &requestHeaders)
            notes.append("设置请求标头 \(rule.headerName)")
        case .responseHeader:
            Self.setHeader(rule, in: &responseHeaders)
            notes.append("设置响应标头 \(rule.headerName)")
        }
    }

    private static func setHeader(_ rule: ProxyRule, in headers: inout [CaptureHeader]) {
        headers.removeAll { $0.name.caseInsensitiveCompare(rule.headerName) == .orderedSame }
        headers.append(CaptureHeader(name: rule.headerName, value: rule.value))
    }
}

enum RuleLocation {
    static let headerToken = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&'*+-.^_`|~".utf8)

    static func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        if let address = IPv6Address(value) { return address.debugDescription }
        return value
    }

    static func isHostname(_ host: String) -> Bool {
        if IPv6Address(host) != nil { return true }
        return !host.isEmpty && host.utf8.count <= 253 && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.count <= 63 && part.first != "-" && part.last != "-" &&
                part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    static func loopbackAddress(_ host: String) -> String? {
        if host == "localhost" { return "127.0.0.1" }
        if host == "::1" { return host }
        guard let address = IPv4Address(host), address.rawValue.first == 127 else { return nil }
        return host
    }

    static func isDevelopmentAlias(_ host: String) -> Bool {
        (host.hasSuffix(".test") || host.hasSuffix(".localhost")) && isHostname(host)
    }

    static func isPath(_ path: String, prefixAllowed: Bool) -> Bool {
        let path = prefixAllowed && path.hasSuffix("/*") ? String(path.dropLast()) : path
        guard path.hasPrefix("/"), !path.contains("*"), !path.contains("?"), !path.contains("#"),
              let components = URLComponents(string: "http://localhost" + path) else { return false }
        return components.percentEncodedPath == path
    }

    static func remoteTarget(_ value: String) -> URLComponents? {
        guard let target = URLComponents(string: value), target.scheme?.lowercased() == "http",
              let host = target.host, loopbackAddress(normalizedHost(host)) != nil,
              target.user == nil, target.password == nil, target.fragment == nil, target.query == nil,
              target.rangeOfPort == nil || (target.port.map { (1...65_535).contains($0) } == true) else { return nil }
        return target
    }
}
