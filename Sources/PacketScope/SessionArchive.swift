import Darwin
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let packetScopeSession = UTType(exportedAs: "local.packetscope.mac.session", conformingTo: .json)
    static let packetScopeHAR = UTType(exportedAs: "local.packetscope.mac.har", conformingTo: .json)
}

struct CaptureArchiveDocument: Sendable {
    static let contentType: UTType = .packetScopeSession

    var sessions: [CaptureSession]

    init(sessions: [CaptureSession]) {
        self.sessions = sessions
    }

    static func read(from url: URL) throws -> Self {
        try decode(readFile(url, limit: CaptureArchive.maximumFileBytes))
    }

    static func readFile(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL else { throw CaptureArchiveError.notRegular }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw CaptureArchiveError.cannotRead }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw CaptureArchiveError.cannotRead }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw CaptureArchiveError.notRegular }
        guard metadata.st_size <= limit else { throw CaptureArchiveError.tooLarge }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CaptureArchiveError.tooLarge }
        return data
    }

    func encoded() throws -> Data {
        try CaptureArchive.validate(sessions)
        let base64Bytes = sessions.reduce(0) { size, session in
            size + [session.requestBody.count, session.responseBody.count].reduce(0) { $0 + ($1 + 2) / 3 * 4 }
        }
        guard base64Bytes <= CaptureArchive.maximumFileBytes else { throw CaptureArchiveError.tooLarge }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .withoutEscapingSlashes
        let encoded = try encoder.encode(CaptureArchive(sessions: sessions))
        guard encoded.count <= CaptureArchive.maximumFileBytes else { throw CaptureArchiveError.tooLarge }
        return encoded
    }

    private static func decode(_ data: Data) throws -> Self {
        guard data.count <= CaptureArchive.maximumFileBytes else { throw CaptureArchiveError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return Self(sessions: try decoder.decode(CaptureArchive.self, from: data).sessions)
        } catch let error as CaptureArchiveError {
            throw error
        } catch {
            throw CaptureArchiveError.invalid
        }
    }
}

struct CaptureArchive: Codable {
    static let maximumFileBytes = 128 * 1024 * 1024
    static let maximumSessions = 2_000
    private static let formatName = "PacketScope Session Archive"
    private static let currentVersion = 1

    let format: String
    let version: Int
    let sessions: [CaptureSession]

    init(sessions: [CaptureSession]) {
        format = Self.formatName
        version = Self.currentVersion
        self.sessions = sessions
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        format = try root.decode(String.self, forKey: .format)
        guard format == Self.formatName else { throw CaptureArchiveError.invalid }
        version = try root.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw CaptureArchiveError.unsupportedVersion(version) }

        var container = try root.nestedUnkeyedContainer(forKey: .sessions)
        if let count = container.count, count > Self.maximumSessions { throw CaptureArchiveError.tooManySessions }
        var sessions: [CaptureSession] = []
        while !container.isAtEnd {
            guard sessions.count < Self.maximumSessions else { throw CaptureArchiveError.tooManySessions }
            sessions.append(try container.decode(CaptureSession.self))
        }
        try Self.validate(sessions)
        self.sessions = sessions
    }

    static func validate(_ sessions: [CaptureSession]) throws {
        guard sessions.count <= maximumSessions else { throw CaptureArchiveError.tooManySessions }
        var identifiers = Set<UUID>()
        var totalBytes = 0
        for session in sessions {
            let (sum, overflow) = totalBytes.addingReportingOverflow(session.responseBytes)
            guard !overflow else { throw CaptureArchiveError.invalid }
            totalBytes = sum
            let date = session.startedAt.timeIntervalSince1970
            guard identifiers.insert(session.id).inserted,
                  (-62_135_596_800...253_402_300_799).contains(date),
                  session.elapsed.map({ ($0 * 1_000).isFinite && $0 * 1_000 >= Double(Int.min) }) ?? true,
                  session.responseBytes >= session.responseBody.count,
                  session.requestBodyBytes.map({ $0 >= session.requestBody.count }) ?? true,
                  session.statusCode.map({ (100...599).contains($0) }) ?? true else {
                throw CaptureArchiveError.invalid
            }
        }
    }
}

enum CaptureArchiveError: LocalizedError {
    case notRegular
    case cannotRead
    case invalid
    case unsupportedVersion(Int)
    case tooLarge
    case tooManySessions

