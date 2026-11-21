import Darwin
import Foundation
import XCTest
@testable import PacketScope

final class LocalClientProcessTests: XCTestCase {
    func testReportsOnlyUniqueClientHalfForExactListenerAndPeer() {
        let candidates = """
        p101
        n127.0.0.1:51000->127.0.0.1:8888
        n127.0.0.1:51001->127.0.0.1:8888
        n127.0.0.1:8888->127.0.0.1:51000
        n127.0.0.1:51002->127.0.0.1:9999
        n192.0.2.1:51003->127.0.0.1:8888
        p102
        n127.0.0.1:51001->127.0.0.1:8888
        """
        XCTAssertEqual(LocalClientProcessResolver.clientPIDs(candidates, port: 8888, peers: [51000, 51001, 51002, 51003]), [51000: 101])
    }

    func testRealLoopbackChildProcessIsIdentified() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var length = socklen_t(address.sin_len)
        let listening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, length) == 0 && listen(listener, 1) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        XCTAssertTrue(listening)
        guard listening else { return }
        let port = UInt16(bigEndian: address.sin_port)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        child.arguments = ["-w", "5", "127.0.0.1", String(port)]
        let input = Pipe()
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 3_000) > 0 else { return XCTFail("Loopback child did not connect") }
        var peer = sockaddr_in()
        let fd = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
        }
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let peerPort = UInt16(bigEndian: peer.sin_port)
        let process = try XCTUnwrap(LocalClientProcessResolver.lookup(port: port, peers: [peerPort])[peerPort])
        XCTAssertEqual(process.pid, child.processIdentifier)
        XCTAssertFalse(process.name.isEmpty)
    }
}
