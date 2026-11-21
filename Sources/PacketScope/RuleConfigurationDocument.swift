import Darwin
import Foundation
import UniformTypeIdentifiers

struct RuleConfigurationDocument: Sendable {
    static let contentType = UTType(exportedAs: "local.packetscope.mac.rules", conformingTo: .json)
    private static let maximumFileBytes = 1024 * 1024

    let rules: ProxyRuleSet

    init(rules: ProxyRuleSet) {
        self.rules = rules
    }

    func encoded() throws -> Data {
        try Self.validate(rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Payload(rules: rules))
        guard data.count <= Self.maximumFileBytes else { throw ConfigurationError.tooLarge }
        return data
    }

    static func read(from url: URL) throws -> Self {
        guard url.isFileURL else { throw ConfigurationError.notRegular }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw ConfigurationError.cannotRead }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw ConfigurationError.cannotRead }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw ConfigurationError.notRegular }
        guard metadata.st_size <= maximumFileBytes else { throw ConfigurationError.tooLarge }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw ConfigurationError.tooLarge }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.invalid
        }
        try validate(payload.rules)
        return Self(rules: payload.rules)
    }

    private static func validate(_ rules: ProxyRuleSet) throws {
        var identifiers: Set<UUID> = []
        for (index, rule) in rules.rules.enumerated() {
            guard identifiers.insert(rule.id).inserted else { throw ConfigurationError.duplicateIDs }
            if let error = rule.validationError {
                throw ConfigurationError.invalidRule(index + 1, error)
            }
        }
    }

    private struct Payload: Codable {
        private static let formatName = "PacketScope Rule Configuration"
        private static let currentVersion = 1

        let format: String
        let version: Int
        let rules: ProxyRuleSet

        init(rules: ProxyRuleSet) {
            format = Self.formatName
            version = Self.currentVersion
            self.rules = rules
        }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: CodingKeys.self)
            format = try root.decode(String.self, forKey: .format)
            guard format == Self.formatName else { throw ConfigurationError.invalid }
            version = try root.decode(Int.self, forKey: .version)
            guard version == Self.currentVersion else { throw ConfigurationError.unsupportedVersion(version) }
            rules = try root.decode(ProxyRuleSet.self, forKey: .rules)
        }
    }

    private enum ConfigurationError: LocalizedError {
        case notRegular, cannotRead, invalid, tooLarge, duplicateIDs
        case unsupportedVersion(Int)
        case invalidRule(Int, String)

        var errorDescription: String? {
            switch self {
            case .notRegular: "请选择常规的流迹规则配置文件。"
            case .cannotRead: "无法读取规则配置文件。"
            case .invalid: "规则配置文件的格式或数据无效。"
            case .tooLarge: "流迹规则配置文件最大支持 1 MiB。"
            case .duplicateIDs: "规则配置文件中有重复的规则标识。"
            case let .unsupportedVersion(version): "当前流迹版本无法打开第 \(version) 版规则配置。"
            case let .invalidRule(index, problem): "第 \(index) 条规则无效。\(problem)"
            }
        }
    }
}
