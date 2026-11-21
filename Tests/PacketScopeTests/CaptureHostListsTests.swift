import XCTest
@testable import PacketScope

final class CaptureHostListsTests: XCTestCase {
    private var scope: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        scope = "local.packetscope.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: scope)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: scope)
        super.tearDown()
    }

    func testFocusedHostsAreListedBeforeOtherHostsAndKeepTunnelRows() throws {
        var lists = CaptureHostLists(defaults: defaults)
        lists.replace(.focused, with: ["API.Example.Test."], defaults: defaults)
        XCTAssertEqual(CaptureHostLists(defaults: defaults).focused, ["api.example.test"])
        XCTAssertEqual(CaptureHostLists.host("bücher.test"), "xn--bcher-kva.test")
        let a = session("https://api.example.test:443", tunnel: true)
        let b = session("https://other.test:443", tunnel: true)
        let c = session("http://other.test:8080/a/b")
        let tree = SessionStructure([b, c, a], focusedHosts: lists.focused)
        let closed = tree.rows(collapsed: [.otherHosts])
        XCTAssertEqual(closed.last?.id, .group(.otherHosts))
        XCTAssertTrue(closed.contains { $0.id == .session(a.id) })
        XCTAssertFalse(closed.contains { $0.id == .session(b.id) })
        XCTAssertEqual(tree.ancestors[b.id]?.prefix(2).map { $0 }, [.otherHosts, .encrypted])
        XCTAssertEqual(tree.rows(collapsed: []).filter { if case .session = $0.id { return true }; return false }.count, 3)
        let noFocus = SessionStructure([a, b, c]).rows(collapsed: [])
        XCTAssertEqual(noFocus.first?.id, .group(.encrypted))
        XCTAssertFalse(noFocus.contains { $0.id == .group(.otherHosts) })
    }

    func testIgnoreMatchesPathAndAuthorityAndNormalizesIPv6() {
        var lists = CaptureHostLists(defaults: defaults)
        lists.replace(.ignored, with: ["http://api.test/a", "https://[::1]:8443", "blocked.test"], defaults: defaults)
        lists = CaptureHostLists(defaults: defaults)
        XCTAssertTrue(lists.ignores(session("http://API.test:80/a?key=1")))
        XCTAssertFalse(lists.ignores(session("http://api.test/ab")))
        XCTAssertFalse(lists.ignores(session("http://api.test:8080/a")))
        XCTAssertTrue(lists.ignores(session("https://[::1]:8443", tunnel: true)))
        XCTAssertFalse(lists.ignores(session("https://[::1]:443", tunnel: true)))
        XCTAssertTrue(lists.ignores(session("http://blocked.test/any")))
        XCTAssertFalse(lists.ignores(session("http://unblocked.test/any")))
        XCTAssertFalse(lists.isFocused("blocked.test"))
    }

    func testIgnoringOnlyAffectsNewSessionsAndUnignoreOnlyAffectsFutureSessions() {
        var lists = CaptureHostLists(defaults: defaults)
        var dropped: Set<UUID> = []
        var pending = session("http://api.test/a")
        lists.replace(.ignored, with: ["api.test"], defaults: defaults)
        XCTAssertFalse(lists.shouldDiscard(session("http://api.test/a"), alreadyRecorded: true, discarded: &dropped))
        XCTAssertTrue(lists.shouldDiscard(pending, alreadyRecorded: false, discarded: &dropped))
        lists.replace(.ignored, with: [], defaults: defaults)
        XCTAssertTrue(lists.shouldDiscard(pending, alreadyRecorded: false, discarded: &dropped))
        pending.finished = true
        XCTAssertTrue(lists.shouldDiscard(pending, alreadyRecorded: false, discarded: &dropped))
        XCTAssertTrue(dropped.isEmpty)
        XCTAssertFalse(lists.shouldDiscard(session("http://api.test/a"), alreadyRecorded: false, discarded: &dropped))
    }

    private func session(_ url: String, tunnel: Bool = false) -> CaptureSession {
        CaptureSession(id: UUID(), startedAt: Date(), method: tunnel ? "CONNECT" : "GET",
                       url: url, requestHeaders: [], isTunnel: tunnel)
    }
}
