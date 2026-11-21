import Foundation

enum TunnelActivity: String, Codable, Sendable {
    case upload, download
}

enum CaptureDevice: String, Codable, Sendable {
    case mac, phone
    var title: String { self == .phone ? "手机" : "Mac" }
}

struct CaptureHeader: Codable, Sendable {
    let name: String
    let value: String
}

struct CaptureSession: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let method: String
    let url: String
    var requestHeaders: [CaptureHeader]
    var requestBody = Data()
    var statusCode: Int?
    var responseHeaders: [CaptureHeader] = []
    var responseBody = Data()
    var responseBytes = 0
    var elapsed: TimeInterval?
    var error: String?
    var isTunnel = false
    var finished = false
    var ruleNotes: [String] = []
    var requestHTTPVersion: String?
    var responseHTTPVersion: String?
    var responseStatusText: String?
    var requestBodyBytes: Int?
    var tunnelActivity: TunnelActivity?
    var tunnelUploadBytes: Int?
    var userNote: String?
    var warnings: [String] {
        var values = error.map { [$0] } ?? []
        if !isTunnel {
            if let bytes = requestBodyBytes, bytes > requestBody.count && harRequestBody == nil {
                values.append("请求正文仅保留了部分预览。")
            }
            if responseBytes > responseBody.count && harResponseBody == nil {
                values.append("响应正文仅保留了部分预览。")
            }
        }
        return values
    }
    var isPausedAtBreakpoint: Bool?
    var breakpointPhase: BreakpointPhase?
    var allowsBreakpointHeaderEdit: Bool?
    var clientProcess: LocalClientProcess?
    var clientProcessChecked: Bool?
    var harRequestBody: HARImportedBody?
    var harResponseBody: HARImportedBody?
    var requestPreviewHeaders: [CaptureHeader] { harRequestBody?.previewHeaders ?? requestHeaders }
    var responsePreviewHeaders: [CaptureHeader] { harResponseBody?.previewHeaders ?? responseHeaders }
    var device: CaptureDevice?

    private var components: URLComponents? { URLComponents(string: url) }

    var host: String { components?.host ?? url }

    var route: String {
        guard let components, !isTunnel else { return url }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    }
}

enum SessionFormat {
    static func bytes(_ count: Int) -> String {
        if count < 1_000 { return "\(count) B" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .decimal)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int(seconds * 1_000)) ms" }
        return seconds.formatted(.number.precision(.fractionLength(1...2))) + " s"
    }
}
