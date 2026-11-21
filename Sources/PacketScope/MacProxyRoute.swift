import Foundation
import SystemConfiguration

struct MacProxyRoute: Equatable {
    let isAvailable: Bool
    let http: String
    let https: String
    let socks: String
    let usesAutomaticConfiguration: Bool
    private let httpEndpoint: Endpoint?
    private let httpsEndpoint: Endpoint?

    static func current() -> Self {
        MacProxyRoute(settings: SCDynamicStoreCopyProxies(nil) as? [String: Any])
    }

    init(settings: [String: Any]?) {
        isAvailable = settings != nil
        let values = settings ?? [:]
        func enabled(_ key: String) -> Bool {
            (values[key] as? NSNumber)?.boolValue == true
        }
        func endpoint(_ scheme: String) -> Endpoint? {
            guard enabled(scheme + "Enable"),
                  let host = values[scheme + "Proxy"] as? String, !host.isEmpty,
                  let number = values[scheme + "Port"] as? NSNumber,
                  let port = UInt16(exactly: number.intValue), port > 0 else { return nil }
            return Endpoint(host: host, port: port)
        }
        func label(_ scheme: String, _ endpoint: Endpoint?) -> String {
            if settings == nil { return "无法读取" }
            if let endpoint { return endpoint.address }
            return enabled(scheme + "Enable") ? "地址或端口无效" : "未启用"
        }
        httpEndpoint = endpoint("HTTP")
        httpsEndpoint = endpoint("HTTPS")
        http = label("HTTP", httpEndpoint)
        https = label("HTTPS", httpsEndpoint)
        socks = label("SOCKS", endpoint("SOCKS"))
        usesAutomaticConfiguration = enabled("ProxyAutoConfigEnable") || enabled("ProxyAutoDiscoveryEnable")
    }

    func loopbackHTTP(excluding port: UInt16) -> LoopbackHTTPProxy? {
        guard let endpoint = httpEndpoint else { return nil }
        let address = LoopbackHTTPProxy(host: endpoint.host, port: endpoint.port)
        return address.usable(excluding: port) ? address : nil
    }

    func matches(port: UInt16) -> Bool {
        let listener = Endpoint(host: "127.0.0.1", port: port)
        return isAvailable && !usesAutomaticConfiguration && httpEndpoint == listener && httpsEndpoint == listener
    }

    private struct Endpoint: Equatable {
        let host: String
        let port: UInt16

        var address: String {
            let literal = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return "\(literal):\(port)"
        }
    }
}

final class MacProxyRouteMonitor {
    private var store: SCDynamicStore?

    init(onChange: @escaping () -> Void) {
        let callback = Callback(onChange)
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { UnsafeRawPointer(Unmanaged<Callback>.fromOpaque($0).retain().toOpaque()) },
            release: { Unmanaged<Callback>.fromOpaque($0).release() }, copyDescription: nil
        )
        let session = withExtendedLifetime(callback) {
            SCDynamicStoreCreate(nil, "流迹系统代理状态" as CFString, { _, _, pointer in
                guard let pointer else { return }
                Unmanaged<Callback>.fromOpaque(pointer).takeUnretainedValue().onChange()
            }, &context)
        }
        guard let session else { return }
        let keys = [
            SCDynamicStoreKeyCreateProxies(nil),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv6)
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(session, keys, nil),
              SCDynamicStoreSetDispatchQueue(session, .main) else { return }
        store = session
    }

    deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }

    private final class Callback {
        let onChange: () -> Void
        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    }
}
