import Foundation

/// HAR payloads are already content-decoded. Keep wire headers for inspection.
struct HARImportedBody: Codable, Sendable {
    let mimeType: String
    let utf8Text: Bool
    let wireBytes: Int
    var previewType: String {
        utf8Text ? (mimeType.components(separatedBy: ";").first ?? mimeType) + "; charset=utf-8" : mimeType
    }
    var previewHeaders: [CaptureHeader] { [CaptureHeader(name: "Content-Type", value: previewType)] }
}

enum HARImport {
    private struct Archive: Decodable {
        struct Log: Decodable {
            let version: String
            let entries: [Entry]
            enum CodingKeys: String, CodingKey { case version, entries }
            init(from decoder: Decoder) throws {
                let root = try decoder.container(keyedBy: CodingKeys.self)
                version = try root.decode(String.self, forKey: .version)
                guard version == "1.2" else { throw failure("支持导入 HAR 1.2 文件。") }
                var list = try root.nestedUnkeyedContainer(forKey: .entries)
                var entries = [Entry]()
                guard (list.count ?? 0) <= 2_000 else { throw CaptureArchiveError.tooManySessions }
                while !list.isAtEnd {
                    guard entries.count < 2_000 else { throw CaptureArchiveError.tooManySessions }
                    entries.append(try list.decode(Entry.self))
                }
                self.entries = entries
            }
        }
        let log: Log
    }
    private struct Entry: Decodable {
        struct Body: Decodable {
            let text: String?
            let mimeType: String?
            let size: Int?
            let encoding: String?
            func preview() throws -> (Data, Int) {
                guard let text else { return (Data(), 0) }
                let bytes: Data
                switch encoding?.lowercased() {
                case .none, "":
                    var prefix = text.utf8.prefix(512 * 1024)
                    while prefix.endIndex.samePosition(in: text.unicodeScalars) == nil { prefix = prefix.dropLast() }
                    return (Data(prefix), text.utf8.count)
                case "base64":
                    guard let decoded = Data(base64Encoded: text) else { throw failure("HAR 中的 Base64 正文无效。") }
                    bytes = decoded
                default: throw failure("HAR 中包含不支持的正文编码。")
                }
                return (Data(bytes.prefix(512 * 1024)), bytes.count)
            }
        }
        struct Request: Decodable {
            let method: String
            let url: String
            let httpVersion: String?
            let headers: [CaptureHeader]
            let bodySize: Int?
            let postData: Body?
        }
        struct Response: Decodable {
            let status: Int
            let statusText: String?
            let httpVersion: String?
            let headers: [CaptureHeader]
            let bodySize: Int?
            let content: Body
        }
        let startedDateTime: String
        let time: Double
        let request: Request
        let response: Response
        let comment: String?
    }

    static func read(_ url: URL) throws -> [CaptureSession] {
        let data = try CaptureArchiveDocument.readFile(url, limit: 128 * 1024 * 1024)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [CaptureSession] {
        guard data.count <= 128 * 1024 * 1024 else { throw CaptureArchiveError.tooLarge }
        let archive: Archive
        do { archive = try JSONDecoder().decode(Archive.self, from: data) }
        catch is DecodingError { throw failure("请选择包含 log 和 entries 的有效 HAR 1.2 文件。") }
        let timestamps = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        let sessions = try archive.log.entries.map { entry in
            let req = entry.request, res = entry.response
            guard let date = fractional.date(from: entry.startedDateTime) ?? timestamps.date(from: entry.startedDateTime),
                  let parts = URLComponents(string: req.url), let scheme = parts.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), parts.host?.isEmpty == false,
                  !req.method.isEmpty, entry.time.isFinite, entry.time >= -1,
                  res.status == 0 || (100...599).contains(res.status) else { throw failure("HAR 含有无效的日期、URL、状态或耗时。") }
            var session = CaptureSession(id: UUID(), startedAt: date, method: req.method, url: req.url, requestHeaders: req.headers)
            let (input, inputBytes) = try req.postData?.preview() ?? (Data(), 0)
            let (output, outputBytes) = try res.content.preview()
            session.requestBody = input
            session.requestBodyBytes = req.postData?.text == nil ? max(0, req.bodySize ?? 0) : inputBytes
            session.responseBody = output
            session.responseBytes = max(0, res.content.size ?? 0, outputBytes)
            let requestMime = req.postData?.mimeType ?? req.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? "application/octet-stream"
            let responseMime = res.content.mimeType ?? res.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? "application/octet-stream"
            session.harRequestBody = HARImportedBody(mimeType: requestMime, utf8Text: req.postData?.encoding?.lowercased() != "base64", wireBytes: max(-1, req.bodySize ?? -1))
            session.harResponseBody = HARImportedBody(mimeType: responseMime, utf8Text: res.content.encoding?.lowercased() != "base64", wireBytes: max(-1, res.bodySize ?? -1))
            session.statusCode = res.status == 0 ? nil : res.status
            session.responseStatusText = res.statusText
            session.responseHeaders = res.headers
            session.requestHTTPVersion = req.httpVersion
            session.responseHTTPVersion = res.httpVersion
            session.elapsed = entry.time < 0 ? nil : entry.time / 1_000
            session.finished = true
            session.isTunnel = req.method.uppercased() == "CONNECT"
            session.ruleNotes = ["从 HAR 导入"] + (entry.comment.map { [$0] } ?? [])
            if res.status == 0 { session.error = "HAR 未记录有效响应状态。" }
            return session
        }
        try CaptureArchive.validate(sessions)
        return sessions
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "PacketScope.HAR", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
