import AppKit
import Network
import SwiftUI

enum SessionMenuAction {
    case copyURL, copyCommand, copyResponse, saveResponse, export, find, validate, viewerMappings
    case inspect(SessionInspectorSelection), reveal, filterToHost, hideHost, terminate, clear, clearOthers
    case rule(ProxyToolKind), sort(SessionOrdering)
}

enum SessionOrdering: String, CaseIterable {
    case newest, oldest, status, duration

    var title: String {
        switch self {
        case .newest: "最新在前"
        case .oldest: "最早在前"
        case .status: "状态码"
        case .duration: "耗时"
        }
    }
}

struct SessionContextMenu: View {
    let session: CaptureSession
    let presentation: SessionListPresentation
    let ordering: SessionOrdering
    let isLive: Bool
    let canTerminate: Bool
    @ObservedObject var store: CaptureStore
    let perform: (SessionMenuAction) -> Void

    var body: some View {
        Button("复制 URL") { perform(.copyURL) }
        if session.localCurlCommand != nil {
            Button("复制本机请求的 cURL") { perform(.copyCommand) }
        }
        if !session.isTunnel {
            Button("复制响应预览") { perform(.copyResponse) }.disabled(session.responseBody.isEmpty)
            Button("保存响应预览…") { perform(.saveResponse) }.disabled(session.responseBody.isEmpty)
        }
        Button("在会话中查找…") { perform(.find) }
        Button("导出此会话…") { perform(.export) }
        if !session.isTunnel {
            Button("校验 JSON 响应…") { perform(.validate) }
                .disabled(session.responseBody.isEmpty)
        }

        Divider()
        Button("编写本机请求…") { store.localRequestDraft = LocalRequestDraft(session: session, mode: .compose) }
            .disabled(LocalRequestDraft(session: session, mode: .compose) == nil)
        Button("新建本机请求…") { store.localRequestDraft = LocalRequestDraft() }
        Button("重复本机请求…") { store.localRequestDraft = LocalRequestDraft(session: session, mode: .repeatRequest) }
            .disabled(LocalRequestDraft(session: session, mode: .repeatRequest) == nil)
        Divider()
        Button("查看概览") { perform(.inspect(.overview)) }
        Button("查看标头") { perform(.inspect(.headers)) }
        if !session.isTunnel {
            Menu("查看请求正文为") {
                inspectionFormats(response: false)
            }
            Menu("查看响应正文为") {
                inspectionFormats(response: true)
            }
        }
        Button("查看器映射…") { perform(.viewerMappings) }
        Button(presentation == .structure ? "在时序视图中显示" : "在结构视图中显示") { perform(.reveal) }

        Divider()
        Menu("排序方式") {
            ForEach(SessionOrdering.allCases, id: \.self) { item in
                Button { perform(.sort(item)) } label: {
                    if item == ordering { Label(item.title, systemImage: "checkmark") }
                    else { Text(item.title) }
                }
            }
        }
        Button("只看此主机") { perform(.filterToHost) }
        Button("隐藏此主机") { perform(.hideHost) }
        Divider()
        HostActionsMenu(store: store, host: session.host, location: RecordingLocation(session: session))
        if canTerminate { Button("终止此连接") { perform(.terminate) } }

        Divider()
        LocationDebugActions(store: store, url: session.url, allPaths: session.isTunnel)
        if session.device == .mac || session.clientProcessChecked == true {
            Menu("客户端进程") {
                if session.clientProcessChecked == true {
                    Text(session.clientProcess?.label ?? "未知")
                }
                Toggle("识别新的本机连接", isOn: Binding(get: { store.collectClientProcess }, set: store.setClientProcessCollection))
            }
        }
        Menu("创建规则") {
            Button("加入黑名单…") { perform(.rule(.blockList)) }
            Button("加入白名单…") { perform(.rule(.allowList)) }
            if session.supportsHTTPDebugRule {
                Divider()
                ForEach([ProxyToolKind.noCaching, .blockCookies, .mapRemote, .mapLocal, .rewrite]) { kind in
                    Button("\(kind.title)…") { perform(.rule(kind)) }
                }
            }
        }
        if isLive {
            Divider()
            Button("清除此会话", role: .destructive) { perform(.clear) }
            Button("清除其他会话", role: .destructive) { perform(.clearOthers) }
        }
    }

