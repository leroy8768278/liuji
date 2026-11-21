import Foundation
import XCTest
@testable import PacketScope

final class MacSystemProxyControllerTests: XCTestCase {
    private var folder: URL!
    private var preferences: StubPreferences!

    private func controller() -> MacSystemProxyController {
        MacSystemProxyController(preferences: preferences, backupURL: folder.appendingPathComponent("recovery.json"))
    }

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        preferences = StubPreferences()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testRestoresOriginalServiceAfterRestartAndNetworkSwitch() throws {
        let original: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7897,
            "HTTPSEnable": 0, "HTTPSProxy": "unused", "HTTPSPort": 8443,
            "SOCKSEnable": 1, "SOCKSPort": 7897, "ExceptionsList": ["localhost"]
        ]
        preferences.configs["wifi"] = original
        var first: MacSystemProxyController? = controller()
        _ = try XCTUnwrap(first).enable(port: 8888)
        XCTAssertTrue(first?.hasSavedConfiguration == true)
        XCTAssertEqual(preferences.configs["wifi"]?["HTTPSPort"] as? Int, 8888)
        XCTAssertEqual(preferences.configs["wifi"]?["SOCKSPort"] as? Int, 7897)
        preferences.active = "ethernet"
        let replacement = controller()
        XCTAssertFalse(replacement.hasSavedConfiguration)
        first = nil
        XCTAssertTrue(replacement.hasSavedConfiguration)
        _ = try replacement.restore()
        XCTAssertEqual(preferences.configs["wifi"]! as NSDictionary, original as NSDictionary)
        XCTAssertTrue(preferences.configs["ethernet"]!.isEmpty)
        XCTAssertFalse(replacement.hasSavedConfiguration)
    }

    func testForeignChangesArePreservedAndMissingOriginalKeysRemoved() throws {
        let subject = controller()
        _ = try subject.enable(port: 8888)
        preferences.configs["wifi"]?["HTTPPort"] = 7899
        preferences.configs["wifi"]?["ExceptionsList"] = ["another.local"]
        _ = try subject.restore()
        XCTAssertEqual(preferences.configs["wifi"]?["HTTPPort"] as? Int, 7899)
        XCTAssertNil(preferences.configs["wifi"]?["HTTPSProxy"])
        XCTAssertNil(preferences.configs["wifi"]?["HTTPSPort"])
        XCTAssertNil(preferences.configs["wifi"]?["HTTPSEnable"])
        XCTAssertEqual(preferences.configs["wifi"]?["ExceptionsList"] as? [String], ["another.local"])
    }

    func testEnableFailureRollsBackBothPreferencesAndRuntime() {
        let subject = controller()
        preferences.failingApplies = [1]
        XCTAssertThrowsError(try subject.enable(port: 8888))
        XCTAssertTrue(preferences.configs["wifi"]!.isEmpty)
        XCTAssertTrue(preferences.applied["wifi"]!.isEmpty)
        XCTAssertFalse(subject.hasSavedConfiguration)
    }

    func testRestoreRetriesApplyAfterInterruptionOrRollbackFailure() throws {
        var subject: MacSystemProxyController? = controller()
        _ = try XCTUnwrap(subject).enable(port: 8888)
        preferences.failingApplies = [2]
        XCTAssertThrowsError(try XCTUnwrap(subject).restore())
        XCTAssertTrue(subject?.hasSavedConfiguration == true)
        XCTAssertEqual(preferences.applied["wifi"]?["HTTPSPort"] as? Int, 8888)
        XCTAssertTrue(preferences.configs["wifi"]!.isEmpty)
        subject = nil
        let recovered = controller()
        _ = try recovered.restore()
        XCTAssertTrue(preferences.applied["wifi"]!.isEmpty)
        XCTAssertFalse(recovered.hasSavedConfiguration)

        preferences.failingApplies = [4, 5]
        XCTAssertThrowsError(try recovered.enable(port: 8888))
        XCTAssertTrue(recovered.hasSavedConfiguration)
        _ = try recovered.restore()
        XCTAssertEqual(preferences.writes, 6)
        XCTAssertFalse(recovered.hasSavedConfiguration)
    }

    func testPACOrAnExistingManualConfigurationDoesNotCreateBackup() throws {
        let subject = controller()
        preferences.automatic = true
        XCTAssertThrowsError(try subject.enable(port: 8888))
        XCTAssertFalse(subject.hasSavedConfiguration)
        preferences.automatic = false
        preferences.configs["wifi"] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8888,
                                       "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 8888]
        _ = try subject.enable(port: 8888)
        XCTAssertFalse(subject.hasSavedConfiguration)
        XCTAssertEqual(preferences.writes, 0)
    }

    func testSecondEnableDoesNotOverwriteBackup() throws {
        let subject = controller()
        _ = try subject.enable(port: 8888)
        _ = try subject.enable(port: 8888)
        XCTAssertEqual(preferences.writes, 1)
        XCTAssertThrowsError(try subject.enable(port: 9001))
        _ = try subject.restore()
        XCTAssertTrue(preferences.configs["wifi"]!.isEmpty)
    }

    func testAnotherInstanceCannotEnableOrRestoreUntilOwnerReleasesLease() throws {
        let original: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7897,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897
        ]
        preferences.configs["wifi"] = original
        let owner = controller()
        let other = controller()
        _ = try owner.enable(port: 8888)
        XCTAssertFalse(other.hasSavedConfiguration)
        XCTAssertThrowsError(try other.restore())
        XCTAssertThrowsError(try other.enable(port: 8888))
        XCTAssertThrowsError(try other.enable(port: 8900))
        XCTAssertEqual(preferences.writes, 1)
        XCTAssertEqual(preferences.configs["wifi"]?["HTTPPort"] as? Int, 8888)
        _ = try owner.restore()
        _ = try other.enable(port: 8900)
        XCTAssertFalse(owner.hasSavedConfiguration)
        _ = try other.restore()
        XCTAssertEqual(preferences.configs["wifi"]! as NSDictionary, original as NSDictionary)
    }
}

private final class StubPreferences: MacProxyPreferences {
    var active = "wifi"
    var automatic = false
    var configs: [String: [String: Any]] = ["wifi": [:], "ethernet": [:]]
    var applied: [String: [String: Any]] = ["wifi": [:], "ethernet": [:]]
    var failingApplies: Set<Int> = []
    var writes = 0

    func edit(serviceID: String?, _ operation: (MacProxyService, [String: Any], ([String: Any]) throws -> Void) throws -> String) throws -> String {
        let id = serviceID ?? active
        let service = MacProxyService(id: id, name: id, automaticProxy: automatic)
        return try operation(service, configs[id]!) { updated in
            self.writes += 1
            self.configs[id] = updated
            if self.failingApplies.contains(self.writes) { throw CocoaError(.fileWriteUnknown) }
            self.applied[id] = updated
        }
    }
}
