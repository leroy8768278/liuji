import Foundation
import XCTest
@testable import PacketScope

final class MobileProxyConfigurationTests: XCTestCase {
    private let wifi = MobileProxyInterface(name: "fixture", address: "192.168.55.10", prefixLength: 24)
    private let phone = "192.168.55.24"

    func testPairsWithSpecificAddressOnPrivateSubnet() throws {
        let configuration = try MobileProxyConfiguration(interface: wifi, clientAddress: phone)
        XCTAssertEqual(configuration.listenAddress, wifi.address)
        XCTAssertEqual(configuration.clientAddress, phone)
        XCTAssertNil(wifi.validateClientAddress(phone))
    }

    func testRejectsMacNetworkBroadcastAndDifferentSubnetAddresses() {
        for address in [wifi.address, "192.168.55.0", "192.168.55.255", "192.168.56.24"] {
            XCTAssertNotNil(wifi.validateClientAddress(address), address)
            XCTAssertThrowsError(try MobileProxyConfiguration(interface: wifi, clientAddress: address), address)
        }
    }

    func testNewPairingRejectsCredentialsFromEarlierPairing() throws {
        let first = try MobileProxyConfiguration(interface: wifi, clientAddress: phone)
        let second = try MobileProxyConfiguration(interface: wifi, clientAddress: phone)
        let firstHeader = basicHeader(username: first.username, password: first.password)
        let secondHeader = basicHeader(username: second.username, password: second.password)
        XCTAssertTrue(first.authorizes([firstHeader]))
        XCTAssertTrue(second.authorizes([secondHeader]))
        XCTAssertFalse(second.authorizes([firstHeader]))
        XCTAssertFalse(first.authorizes([secondHeader]))
    }

    func testRejectsMissingWrongAndDuplicateAuthorizationValues() throws {
        let configuration = try MobileProxyConfiguration(interface: wifi, clientAddress: phone)
        let good = basicHeader(username: configuration.username, password: configuration.password)
        let replacement = configuration.password.first == "A" ? "B" : "A"
        let wrong = basicHeader(username: configuration.username, password: replacement + configuration.password.dropFirst())
        XCTAssertFalse(configuration.authorizes([]))
        XCTAssertFalse(configuration.authorizes([wrong]))
        XCTAssertFalse(configuration.authorizes([basicHeader(username: "other", password: configuration.password)]))
        XCTAssertFalse(configuration.authorizes([good, good]))
        XCTAssertFalse(configuration.authorizes([wrong, good]))
        XCTAssertFalse(configuration.authorizes(["Basic invalid$"]))
    }

    private func basicHeader(username: String, password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}
