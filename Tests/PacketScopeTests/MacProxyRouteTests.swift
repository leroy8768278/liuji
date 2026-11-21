import XCTest
@testable import PacketScope

final class MacProxyRouteTests: XCTestCase {
    private let manual: [String: Any] = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8888,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 8888,
        "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7897
    ]

    func testHTTPAndHTTPSMustBothPointToTheListener() {
        var settings = manual
        let own = MacProxyRoute(settings: settings)
        XCTAssertTrue(own.matches(port: 8888))
        XCTAssertEqual(own.socks, "127.0.0.1:7897")

        settings["HTTPPort"] = 7897
        XCTAssertFalse(MacProxyRoute(settings: settings).matches(port: 8888))
        settings["HTTPSPort"] = 7897
        let other = MacProxyRoute(settings: settings)
        XCTAssertEqual(other.https, "127.0.0.1:7897")
        XCTAssertFalse(other.matches(port: 8888))
    }

    func testIncompleteOrAutomaticConfigurationDoesNotReportCaptureReady() {
        for flag in ["ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            var settings = manual
            settings[flag] = 1
            let route = MacProxyRoute(settings: settings)
            XCTAssertTrue(route.usesAutomaticConfiguration)
            XCTAssertFalse(route.matches(port: 8888))
        }
        var incomplete = manual
        incomplete.removeValue(forKey: "HTTPSPort")
        XCTAssertFalse(MacProxyRoute(settings: incomplete).matches(port: 8888))
        incomplete["HTTPSEnable"] = 0
        XCTAssertEqual(MacProxyRoute(settings: incomplete).https, "未启用")
    }

    func testUnavailableSettingsAreDistinctFromAllProxiesDisabled() {
        XCTAssertFalse(MacProxyRoute(settings: nil).isAvailable)
        let disabled = MacProxyRoute(settings: [:])
        XCTAssertTrue(disabled.isAvailable)
        XCTAssertEqual(disabled.http, "未启用")
        XCTAssertFalse(disabled.matches(port: 8888))
    }
}
