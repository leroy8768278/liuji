import Foundation

enum BreakpointPhase: String, Codable, CaseIterable {
    case request, response, both

    var title: String {
        switch self {
        case .request: "请求"
        case .response: "响应"
        case .both: "请求和响应"
        }
    }
}

struct BreakpointLocation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let scheme: String
    let host: String
    let port: Int
    let path: String?
    var phase: BreakpointPhase

    init?(url: String, includeAllPaths: Bool, phase: BreakpointPhase = .request) {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        self.id = UUID()
        self.scheme = scheme
        self.host = host
        self.port = parts.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { return nil }
        self.path = includeAllPaths ? nil : (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath)
        self.phase = phase
    }

    var title: String { "\(scheme)://\(host):\(port)\(path ?? "/*")" }

    func sameLocation(as other: Self) -> Bool {
        scheme == other.scheme && host == other.host && port == other.port && path == other.path
    }

    func matches(_ session: CaptureSession, phase requestedPhase: BreakpointPhase) -> Bool {
        guard !session.isTunnel, phase == .both || phase == requestedPhase,
              let destination = Self(url: session.url, includeAllPaths: false) else { return false }
        return scheme == destination.scheme && host == destination.host && port == destination.port &&
            (path == nil || path == destination.path)
    }
}

extension CaptureHeader {
    var validatedBreakpointHeader: CaptureHeader? {
        let field = name.lowercased()
        guard field.hasPrefix("x-debug-"), field.count > 8, name.utf8.count <= 128,
              field.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              value.utf8.count <= 1_024, value.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return self
    }
}
