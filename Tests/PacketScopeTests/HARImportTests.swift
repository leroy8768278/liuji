import XCTest
@testable import PacketScope

final class HARImportTests: XCTestCase {
    private func entry() -> [String: Any] {
        [
            "startedDateTime": "2026-11-21T00:00:00.001Z", "time": 150,
            "request": ["url": "http://unit.example.test/path", "method": "POST", "httpVersion": "HTTP/1.1",
                        "headers": [["name": "X-Debug-Reason", "value": "test"]], "bodySize": 3,
                        "postData": ["mimeType": "text/plain", "text": "abc"]],
            "response": ["status": 200, "httpVersion": "h2", "headers": [["name": "Content-Encoding", "value": "gzip"]],
                         "bodySize": 42, "content": ["size": 3, "mimeType": "text/plain", "text": "xyz"]]
        ]
    }

    private func archive(_ entries: [[String: Any]], version: String = "1.2") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["log": ["version": version, "entries": entries]])
    }

    func testImportThenFindAndExportPreservesBodyAndWireHeaders() throws {
        let session = try XCTUnwrap(HARImport.decode(archive([entry()])).first)
        XCTAssertEqual(session.requestBody, Data("abc".utf8))
        XCTAssertEqual(session.responseBody, Data("xyz".utf8))
        XCTAssertEqual(session.responseHeaders.first?.value, "gzip")
        XCTAssertEqual(session.elapsed, 0.15)
        XCTAssertTrue(SessionFindIndex(session).contains("XYZ"))
        XCTAssertTrue(SessionFindIndex(session).contains("debug-reason"))
        let exported = try HARExportDocument(sessions: [session]).encoded()
        let again = try XCTUnwrap(HARImport.decode(exported).first)
        XCTAssertEqual(again.responseBody, session.responseBody)
        XCTAssertEqual(again.harResponseBody?.wireBytes, 42)
        XCTAssertEqual(again.harResponseBody?.mimeType, "text/plain")
    }

    func testBinaryAndSizeLimit() throws {
        var item = entry()
        let input = Data(repeating: 255, count: 600_000)
        item["response"] = ["status": 200, "headers": [], "bodySize": input.count,
                            "content": ["mimeType": "application/octet-stream", "size": input.count,
                                        "encoding": "base64", "text": input.base64EncodedString()]]
        let session = try XCTUnwrap(HARImport.decode(archive([item])).first)
        XCTAssertEqual(session.responseBody, input.prefix(512 * 1024))
        XCTAssertEqual(session.responseBytes, 600_000)
    }

    func testInvalidAndOversizedEntriesRejected() throws {
        XCTAssertThrowsError(try HARImport.decode(archive([], version: "2")))
        XCTAssertThrowsError(try HARImport.decode(archive(Array(repeating: [:], count: 2001))))
        var item = entry()
        item["response"] = ["status": 200, "headers": [], "content": ["encoding": "base64", "text": "@@@"]]
        XCTAssertThrowsError(try HARImport.decode(archive([item])))
        item["response"] = ["status": 200, "headers": [], "content": ["size": Int.max]]
        XCTAssertThrowsError(try HARImport.decode(archive([item, item])))
    }
}

extension HARImportTests {
    @MainActor
    func testRotatingRecordingsKeepsPendingUpdatesInOriginalSession() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CaptureStore(macProxyController: MacSystemProxyController(preferences: NoWrites(), backupURL: path))
        var first = CaptureSession(id: UUID(), startedAt: Date(), method: "GET", url: "http://unit.example.test/a", requestHeaders: [])
        store.receive(first)
        store.setNote("检查响应时间", for: first.id)
        store.receive(first)
        XCTAssertEqual(store.sessions.first?.userNote, "检查响应时间")
        store.newRecordingSession()
        let second = CaptureSession(id: UUID(), startedAt: Date(), method: "GET", url: "http://unit.example.test/b", requestHeaders: [])
        store.receive(second)
        first.statusCode = 200
        first.finished = true
        store.receive(first)
        XCTAssertEqual(store.sessions.map(\.id), [second.id])
        store.showRecordingSession(1)
        XCTAssertEqual(store.sessions.map(\.id), [first.id])
        XCTAssertEqual(store.sessions.first?.statusCode, 200)
        let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        try CaptureArchiveDocument(sessions: store.sessions).encoded().write(to: archiveURL)
        XCTAssertEqual(try CaptureArchiveDocument.read(from: archiveURL).sessions.first?.userNote, "检查响应时间")
        store.closeViewedSession()
        XCTAssertEqual(store.sessions.map(\.id), [second.id])
        XCTAssertTrue(store.previousSessions.isEmpty)
    }
}

private struct NoWrites: MacProxyPreferences {
    func edit(serviceID: String?, _ operation: (MacProxyService, [String: Any], ([String: Any]) throws -> Void) throws -> String) throws -> String {
        XCTFail("Session actions must not modify system settings")
        return ""
    }
}
