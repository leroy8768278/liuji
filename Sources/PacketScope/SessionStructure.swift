import Foundation

struct SessionStructure {
    struct Authority: Hashable {
        let scheme: String
        let host: String
        let port: Int?
        let isTunnel: Bool

        var address: String {
            let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            let authority = port.map { "\(name):\($0)" } ?? name
            return !isTunnel && scheme != "http" ? "\(scheme)://\(authority)" : authority
        }

        var recordingOrigin: RecordingLocation? {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = port
            return components.string.flatMap(RecordingLocation.init)
        }
    }

    enum GroupID: Hashable {
        case encrypted
        case otherHosts
        case authority(Authority)
        case route(Authority, [String])
    }

    enum RowID: Hashable {
        case group(GroupID)
        case session(UUID)
    }

    enum Content {
        case group(GroupID, title: String, symbol: String, count: Int)
        case session(CaptureSession, title: String)
    }

    struct Row: Identifiable {
        let id: RowID
        let depth: Int
        let content: Content
    }

    private final class Group {
        let id: GroupID
        let title: String
        let symbol: String
        var childGroups: [GroupID: Group] = [:]
        var sessions: [(session: CaptureSession, title: String)] = []
        var count = 0

        init(id: GroupID, title: String, symbol: String) {
            self.id = id
            self.title = title
            self.symbol = symbol
        }

        func child(_ id: GroupID, title: String, symbol: String) -> Group {
            if let item = childGroups[id] { return item }
            let group = Group(id: id, title: title, symbol: symbol)
            childGroups[id] = group
            return group
        }
    }

    private var roots: [GroupID: Group] = [:]
    private(set) var ancestors: [UUID: [GroupID]] = [:]

    init(_ sessions: [CaptureSession], focusedHosts: Set<String> = []) {
        for session in sessions {
            let components = URLComponents(string: session.url)
            let scheme = components?.scheme?.lowercased() ?? (session.isTunnel ? "https" : "http")
            let parsedPort = components?.port
            let port = session.isTunnel ? (parsedPort ?? 443) : Self.nondefaultPort(parsedPort, scheme: scheme)
            let address = Authority(scheme: scheme, host: components?.host?.lowercased() ?? session.host,
                                    port: port, isTunnel: session.isTunnel)
            let focused = !focusedHosts.isEmpty && CaptureHostLists.host(address.host).map(focusedHosts.contains) == true
            var folder: Group?
            var ancestry: [GroupID] = []
            if !focusedHosts.isEmpty && !focused {
                let other = root(.otherHosts, title: "其他主机", symbol: "folder")
                other.count += 1
                ancestry.append(other.id)
                folder = other
            }
            if session.isTunnel && !focused {
                let encrypted = folder?.child(.encrypted, title: "加密", symbol: "lock")
                    ?? root(.encrypted, title: "加密", symbol: "lock")
                encrypted.count += 1
                ancestry.append(encrypted.id)
                folder = encrypted
            }
            let hostSymbol = session.isTunnel ? "lock" : "globe"
            var parent = folder?.child(.authority(address), title: address.address, symbol: hostSymbol)
                ?? root(.authority(address), title: address.address, symbol: hostSymbol)
            parent.count += 1
            ancestry.append(parent.id)
            if session.isTunnel {
                parent.sessions.append((session, "加密隧道"))
                ancestors[session.id] = ancestry
            } else {
                let path = components?.percentEncodedPath ?? ""
                // Keep the rest in the leaf after eight segments so long URLs stay readable.
                let parts = (path.hasPrefix("/") ? path.dropFirst() : Substring(path))
                    .split(separator: "/", maxSplits: 8, omittingEmptySubsequences: false)
                var prefix: [String] = []
                for segment in parts.dropLast() {
                    prefix.append(String(segment))
                    parent = parent.child(.route(address, prefix), title: "/" + segment, symbol: "folder")
                    parent.count += 1
                    ancestry.append(parent.id)
                }
                let pathEnd = "/" + (parts.last.map(String.init) ?? "")
                let title = components?.percentEncodedQuery.map { "\(pathEnd)?\($0)" } ?? pathEnd
                parent.sessions.append((session, title))
                ancestors[session.id] = ancestry
            }
        }
    }

    private mutating func root(_ id: GroupID, title: String, symbol: String) -> Group {
        if let group = roots[id] { return group }
        let group = Group(id: id, title: title, symbol: symbol)
        roots[id] = group
        return group
    }

    private static func nondefaultPort(_ port: Int?, scheme: String) -> Int? {
        switch (scheme, port) {
        case ("http", 80), ("https", 443): return nil
        default: return port
        }
    }

    func rows(collapsed: Set<GroupID>) -> [Row] {
        var result: [Row] = []
        func append(_ group: Group, depth: Int) {
            result.append(Row(id: .group(group.id), depth: depth,
                              content: .group(group.id, title: group.title, symbol: group.symbol, count: group.count)))
            guard !collapsed.contains(group.id) else { return }
            for child in group.childGroups.values.sorted(by: Self.compares) {
                append(child, depth: depth + 1)
            }
            for entry in group.sessions {
                result.append(Row(id: .session(entry.session.id), depth: depth + 1,
                                  content: .session(entry.session, title: entry.title)))
            }
        }
        if let encrypted = roots[.encrypted] { append(encrypted, depth: 0) }
        for host in roots.values.sorted(by: Self.compares) where host.id != .encrypted && host.id != .otherHosts {
            append(host, depth: 0)
        }
        if let other = roots[.otherHosts] { append(other, depth: 0) }
        return result
    }

    private static func compares(_ lhs: Group, _ rhs: Group) -> Bool {
        switch lhs.title.localizedStandardCompare(rhs.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.title < rhs.title
        }
    }
}
