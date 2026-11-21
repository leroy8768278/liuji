import Darwin
import Foundation
import Security
import SystemConfiguration

struct MacProxyService {
    let id: String
    let name: String
    let automaticProxy: Bool
}

protocol MacProxyPreferences {
    /// The read, comparison and writes all run under one system preferences lock.
    func edit(serviceID: String?, _ operation: (MacProxyService, [String: Any], ([String: Any]) throws -> Void) throws -> String) throws -> String
}

private struct MacProxyFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }

    static func system(_ action: String) -> Self {
        let status = SCError()
        if status == kSCStatusAccessError {
            return Self("macOS 未授权修改代理。请在授权弹窗中允许流迹更改网络设置，或在系统设置中手动配置。")
        }
        if status == kSCStatusPrefsBusy {
            return Self("其他程序正在更新网络设置，请稍后重试。")
        }
        return Self("\(action)失败（\(String(cString: SCErrorString(status)))）。")
    }
}

private final class SystemConfigurationPreferences: MacProxyPreferences {
    private var authorization: AuthorizationRef?
    private static let name = "流迹" as CFString

    deinit {
        if let authorization { AuthorizationFree(authorization, []) }
    }

    private static func primaryServiceID() -> String? {
        guard let store = SCDynamicStoreCreate(nil, name, nil, nil) else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let id = state["PrimaryService"] as? String { return id }
        }
        return nil
    }

    static func activeServiceName() -> String? {
        guard let id = primaryServiceID(),
              let prefs = SCPreferencesCreate(nil, name, nil),
              let service = SCNetworkServiceCopy(prefs, id as CFString) else { return nil }
        return SCNetworkServiceGetName(service) as String?
    }

    func edit(serviceID: String?, _ operation: (MacProxyService, [String: Any], ([String: Any]) throws -> Void) throws -> String) throws -> String {
        if authorization == nil {
            let status = AuthorizationCreate(nil, nil, [], &authorization)
            guard status == errAuthorizationSuccess else { throw MacProxyFailure("无法启动 macOS 网络设置授权（\(status)）。") }
        }
        guard let authorization,
              let prefs = SCPreferencesCreateWithAuthorization(nil, Self.name, nil, authorization) else {
            throw MacProxyFailure.system("打开网络设置")
        }
        guard SCPreferencesLock(prefs, false) else { throw MacProxyFailure.system("锁定网络设置") }
        defer { SCPreferencesUnlock(prefs) }

        guard let id = serviceID ?? Self.primaryServiceID(),
              let service = SCNetworkServiceCopy(prefs, id as CFString),
              let proxies = SCNetworkServiceCopyProtocol(service, kSCEntNetProxies) else {
            throw MacProxyFailure(serviceID == nil ? "当前没有可配置代理的活动网络服务。请检查 Wi-Fi 或以太网连接。" : "找不到原网络服务。恢复记录已保留。")
        }
        if serviceID == nil && !SCNetworkProtocolGetEnabled(proxies) {
            throw MacProxyFailure("当前网络服务的代理配置已被停用，请在系统设置中检查该服务。")
        }
        let current = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] ?? [:]
        let effective = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        let automatic = ["ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"].contains { key in
            (current[key] as? NSNumber)?.boolValue == true || (effective[key] as? NSNumber)?.boolValue == true
        }
        let descriptor = MacProxyService(id: id, name: SCNetworkServiceGetName(service) as String? ?? id, automaticProxy: automatic)
        return try operation(descriptor, current) { values in
            guard SCNetworkProtocolSetConfiguration(proxies, values as CFDictionary) else { throw MacProxyFailure.system("更新代理") }
            guard SCPreferencesCommitChanges(prefs) else { throw MacProxyFailure.system("保存代理") }
            guard SCPreferencesApplyChanges(prefs) else { throw MacProxyFailure.system("应用代理") }
        }
    }
}

private struct ManualProxyEndpoint: Codable, Equatable {
    var enabled: Int?
    var host: String?
    var port: Int?

    init(port: UInt16) {
        self.enabled = 1
        self.host = "127.0.0.1"
        self.port = Int(port)
    }

    init(_ values: [String: Any], protocolName: String) {
        enabled = (values[protocolName + "Enable"] as? NSNumber)?.intValue
        host = values[protocolName + "Proxy"] as? String
        port = (values[protocolName + "Port"] as? NSNumber)?.intValue
    }

    func write(to config: inout [String: Any], protocolName: String) {
        config[protocolName + "Enable"] = enabled
        config[protocolName + "Proxy"] = host
        config[protocolName + "Port"] = port
    }
}

private struct MacProxyBackup: Codable, Equatable {
    var transaction = UUID()
    let serviceID: String
    let port: UInt16
    let original: [String: ManualProxyEndpoint]
    var restoring = false
}

private enum ProxyLeaseError: LocalizedError {
    case inUse
    var errorDescription: String? { "另一个流迹实例正在管理 Mac 系统代理，请先在该实例中恢复原代理。" }
}

/// Keep a stable lock file beside the atomically replaced journal. The kernel
/// releases its flock when the owner's last descriptor closes, including on crash.
private final class ProxyRecoveryLease {
    private let descriptor: Int32