    @ViewBuilder
    private func inspectionFormats(response: Bool) -> some View {
        Button("自动") { perform(.inspect(response ? .response(.automatic) : .request(.automatic))) }
        Button("格式化 JSON") { perform(.inspect(response ? .response(.formatted) : .request(.formatted))) }
        Button("原始文本") { perform(.inspect(response ? .response(.raw) : .request(.raw))) }
        Button("十六进制") { perform(.inspect(response ? .response(.hexadecimal) : .request(.hexadecimal))) }
    }
}

struct LocationDebugActions: View {
    let store: CaptureStore
    let url: String
    let allPaths: Bool

    var body: some View {
        HTTPSContextActions(url: url, settings: store.ownedHTTPS) { store.openHTTPS(for: url) }
        if let location = BreakpointLocation(url: url, includeAllPaths: allPaths) {
            let exists = store.trafficOptions.breakpointLocations?.contains { $0.sameLocation(as: location) } == true
            Button(exists ? "移除此断点" : "添加断点") { store.setBreakpoint(location, enabled: !exists) }
            Button("断点设置…") { store.presentedProxySettings = .breakpoints }
        }
    }
}

extension CaptureSession {
    var pathForRule: String {
        let path = URLComponents(string: url)?.percentEncodedPath ?? "/"
        return path.isEmpty ? "/" : path
    }

    var supportsHTTPDebugRule: Bool {
        !isTunnel && ProxyRule(kind: .noCaching, host: host, path: pathForRule).validationError == nil
    }

    var localCurlCommand: String? {
        guard !isTunnel, let parsed = URLComponents(string: url), parsed.scheme?.lowercased() == "http",
              parsed.user == nil, parsed.password == nil, parsed.fragment == nil,
              let value = parsed.host?.lowercased(), !method.isEmpty,
              method.utf8.allSatisfy({ (65...90).contains($0) || $0 == 45 }) else { return nil }

        let address = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let isNumericLoopback = IPv4Address(address)?.rawValue.first == 127 || IPv6Address(address) == .loopback
        guard address == "localhost" || isNumericLoopback else { return nil }
        let length = requestBodyBytes ?? requestHeaders.first { $0.name.lowercased() == "content-length" }.flatMap { Int($0.value) }
        let hasFraming = requestHeaders.contains { $0.name.lowercased() == "transfer-encoding" }
        guard length.map({ $0 == requestBody.count }) ?? (!hasFraming && requestBody.isEmpty),
              let body = String(data: requestBody, encoding: .utf8), !body.contains("\0") else { return nil }

        var parts = ["curl", "--globoff", "--noproxy", "'*'", "--request", Self.shellQuote(method)]
        if address == "localhost" {
            parts += ["--resolve", Self.shellQuote("localhost:\(parsed.port ?? 80):127.0.0.1")]
        }
        let ignoredHeaders: Set<String> = [
            "authorization", "cookie", "proxy-authorization", "proxy-connection", "host",
            "connection", "content-length", "transfer-encoding", "expect"
        ]
        for header in requestHeaders where !ignoredHeaders.contains(header.name.lowercased()) {
            guard !header.name.isEmpty, !header.name.contains(":"), !header.name.contains("\r"), !header.name.contains("\n"),
                  !header.value.contains("\0"), !header.value.contains("\r"), !header.value.contains("\n") else { continue }
            parts += ["--header", Self.shellQuote("\(header.name): \(header.value)")]
        }
        if !body.isEmpty { parts += ["--data-raw", Self.shellQuote(body)] }
        parts += ["--", Self.shellQuote(url)]
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
