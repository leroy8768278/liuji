import Darwin
import Foundation
import Network
import Security
import SwiftUI

struct OwnedHTTPSError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct OwnedHTTPSRoute: Identifiable, @unchecked Sendable {
    let id = UUID()
    let host: String
    let port: UInt16
    let identity: sec_identity_t
    let certificate: Data

    static func hostname(_ input: String) -> String? {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.count <= 253, host.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-" &&
                label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return nil }
        return host
    }

    init(host: String, port: UInt16, file: URL, password: String) throws {
        guard #available(macOS 15, *) else { throw OwnedHTTPSError("内存证书导入需要 macOS 15 或更高版本。") }
        guard let host = Self.hostname(host), port > 0 else { throw OwnedHTTPSError("请输入确切的域名和有效端口。") }
        guard file.isFileURL else { throw OwnedHTTPSError("请选择本机的 PKCS#12 文件。") }
        let fd = file.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { throw OwnedHTTPSError("无法打开选定的证书文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let limit = 4 * 1024 * 1024
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else {
            throw OwnedHTTPSError("证书文件应为 1 字节到 4 MiB。")
        }
        let options: [String: Any] = [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        let result = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard result == errSecSuccess, let entries = items as? [[String: Any]], entries.count == 1,
              let entry = entries.first, let raw = entry[kSecImportItemIdentity as String],
              CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID() else {
            throw OwnedHTTPSError("无法读取服务端身份，请检查文件、密码及其是否包含一个私钥。")
        }
        let imported = raw as! SecIdentity
        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(imported, &leaf) == errSecSuccess, let leaf else {
            throw OwnedHTTPSError("服务端身份缺少叶证书。")
        }
        let values = SecCertificateCopyValues(leaf, [kSecOIDSubjectAltName] as CFArray, nil) as? [String: Any]
        let san = values?[kSecOIDSubjectAltName as String] as? [String: Any]
        let names = san?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        guard names.contains(where: { name in
            let type = name[kSecPropertyKeyLabel as String] as? String
            return (type == "DNS Name" || type == "IP Address") &&
                (name[kSecPropertyKeyValue as String] as? String)?.lowercased() == host
        }) else { throw OwnedHTTPSError("证书的备用名称中没有此确切主机。") }
        let chain = entry[kSecImportItemCertChain as String] as? [SecCertificate] ?? []
        guard let identity = sec_identity_create_with_certificates(imported, chain as CFArray) else {
            throw OwnedHTTPSError("无法加载该服务的 TLS 身份。")
        }
        self.identity = identity
        self.host = host
        self.port = port
        certificate = SecCertificateCopyData(leaf) as Data
    }

    func serverParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    func originParameters() -> NWParameters {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)
        sec_protocol_options_set_tls_resumption_enabled(options.securityProtocolOptions, false)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { [host, certificate] _, securityTrust, complete in
            let trust = sec_trust_copy_ref(securityTrust).takeRetainedValue()
            let policy = SecPolicyCreateSSL(true, host as CFString)
            var original: CFArray?
            guard SecTrustCopyPolicies(trust, &original) == errSecSuccess, let policies = original as? [SecPolicy],
                  SecTrustSetPolicies(trust, (policies + [policy]) as CFArray) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil),
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let actual = chain.first else {
                complete(false)
                return
            }
            complete(SecCertificateCopyData(actual) as Data == certificate)
        }, .global(qos: .userInitiated))
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.preferNoProxies = true
        return parameters
    }
}

@MainActor
final class OwnedHTTPSSettings: ObservableObject {
    @Published private(set) var enabled = true
    @Published private(set) var routes: [OwnedHTTPSRoute] = []
    var onChange: (([OwnedHTTPSRoute]) -> Void)?

    func isEnabled(host: String, port: UInt16) -> Bool {
        enabled && routes.contains { $0.host == OwnedHTTPSRoute.hostname(host) && $0.port == port }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        onChange?(enabled ? routes : [])
    }

    func add(host: String, port: UInt16, file: URL, password: String) throws {
        let route = try OwnedHTTPSRoute(host: host, port: port, file: file, password: password)
        routes.removeAll { $0.host == route.host && $0.port == route.port }
        routes.append(route)
        setEnabled(true)
    }

    func remove(id: UUID) {
        routes.removeAll { $0.id == id }
        onChange?(enabled ? routes : [])
    }
}