    init(backupURL: URL) throws {
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = backupURL.appendingPathExtension("lock")
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw ProxyLeaseError.inUse }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

final class MacSystemProxyController {
    private static let protocols = ["HTTP", "HTTPS"]
    private let preferences: MacProxyPreferences
    private let backupURL: URL
    private let lock = NSLock()
    private var lease: ProxyRecoveryLease?

    convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.packetscope.mac", isDirectory: true)
        self.init(preferences: SystemConfigurationPreferences(), backupURL: folder.appendingPathComponent("system-proxy-recovery.json"))
    }

    init(preferences: MacProxyPreferences, backupURL: URL) {
        self.preferences = preferences
        self.backupURL = backupURL
    }

    static func activeServiceName() -> String? { SystemConfigurationPreferences.activeServiceName() }
    private var journalExists: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    var hasSavedConfiguration: Bool {
        lock.withLock {
            guard journalExists else { return false }
            if lease != nil { return true }
            do {
                // A live instance owns its journal. Only an abandoned journal
                // should trigger recovery at startup in another instance.
                _ = try ProxyRecoveryLease(backupURL: backupURL)
                return true
            } catch ProxyLeaseError.inUse {
                return false
            } catch {
                return true  // Surface genuine recovery failures to the user.
            }
        }
    }

    private func claimLease() throws {
        if lease == nil { lease = try ProxyRecoveryLease(backupURL: backupURL) }
    }

    private func load() throws -> MacProxyBackup {
        guard let backup = try? JSONDecoder().decode(MacProxyBackup.self, from: Data(contentsOf: backupURL)),
              Set(backup.original.keys) == Set(Self.protocols), backup.port > 0, !backup.serviceID.isEmpty else {
            throw MacProxyFailure("原代理的恢复记录无法读取，请先在系统设置中检查 HTTP 和 HTTPS 代理。")
        }
        return backup
    }

    private func save(_ backup: MacProxyBackup) throws {
        try JSONEncoder().encode(backup).write(to: backupURL, options: .atomic)
    }

    func enable(port: UInt16) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard port > 0 else { throw MacProxyFailure("请先设置有效的监听端口。") }
        try claimLease()
        defer { if !journalExists { lease = nil } }
        return try preferences.edit(serviceID: nil) { service, current, write in
            guard !service.automaticProxy else { throw MacProxyFailure("当前网络启用了自动代理（PAC 或自动发现），请先在系统设置中检查自动代理，再接入流迹。") }
            let target = ManualProxyEndpoint(port: port)
            let endpoints = Dictionary(uniqueKeysWithValues: Self.protocols.map { ($0, ManualProxyEndpoint(current, protocolName: $0)) })
            if self.journalExists {
                let backup = try self.load()
                guard backup.serviceID == service.id, backup.port == port, !backup.restoring,
                      endpoints.values.allSatisfy({ $0 == target }) else {
                    throw MacProxyFailure("已有代理恢复记录。请先恢复原代理，再启用当前连接。")
                }
                return "\(service.name) 的 HTTP 和 HTTPS 已接入流迹。"
            }
            guard endpoints.values.contains(where: { $0 != target }) else {
                return "\(service.name) 的 HTTP 和 HTTPS 已手动指向流迹。"
            }
            var changed = current
            for name in Self.protocols { target.write(to: &changed, protocolName: name) }
            var backup = MacProxyBackup(serviceID: service.id, port: port, original: endpoints)
            try self.save(backup)
            do {
                try write(changed)
            } catch {
                let cause = error.localizedDescription
                do {
                    backup.restoring = true
                    try self.save(backup)
                    try write(current)
                    try FileManager.default.removeItem(at: self.backupURL)
                } catch {
                    throw MacProxyFailure("\(cause) 原代理的恢复记录已保留，请重试恢复。")
                }
                throw MacProxyFailure(cause)
            }
            return "\(service.name) 的 HTTP 和 HTTPS 已接入 127.0.0.1:\(port)。"
        }
    }

    func restore() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard journalExists else {
            lease = nil
            return "当前没有需要恢复的代理配置。"
        }
        try claimLease()
        defer { if !journalExists { lease = nil } }
        guard journalExists else { return "原代理恢复已完成。" }
        let expected = try load()
        return try preferences.edit(serviceID: expected.serviceID) { service, current, write in
            guard self.journalExists else { return "原代理恢复已完成。" }
            var backup = try self.load()
            guard backup.transaction == expected.transaction else {
                throw MacProxyFailure("代理设置已更新，请刷新状态后重试。")
            }
            let target = ManualProxyEndpoint(port: backup.port)
            var changed = current
            var needsWrite = false
            var externalChanges = false
            for name in Self.protocols {
                guard let original = backup.original[name], original != target else { continue }
                let actual = ManualProxyEndpoint(current, protocolName: name)
                if actual == target {
                    original.write(to: &changed, protocolName: name)
                    needsWrite = true
                } else if actual != original {
                    externalChanges = true
                }
            }
            // After an interruption between commit and apply, re-apply the persisted restoration.
            if needsWrite || backup.restoring {
                backup.restoring = true
                try self.save(backup)
                try write(changed)
            }
            try FileManager.default.removeItem(at: self.backupURL)
            return externalChanges ? "已结束接入，保留了其他程序修改的代理设置。" : "已恢复 \(service.name) 的原代理配置。"
        }
    }
}