    var errorDescription: String? {
        switch self {
        case .notRegular: "请选择常规的流迹会话文件。"
        case .cannotRead: "无法读取会话文件。"
        case .invalid: "会话文件的格式或数据无效。"
        case let .unsupportedVersion(version): "当前流迹版本无法打开第 \(version) 版会话档案。"
        case .tooLarge: "流迹会话文件最大支持 128 MiB。"
        case .tooManySessions: "单个流迹会话文件最多支持 2,000 条记录。"
        }
    }
}

struct HARExportDocument: Sendable {
    static let contentType: UTType = .packetScopeHAR

    private let sessions: [CaptureSession]

    init(sessions: [CaptureSession]) {
        self.sessions = sessions
    }

    func encoded() throws -> Data {
        let timestamps = ISO8601DateFormatter()
        timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries = sessions
            .filter { !$0.isTunnel && $0.method != "CONNECT" }
            .sorted { $0.startedAt < $1.startedAt }
            .map { HAREntry(session: $0, timestamps: timestamps) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let archive = HARArchive(log: HARLog(creator: .init(name: "流迹", version: version), entries: entries))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(archive)
    }
}

private struct HARArchive: Encodable {
    let log: HARLog
}

private struct HARLog: Encodable {
    struct Creator: Encodable {
        let name: String
        let version: String
    }

    let version = "1.2"
    let creator: Creator
    let entries: [HAREntry]
}

private struct HAREntry: Encodable {
    struct Cache: Encodable {}

    struct Timings: Encodable {
        let send = 0
        let wait: Double
        let receive = 0
        let comment: String
    }

    let startedDateTime: String
    let time: Double
    let request: HARRequest
    let response: HARResponse
    let cache = Cache()
    let timings: Timings
    let comment: String?

    init(session: CaptureSession, timestamps: ISO8601DateFormatter) {
        startedDateTime = timestamps.string(from: session.startedAt)
        let elapsed = session.elapsed.map { $0 * 1_000 }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        time = elapsed ?? 0
        let timingNote = elapsed == nil
            ? "耗时未知。HAR 必填阶段使用 0 表示未测量。"
            : "wait 保存代理记录的总耗时。send、wait 和 receive 未单独测量。"
        timings = Timings(wait: time, comment: timingNote)
        request = HARRequest(session: session)
        response = HARResponse(session: session, timestamps: timestamps)
        var notes = session.ruleNotes.filter { $0 != session.error }
        if let error = session.error { notes.append(error) }
        if let note = session.userNote { notes.append(note) }
        if !session.finished { notes.append("导出时此会话仍在进行。") }
        comment = notes.isEmpty ? nil : notes.joined(separator: "\n")
    }
}

private struct HARPair: Encodable {
    let name: String
    let value: String

    static func cookieField(_ field: Substring) -> Self? {
        guard let equals = field.firstIndex(of: "=") else { return nil }
        let name = field[..<equals].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let value = field[field.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return Self(name: name, value: value)
    }
}

private struct HARCookie: Encodable {
    let name: String
    let value: String
    var path: String?
    var domain: String?
    var expires: String?
    var httpOnly: Bool?
    var secure: Bool?
}

private struct HARRequest: Encodable {
    struct PostData: Encodable {
        let mimeType: String
        let text: String?
        let comment: String?
    }

    let method: String
    let url: String
    let httpVersion: String
    let headers: [CaptureHeader]
    let cookies: [HARCookie]
    let queryString: [HARPair]
    let headersSize = -1
    let bodySize: Int
    let postData: PostData?

    init(session: CaptureSession) {
        method = session.method
        url = session.url
        httpVersion = session.requestHTTPVersion ?? ""
        headers = session.requestHeaders
        cookies = headers.values("Cookie").flatMap { value in
            value.split(separator: ";").compactMap(HARPair.cookieField)
                .map { HARCookie(name: $0.name, value: $0.value) }
        }
        queryString = (URLComponents(string: url)?.queryItems ?? []).map {
            HARPair(name: $0.name, value: $0.value ?? "")
        }

        let data = session.requestBody
        let declaredLength = headers.firstValue("Content-Length").flatMap(Int.init)
        if session.finished, let count = session.requestBodyBytes {
            bodySize = session.harRequestBody?.wireBytes ?? count
        } else if session.finished, declaredLength == data.count {
            bodySize = data.count
        } else {
            bodySize = -1
        }
        guard bodySize > 0 || !data.isEmpty || (declaredLength ?? 0) > 0 else {
            postData = nil
            return
        }
        let mimeType = session.harRequestBody?.mimeType ?? headers.firstValue("Content-Type") ?? "application/octet-stream"
        let complete = session.finished && (session.harRequestBody != nil || (declaredLength.map { $0 == data.count } ?? true))
        guard complete, (session.requestBodyBytes ?? bodySize) == data.count else {
            postData = PostData(mimeType: mimeType, text: nil, comment: "请求正文只捕获了一部分。")
            return
        }
        let decoded = session.requestPreviewHeaders.decodedBody(data)
        let text = decoded.flatMap { CaptureBodyDecoding.text($0, contentType: session.harRequestBody?.previewType ?? mimeType) }
        postData = PostData(mimeType: mimeType, text: text, comment: text == nil ? "HAR 仅包含可解码的文本请求正文。" : nil)
    }
}

private struct HARResponse: Encodable {
    struct Content: Encodable {
        let size: Int
        let mimeType: String
        let text: String?
        let encoding: String?
        let comment: String?
    }

