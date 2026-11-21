import Network
import XCTest
@testable import PacketScope

final class LocalRequestComposerTests: XCTestCase {
    func testNormalizesLoopbacksAndRejectsRemoteTargetsAndCredentials() throws {
        XCTAssertEqual(try LocalRequestDraft.loopbackURL("http://localhost:123/").host, "127.0.0.1")
        XCTAssertEqual(try LocalRequestDraft.loopbackURL("http://127.0.2.1:123/").host, "127.0.2.1")
        XCTAssertEqual(try LocalRequestDraft.loopbackURL("http://[::1]/a").host, "::1")
        for url in ["http://example.test", "https://localhost", "http://user:secret@localhost",
                    "http://localhost.example", "http://127.0.0.1:65536", "http://[::2]", "http://localhost/x\r\nTest: a"] {
            XCTAssertThrowsError(try LocalRequestDraft.loopbackURL(url), url)
        }
    }

    func testRepeatUsesOnlyCompleteTextAndSelectedContentHeaders() throws {
        var row = CaptureSession(id: UUID(), startedAt: Date(), method: "POST", url: "http://localhost:8080/a",
                                 requestHeaders: [
                                    .init(name: "Authorization", value: "private"),
                                    .init(name: "Cookie", value: "private"),
                                    .init(name: "X-API-Key", value: "private"),
                                    .init(name: "Content-Type", value: "text/plain")
                                 ], finished: true)
        row.requestBody = Data("你好".utf8)
        row.requestBodyBytes = row.requestBody.count
        let copy = try XCTUnwrap(LocalRequestDraft(session: row, mode: .repeatRequest))
        let wire = String(decoding: try copy.prepared().data, as: UTF8.self)
        XCTAssertTrue(wire.contains("Content-Type: text/plain\r\n"))
        XCTAssertTrue(wire.hasSuffix("Content-Length: 6\r\n\r\n你好"))
        XCTAssertFalse(wire.contains("private"))
        row.requestBodyBytes = 2_000
        XCTAssertNil(LocalRequestDraft(session: row, mode: .repeatRequest))
        var new = LocalRequestDraft()
        for header in ["Proxy-Authorization: a", "Set-Cookie: a=b", "Host: outside.test", "Transfer-Encoding: chunked", "X-Debug-Test: good\revil"] {
            new.headers = header
            XCTAssertThrowsError(try new.prepared(), header)
        }
    }

    @MainActor
    func testSendAndRepeatProduceTwoCapturedTransactionsAndStopAtRedirect() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let origin = try NWListener(using: parameters)
        defer { origin.cancel() }
        let readyOrigin = expectation(description: "loopback app ready")
        origin.stateUpdateHandler = { if case .ready = $0 { readyOrigin.fulfill() } }
        origin.newConnectionHandler = { link in
            link.start(queue: .main)
            func readRequest(_ buffered: Data) {
                link.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, eof, error in
                    let all = buffered + (data ?? Data())
                    guard all.suffix(9) == Data("\r\n\r\nhello".utf8) else {
                        if eof || error != nil { link.cancel() } else { readRequest(all) }
                        return
                    }
                    let text = String(decoding: all, as: UTF8.self)
                    XCTAssertTrue(text.hasPrefix("POST /check HTTP/1.1\r\n"))
                    let reply = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(origin.port!.rawValue)/redirected\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
                    link.send(content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true,
                              completion: .contentProcessed { _ in link.cancel() })
                }
            }
            readRequest(Data())
        }
        origin.start(queue: .main)
        await fulfillment(of: [readyOrigin], timeout: 6)
        let targetPort = try XCTUnwrap(origin.port?.rawValue)
        let engine = ProxyEngine()
        defer { engine.stop() }
        let readyProxy = expectation(description: "capture listener ready")
        let captured = expectation(description: "both sessions captured")
        captured.expectedFulfillmentCount = 2
        var proxyPort: UInt16?
        var observed: [CaptureSession] = []
        engine.start(port: 0, onState: { state in
            if case let .running(port) = state {
                DispatchQueue.main.async { proxyPort = port; readyProxy.fulfill() }
            }
        }, onSession: { session in
            DispatchQueue.main.async {
                if session.finished { observed.append(session); captured.fulfill() }
            }
        })
        await fulfillment(of: [readyProxy], timeout: 6)
        let port = try XCTUnwrap(proxyPort)
        var draft = LocalRequestDraft()
        draft.url = "http://localhost:\(targetPort)/check"
        draft.method = "POST"
        draft.body = "hello"
        draft.headers = "Content-Type: text/plain"
        let sender = LocalRequestSender()
        for i in 0..<2 {
            if i == 1 {
                for _ in 0..<100 where observed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
                draft = try XCTUnwrap(observed.first.flatMap { LocalRequestDraft(session: $0, mode: .repeatRequest) })
            }
            let request = try draft.prepared()
            let done = expectation(description: "manual send \(i)")
            sender.send(request, via: port) { result in
                if case let .failure(error) = result { XCTFail(error.localizedDescription) }
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 8)
        }
        await fulfillment(of: [captured], timeout: 6)
        XCTAssertEqual(Set(observed.map(\.id)).count, 2)
        XCTAssertEqual(observed.map(\.statusCode), [302, 302])
        XCTAssertEqual(observed.map(\.requestBody), [Data("hello".utf8), Data("hello".utf8)])
        XCTAssertEqual(observed.map(\.responseBody), [Data("OK".utf8), Data("OK".utf8)])
    }
}
