import XCTest
@testable import PacketScope

final class ViewPreferencesTests: XCTestCase {
    @MainActor
    func testHighlightConditionsUseHostBoundaryPathWithoutQueryAndStatusClass() throws {
        let suite = "test.view-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ViewPreferences(defaults: defaults)
        let specific = HighlightRule(host: "*.example.test", path: "/api/*", status: "5xx", color: .red)
        let fallback = HighlightRule(status: "503", color: .orange)
        preferences.save(specific)
        preferences.save(fallback)
        func session(_ url: String, status: Int? = 503) -> CaptureSession {
            var result = CaptureSession(id: UUID(), startedAt: Date(), method: "GET", url: url, requestHeaders: [])
            result.statusCode = status
            return result
        }
        XCTAssertEqual(preferences.highlight(for: session("https://a.example.test/api/v1?q=/wrong")), .red)
        XCTAssertEqual(preferences.highlight(for: session("https://notexample.test/api/v1")), .orange)
        XCTAssertEqual(preferences.highlight(for: session("https://a.example.test/api2/v1")), .orange)
        XCTAssertNil(preferences.highlight(for: session("https://a.example.test/api/v1", status: nil)))
        let reopened = ViewPreferences(defaults: defaults)
        XCTAssertEqual(reopened.highlights, [specific, fallback])
        reopened.remove(specific.id, from: .highlights)
        XCTAssertEqual(ViewPreferences(defaults: defaults).highlights, [fallback])
        XCTAssertNotNil(HighlightRule(path: "api").validationError)
        XCTAssertNotNil(HighlightRule(status: "999").validationError)
    }

    @MainActor
    func testMappingsHaveOneEntryPerMIMEAndExplicitSessionChoiceWins() throws {
        let suite = "test.viewer-mappings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pref = ViewPreferences(defaults: defaults)
        pref.save(ViewerMapping(mime: "application/json", viewer: .formatted))
        let item = ViewerMapping(mime: "APPLICATION/JSON", viewer: .hexadecimal)
        pref.save(item)
        let headers = [CaptureHeader(name: "content-TYPE", value: "Application/JSON; charset=UTF-8")]
        XCTAssertEqual(pref.mappings.count, 1)
        XCTAssertEqual(pref.presentation(for: headers, override: .automatic), .hexadecimal)
        XCTAssertEqual(pref.presentation(for: headers, override: .raw), .raw)
        XCTAssertEqual(pref.presentation(for: [], override: .automatic), .automatic)
        let reopened = ViewPreferences(defaults: defaults)
        XCTAssertEqual(reopened.presentation(for: headers, override: .automatic), .hexadecimal)
        reopened.remove(item.id, from: .mappings)
        XCTAssertTrue(ViewPreferences(defaults: defaults).mappings.isEmpty)
    }
}
