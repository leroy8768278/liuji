import Foundation
import Network

enum HostListKind {
    case focused, ignored

    var title: String { self == .focused ? "关注的主机" : "录制忽略名单" }

    func entry(_ text: String) -> String? {
        if self == .ignored, text.contains("://") { return RecordingLocation(text)?.description }
        return CaptureHostLists.host(text)
    }
}

struct CaptureHostLists {
    var focused: Set<String>
    var ignored: Set<String>

    init(defaults: UserDefaults = .standard) {
        focused = Set((defaults.stringArray(forKey: "capture.focusedHosts") ?? []).compactMap(HostListKind.focused.entry))
        ignored = Set((defaults.stringArray(forKey: "capture.ignoredLocations") ?? []).compactMap(HostListKind.ignored.entry))
    }

    func entries(_ kind: HostListKind) -> Set<String> { kind == .focused ? focused : ignored }

    mutating func replace(_ kind: HostListKind, with entries: Set<String>, defaults: UserDefaults = .standard) {
        let canonical = Set(entries.compactMap(kind.entry))
        if kind == .focused { focused = canonical } else { ignored = canonical }
        let key = kind == .focused ? "capture.focusedHosts" : "capture.ignoredLocations"
        defaults.set(canonical.sorted(), forKey: key)
    }

    func isFocused(_ host: String) -> Bool { Self.host(host).map(focused.contains) == true }

    func ignores(_ session: CaptureSession) -> Bool {
        guard !ignored.isEmpty, let location = RecordingLocation(session: session) else { return false }
        return ignored.contains(location.host) || ignored.contains(location.origin) || ignored.contains(location.description)
    }

    func shouldDiscard(_ session: CaptureSession, alreadyRecorded: Bool, discarded: inout Set<UUID>) -> Bool {
        if discarded.contains(session.id) {
            if session.finished { discarded.remove(session.id) }
            return true
        }
        guard !alreadyRecorded, ignores(session) else { return false }
        if !session.finished { discarded.insert(session.id) }
        return true
    }

    static func host(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("["), value.hasSuffix("]") {
            return IPv6Address(String(value.dropFirst().dropLast()))?.debugDescription
        }
        if let address = IPv6Address(value) { return address.debugDescription }
        if !value.utf8.allSatisfy({ $0 < 128 }) {
            var components = URLComponents()
            components.scheme = "http"
            components.host = value
            guard let asciiHost = components.url?.host else { return nil }
            value = asciiHost
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
        }) else { return nil }
        return value
    }
}

struct RecordingLocation {
    let scheme: String
    let host: String
    let port: UInt16
    let path: String

    init?(_ url: String) {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let name = components.host, let host = CaptureHostLists.host(name),
              let port = UInt16(exactly: components.port ?? (scheme == "http" ? 80 : 443)), port > 0,
              components.user == nil, components.password == nil, components.fragment == nil, components.query == nil else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = components.percentEncodedPath
    }

    init?(session: CaptureSession) {
        guard var components = URLComponents(string: session.url) else { return nil }
        components.query = nil
        components.fragment = nil
        if !session.isTunnel && components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        guard let url = components.string else { return nil }
        self.init(url)
    }

    var origin: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(name):\(port)"
    }

    var description: String { origin + path }
}
