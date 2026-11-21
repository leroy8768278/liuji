import Darwin
import Foundation
import XCTest
@testable import PacketScope

final class ExternalProxyTests: XCTestCase {
    func testRouteSuggestionIsLimitedToDistinctLoopbackPort() {
        let route = MacProxyRoute(settings: ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7897])
        XCTAssertEqual(route.loopbackHTTP(excluding: 8888)?.port, 7897)
        XCTAssertNil(route.loopbackHTTP(excluding: 7897))
        for host in ["192.0.2.1", "127.1", "127.0.0.1%lo0", "localhost"] {
            XCTAssertFalse(LoopbackHTTPProxy(host: host, port: 7897).isLoopback)
        }
    }

    func testHTTPUsesAbsoluteTargetAndLoopbackDestinationGoesDirect() throws {
        let server = try LocalPeer()
        let origin = try LocalPeer()
        let engine = ProxyEngine()
        defer { engine.stop() }
        engine.setExternalProxy(LoopbackHTTPProxy(host: "127.0.0.1", port: server.port))
        let port = try start(engine)
        let done = expectation(description: "upstream request")
        server.serve { fd in
            let request = LocalPeer.readHead(fd)
            XCTAssertTrue(request.hasPrefix("GET http://upstream-fixture.invalid:8080/path?q=1 HTTP/1.1\r\n"))
            XCTAssertFalse(request.lowercased().contains("proxy-authorization"))
            LocalPeer.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", fd)
            done.fulfill()
        }
        XCTAssertTrue(try LocalPeer.exchange(port, "GET http://upstream-fixture.invalid:8080/path?q=1 HTTP/1.1\r\nHost: upstream-fixture.invalid:8080\r\nProxy-Authorization: Basic fixture\r\n\r\n").hasSuffix("ok"))
        wait(for: [done], timeout: 4)

        let bypass = expectation(description: "bypassed upstream")
        origin.serve { fd in
            XCTAssertTrue(LocalPeer.readHead(fd).hasPrefix("GET /direct HTTP/1.1"))
            LocalPeer.write("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\ndirect", fd)
            bypass.fulfill()
        }
        XCTAssertTrue(try LocalPeer.exchange(port, "GET http://127.0.0.1:\(origin.port)/direct HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n").hasSuffix("direct"))
        wait(for: [bypass], timeout: 4)
    }

    func testConnectNegotiatesThenRelaysEarlyDataInBothDirections() throws {
        let server = try LocalPeer()
        let engine = ProxyEngine()
        defer { engine.stop() }
        engine.setExternalProxy(LoopbackHTTPProxy(host: "127.0.0.1", port: server.port))
        let proxy = try start(engine)
        let complete = expectation(description: "proxy tunnel")
        server.serve { fd in
            let head = LocalPeer.readHead(fd)
            XCTAssertEqual(head, "CONNECT upstream-fixture.invalid:443 HTTP/1.1\r\nHost: upstream-fixture.invalid:443\r\n\r\n")
            LocalPeer.write("HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 200 Established\r\n\r\nfirst-", fd)
            let incoming = LocalPeer.readToEOF(fd)
            XCTAssertEqual(incoming, "payload")
            LocalPeer.write(incoming, fd)
            complete.fulfill()
        }
        let reply = try LocalPeer.exchange(proxy, "CONNECT upstream-fixture.invalid:443 HTTP/1.1\r\nHost: upstream-fixture.invalid:443\r\nProxy-Authorization: fixture\r\n\r\npayload")
        XCTAssertEqual(reply, "HTTP/1.1 200 Connection Established\r\n\r\nfirst-payload")
        wait(for: [complete], timeout: 4)
    }

    func testProxyAuthenticationIsNotRelayedAndOwnPortRejected() throws {
        let server = try LocalPeer()
        let engine = ProxyEngine()
        defer { engine.stop() }
        engine.setExternalProxy(LoopbackHTTPProxy(host: "127.0.0.1", port: server.port))
        let proxy = try start(engine)
        for request in ["GET http://upstream-fixture.invalid/ HTTP/1.1", "CONNECT upstream-fixture.invalid:443 HTTP/1.1"] {
            server.serve { fd in
                _ = LocalPeer.readHead(fd)
                LocalPeer.write("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=private-fixture\r\nContent-Length: 7\r\n\r\nprivate", fd)
            }
            let reply = try LocalPeer.exchange(proxy, request + "\r\nHost: upstream-fixture.invalid\r\n\r\n")
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 502"))
            XCTAssertFalse(reply.contains("private"))
            XCTAssertFalse(reply.lowercased().contains("proxy-authenticate"))
        }
        engine.setExternalProxy(LoopbackHTTPProxy(host: "127.0.0.1", port: proxy))
        let reply = try LocalPeer.exchange(proxy, "CONNECT upstream-fixture.invalid:443 HTTP/1.1\r\nHost: upstream-fixture.invalid\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 502"))
    }

    private func start(_ engine: ProxyEngine) throws -> UInt16 {
        let ready = expectation(description: "loopback proxy ready")
        let value = PortResult()
        engine.start(port: 0, onState: { state in
            if case let .running(port) = state { value.port = port; ready.fulfill() }
        }, onSession: { _ in })
        wait(for: [ready], timeout: 4)
        return try XCTUnwrap(value.port)
    }
}

private final class PortResult: @unchecked Sendable { var port: UInt16? }

private final class LocalPeer: @unchecked Sendable {
    let listener: Int32
    let port: UInt16
    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw POSIXError(.EIO) }
        var addr = Self.address(0)
        var size = socklen_t(addr.sin_len)
        let ready = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, size) == 0 && listen(sock, 8) == 0 && getsockname(sock, $0, &size) == 0
            }
        }
        guard ready else { close(sock); throw POSIXError(.EADDRNOTAVAIL) }
        listener = sock
        port = UInt16(bigEndian: addr.sin_port)
    }

    deinit { close(listener) }

    func serve(_ respond: @escaping (Int32) -> Void) {
        DispatchQueue.global().async {
            var item = pollfd(fd: self.listener, events: Int16(POLLIN), revents: 0)
            guard poll(&item, 1, 4000) > 0 else { return }
            let fd = accept(self.listener, nil, nil)
            guard fd >= 0 else { return }
            defer { close(fd) }
            Self.setTimeout(fd)
            respond(fd)
        }
    }

    static func exchange(_ port: UInt16, _ request: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = address(port)
        let length = socklen_t(addr.sin_len)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) == 0 }
        }
        guard connected else { throw POSIXError(.ECONNREFUSED) }
        setTimeout(fd)
        write(request, fd)
        shutdown(fd, SHUT_WR)
        return readToEOF(fd)
    }

    private static func address(_ port: UInt16) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        value.sin_port = port.bigEndian
        return value
    }

    private static func setTimeout(_ fd: Int32) {
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on)))
    }

    static func write(_ text: String, _ fd: Int32) {
        let bytes = Data(text.utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    }

    static func readHead(_ fd: Int32) -> String {
        var bytes = Data()
        var byte: UInt8 = 0
        let end = Data("\r\n\r\n".utf8)
        while bytes.count < 16_384 && recv(fd, &byte, 1, 0) == 1 {
            bytes.append(byte)
            if bytes.suffix(4) == end { break }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func readToEOF(_ fd: Int32) -> String {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
}