    let status: Int
    let statusText: String
    let httpVersion: String
    let headers: [CaptureHeader]
    let cookies: [HARCookie]
    let content: Content
    let redirectURL: String
    let headersSize = -1
    let bodySize: Int

    init(session: CaptureSession, timestamps: ISO8601DateFormatter) {
        status = session.statusCode ?? 0
        statusText = session.responseStatusText ?? ""
        httpVersion = session.responseHTTPVersion ?? ""
        headers = session.responseHeaders
        let url = URL(string: session.url)
        cookies = headers.values("Set-Cookie").compactMap { value in
            let fields = value.split(separator: ";", omittingEmptySubsequences: false)
            guard let first = fields.first, let pair = HARPair.cookieField(first) else { return nil }
            let attributes = fields.dropFirst()
            let options = attributes.compactMap(HARPair.cookieField)
            let flags = attributes.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let expiry = url.flatMap {
                HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: $0).first?.expiresDate
            }
            return HARCookie(
                name: pair.name, value: pair.value,
                path: options.first { $0.name.caseInsensitiveCompare("Path") == .orderedSame }?.value,
                domain: options.first { $0.name.caseInsensitiveCompare("Domain") == .orderedSame }?.value,
                expires: expiry.map(timestamps.string(from:)), httpOnly: flags.contains("httponly"), secure: flags.contains("secure")
            )
        }
        redirectURL = headers.firstValue("Location") ?? ""

        let noBody = session.method == "HEAD" || status == 204 || status == 304
        bodySize = status == 0 || !session.finished ? -1 : (noBody ? 0 : session.harResponseBody?.wireBytes ?? session.responseBytes)
        let mimeType = session.harResponseBody?.mimeType ?? headers.firstValue("Content-Type") ?? "application/octet-stream"
        let data = session.responseBody
        if noBody || (bodySize == 0 && data.isEmpty) {
            content = Content(size: 0, mimeType: mimeType, text: nil, encoding: nil, comment: nil)
        } else if session.responseBytes == data.count, session.finished, status != 0, session.error == nil,
                  let decoded = session.responsePreviewHeaders.decodedBody(data) {
            let text = CaptureBodyDecoding.text(decoded, contentType: session.harResponseBody?.previewType ?? mimeType)
            content = Content(
                size: decoded.count, mimeType: mimeType,
                text: text ?? decoded.base64EncodedString(), encoding: text == nil ? "base64" : nil,
                comment: nil
            )
        } else {
            let contentSize = headers.needsBodyDecoding ? 0 : max(bodySize, 0)
            let note: String
            if bodySize < 0 || session.error != nil {
                note = "响应正文不可用或响应未完成。"
            } else if bodySize > data.count {
                note = "响应正文只捕获了一部分。"
            } else {
                note = "未能解码响应正文。"
            }
            content = Content(size: contentSize, mimeType: mimeType, text: nil, encoding: nil, comment: note)
        }
    }
}

private extension [CaptureHeader] {
    func values(_ name: String) -> [String] {
        compactMap { $0.name.caseInsensitiveCompare(name) == .orderedSame ? $0.value : nil }
    }

    func firstValue(_ name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var needsBodyDecoding: Bool {
        !codings("Content-Encoding").allSatisfy { $0 == "identity" } ||
        !codings("Transfer-Encoding").allSatisfy { $0 == "identity" || $0 == "chunked" }
    }

    func decodedBody(_ data: Data) -> Data? {
        guard codings("Transfer-Encoding").allSatisfy({ $0 == "identity" || $0 == "chunked" }) else { return nil }
        return CaptureBodyDecoding.decode(data, headers: self)
    }

    private func codings(_ name: String) -> [String] {
        values(name).flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}
