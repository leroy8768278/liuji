import Darwin
import XCTest
@testable import PacketScope

final class MacCaptureWorkflowTests: XCTestCase {
    @MainActor
    func testStartsListenerThenRoutesAndResumesRecordingAndRestoresOnStop() async throws {
        let context = try Fixture()
        defer { context.clean() }
        let port = try freshPort()
        context.store.setPort(port)
        context.store.showExampleOrReturnToLive()
        context.store.startMacCapture()
        try await wait { !context.store.macProxyBusy }
        XCTAssertTrue(context.store.isRunning)
        XCTAssertTrue(context.store.macRoute.matches(port: port))
        XCTAssertTrue(context.store.hasMacProxyBackup)
        XCTAssertEqual(context.store.source, .live)
        context.store.toggleRecording()
        XCTAssertFalse(context.store.recordingEnabled)
        context.store.startMacCapture()
        try await wait { !context.store.macProxyBusy }
        XCTAssertTrue(context.store.recordingEnabled)
        context.store.stop()
        try await wait { !context.store.isRunning && !context.store.macProxyBusy }
        XCTAssertFalse(context.store.hasMacProxyBackup)
        XCTAssertTrue(context.store.macRoute.matches(port: 7897))
    }

    @MainActor
    func testBusyListeningPortDoesNotChangeSystemProxy() async throws {
        let context = try Fixture()
        defer { context.clean() }
        let (fd, port) = try reservedEndpoint()
        defer { close(fd) }
        context.store.setPort(port)
        context.store.startMacCapture()
        try await wait { !context.store.macProxyBusy }
        XCTAssertTrue(context.store.macProxyFailed)
        XCTAssertFalse(context.store.hasMacProxyBackup)
        XCTAssertTrue(context.store.macRoute.matches(port: 7897))
    }

    @MainActor
    func testRollsBackNewPreferencesWhenEffectiveRouteDoesNotChange() async throws {
        let context = try Fixture(keepOriginalRoute: true)
        defer { context.clean() }
        context.store.setPort(try freshPort())
        context.store.startMacCapture()
        try await wait { !context.store.macProxyBusy }
        XCTAssertTrue(context.store.macProxyFailed)
        XCTAssertFalse(context.store.hasMacProxyBackup)
        XCTAssertTrue(context.prefs.route.matches(port: 7897))
        context.store.stop()
        try await wait { !context.store.isRunning }
    }

    @MainActor private func wait(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !ready() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private func freshPort() throws -> UInt16 {
        let (fd, port) = try reservedEndpoint()
        close(fd)
        return port
    }

    private func reservedEndpoint() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var length = socklen_t(address.sin_len)
        let success = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard success else { close(fd); throw POSIXError(.EADDRINUSE) }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    @MainActor private final class Fixture {
        let store: CaptureStore
        let prefs = NetworkFixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let originalPort = UserDefaults.standard.object(forKey: "proxyPort")

        init(keepOriginalRoute: Bool = false) throws {
            let prefs = self.prefs
            let original = prefs.route
            let controller = MacSystemProxyController(preferences: prefs, backupURL: folder.appendingPathComponent("recovery"))
            store = CaptureStore(macProxyController: controller, readMacRoute: { keepOriginalRoute ? original : prefs.route })
        }

        func clean() {
            UserDefaults.standard.set(originalPort, forKey: "proxyPort")
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

private final class NetworkFixture: MacProxyPreferences {
    private let lock = NSLock()
    private var config: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7897,
                                         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897]
    var route: MacProxyRoute { lock.withLock { MacProxyRoute(settings: config) } }

    func edit(serviceID: String?, _ operation: (MacProxyService, [String: Any], ([String: Any]) throws -> Void) throws -> String) throws -> String {
        try lock.withLock {
            try operation(MacProxyService(id: "wifi", name: "Wi-Fi", automaticProxy: false), config) { self.config = $0 }
        }
    }
}
