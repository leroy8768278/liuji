import SwiftUI

enum ViewSettingsPage: String, Identifiable {
    case highlights, mappings
    var id: Self { self }
    var title: String { self == .highlights ? "高亮规则" : "查看器映射" }
}

enum HighlightColor: String, Codable, CaseIterable {
    case red, orange, green, blue, purple
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
    var title: String {
        switch self {
        case .red: "红色"
        case .orange: "橙色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .purple: "紫色"
        }
    }
}

struct HighlightRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var host = ""
    var path = ""
    var status = ""
    var color: HighlightColor = .orange

    var validationError: String? {
        if host.isEmpty && path.isEmpty && status.isEmpty { return "至少填写一个匹配条件。" }
        if !host.isEmpty, ProxyRule(kind: .blockList, host: host).validationError != nil { return "请输入主机名或 *.example.test。" }
        if !path.isEmpty, !RuleLocation.isPath(path, prefixAllowed: true) { return "请输入路径，例如 /api 或 /api/*。" }
        if !status.isEmpty, !(1...5).map({ "\($0)xx" }).contains(status.lowercased()),
           !(status.count == 3 && (100...599).contains(Int(status) ?? 0)) { return "请输入三位状态码或 2xx 等状态码类别。" }
        return nil
    }

    func matches(_ session: CaptureSession) -> Bool {
        if !status.isEmpty {
            guard let code = session.statusCode, status == String(code) || status.lowercased() == "\(code / 100)xx" else { return false }
        }
        if !host.isEmpty {
            let pattern = RuleLocation.normalizedHost(host)
            let current = RuleLocation.normalizedHost(session.host)
            guard pattern.hasPrefix("*.") ? current.hasSuffix(pattern.dropFirst()) : current == pattern else { return false }
        }
        if !path.isEmpty {
            guard !session.isTunnel else { return false }
            let current = session.pathForRule
            return path.hasSuffix("/*") ? current.hasPrefix(path.dropLast()) : current == path
        }
        return true
    }

    var title: String { [host, path, status].filter { !$0.isEmpty }.joined(separator: " · ") }
}

struct ViewerMapping: Identifiable, Codable, Equatable {
    var id = UUID()
    var mime = ""
    var viewer: SessionBodyPresentation = .raw
    static func normalized(_ contentType: String) -> String {
        String(contentType.prefix { $0 != ";" }).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    var isValid: Bool {
        let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'+-.^_`|~")
        return viewer != .automatic && parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0.lowercased().unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}

@MainActor
final class ViewPreferences: ObservableObject {
    @Published var page: ViewSettingsPage?
    @Published private(set) var highlights: [HighlightRule]
    @Published private(set) var mappings: [ViewerMapping]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        highlights = Self.read([HighlightRule].self, from: defaults, key: "view.highlightRules")?.filter { $0.validationError == nil } ?? []
        mappings = Self.read([ViewerMapping].self, from: defaults, key: "view.viewerMappings")?.filter(\.isValid) ?? []
    }

    func save(_ rule: HighlightRule) {
        guard rule.validationError == nil else { return }
        if let index = highlights.firstIndex(where: { $0.id == rule.id }) { highlights[index] = rule }
        else { highlights.append(rule) }
        persist(highlights, key: "view.highlightRules")
    }

    func save(_ mapping: ViewerMapping) {
        var item = mapping
        item.mime = ViewerMapping.normalized(item.mime)
        guard item.isValid else { return }
        mappings.removeAll { $0.id == item.id || $0.mime == item.mime }
        mappings.append(item)
        persist(mappings, key: "view.viewerMappings")
    }

    func remove(_ id: UUID, from page: ViewSettingsPage) {
        if page == .highlights {
            highlights.removeAll { $0.id == id }
            persist(highlights, key: "view.highlightRules")
        } else {
            mappings.removeAll { $0.id == id }
            persist(mappings, key: "view.viewerMappings")
        }
    }

    func highlight(for session: CaptureSession) -> HighlightColor? {
        highlights.first { $0.matches(session) }?.color
    }

    func presentation(for headers: [CaptureHeader], override: SessionBodyPresentation) -> SessionBodyPresentation {
        guard override == .automatic, let header = headers.first(where: { $0.name.lowercased() == "content-type" }) else { return override }
        let type = ViewerMapping.normalized(header.value)
        return mappings.first { $0.mime == type }?.viewer ?? .automatic
    }

    private static func read<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
