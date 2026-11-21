import AppKit
import Compression
import CoreFoundation
import SwiftUI
import zlib

enum SessionInspectorSelection: Equatable, Sendable {
    case overview
    case headers
    case request(SessionBodyPresentation)
    case response(SessionBodyPresentation)
}

enum SessionBodyPresentation: String, Codable, Identifiable, Sendable {
    case automatic = "自动"
    case formatted = "格式化"
    case raw = "文本"
    case hexadecimal = "十六进制"

    var id: Self { self }
}

struct SessionInspector: View {
    let session: CaptureSession
    var isArchive = false
    var externalSelection: SessionInspectorSelection?
    var selectionRevision = 0
    var updateNote: ((String) -> Void)?
    @State private var tab: DetailTab = .overview
    @State private var requestPresentation: SessionBodyPresentation = .automatic
    @State private var responsePresentation: SessionBodyPresentation = .automatic

    private struct SelectionUpdate: Equatable {
        let sessionID: UUID
        let selection: SessionInspectorSelection?
        let revision: Int
    }

    private var accent: Color { WorkspaceTheme.accent }

    var body: some View {
        VStack(spacing: 0) {
            title
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 16)
            tabBar
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .overview:
                        overview
                    case .request:
                        request
                    case .response:
                        response
                    case .notes:
                        TextEditor(text: Binding(get: { session.userNote ?? "" }, set: { updateNote?($0) }))
                            .disabled(updateNote == nil)
                            .font(.body)
                            .frame(minHeight: 145)
                            .accessibilityLabel("会话备注")
                            .padding(8)
                            .inspectorCard()
                        Text("备注随流迹会话文件保存。").font(.caption).foregroundStyle(.secondary)
                    case .headers:
                        HeaderSection(title: "请求标头", headers: session.requestHeaders)
                        HeaderSection(title: "响应标头", headers: session.responseHeaders)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
            .id(tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: SelectionUpdate(sessionID: session.id, selection: externalSelection, revision: selectionRevision), initial: true) { previous, update in
            if previous.sessionID != update.sessionID {
                requestPresentation = .automatic
                responsePresentation = .automatic
            }
            guard let selection = update.selection else { return }
            switch selection {
            case .overview:
                tab = .overview
            case .headers:
                tab = .headers
            case let .request(presentation):
                requestPresentation = presentation
                tab = .request
            case let .response(presentation):
                responsePresentation = presentation
                tab = .response
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(session.method)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                Text(session.isTunnel ? (URLComponents(string: session.url)?.host ?? session.url) : session.route)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.13), in: Capsule())
            }
            HStack(spacing: 8) {
                Image(systemName: session.isTunnel ? "lock" : "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(session.url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(session.url)
                Spacer(minLength: 2)
                InspectorCopyButton(value: session.url, label: "复制 URL")
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 5) {
            ForEach(DetailTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(.subheadline.weight(tab == item ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(tab == item ? accent : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .background(tab == item ? accent.opacity(0.13) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var overview: some View {
        HStack(spacing: 8) {
            InspectorMetric(label: session.isTunnel ? "持续时间" : "耗时",
                            symbol: "clock", value: session.elapsed.map(SessionFormat.duration) ?? "—")
            InspectorMetric(label: session.isTunnel ? "下行数据" : "响应大小",
                            symbol: "arrow.down", value: SessionFormat.bytes(session.responseBytes))
            if session.isTunnel {
                InspectorMetric(label: "上行数据", symbol: "arrow.up",
                                value: session.tunnelUploadBytes.map(SessionFormat.bytes) ?? "—")
            } else {
                InspectorMetric(label: "协议", symbol: "point.3.connected.trianglepath.dotted", value: transport)
            }
        }

        if let error = session.error {
            InspectorNotice(symbol: "exclamationmark.circle", title: failureTitle, detail: error, color: WorkspaceTheme.failure)
        } else if session.isTunnel {
            tunnelNotice
        }

        let warnings = session.warnings.filter { $0 != session.error }
        if !warnings.isEmpty {
            InspectorNotice(symbol: "exclamationmark.triangle", title: "会话提示", detail: warnings.joined(separator: "\n"), color: WorkspaceTheme.warning)
        }
        let ruleNotes = session.ruleNotes.filter { $0 != session.error }
        if !ruleNotes.isEmpty {
            InspectorNotice(symbol: "wrench.and.screwdriver", title: "命中规则",
                            detail: ruleNotes.joined(separator: "\n"), color: accent)
        }

        InspectorGroup(title: "连接信息") {
            InspectorValueRow(label: "主机", value: session.host)
            if session.clientProcessChecked == true {
                Divider().padding(.leading, 12)
                InspectorValueRow(label: "客户端进程", value: session.clientProcess?.label ?? "未知")
            }
            if let device = session.device {
                Divider().padding(.leading, 12)
                InspectorValueRow(label: "接入来源", value: device.title)
            }
            Divider().padding(.leading, 12)
            InspectorValueRow(label: "开始时间", value: session.startedAt.formatted(
                .dateTime.month().day().hour().minute().second()
            ))
            if let contentType = contentType(from: session.responseHeaders) {
                Divider().padding(.leading, 12)
                InspectorValueRow(label: "内容类型", value: contentType)
            }
        }

        if !session.isTunnel,
           let items = URLComponents(string: session.url)?.queryItems, !items.isEmpty {
            InspectorGroup(title: "查询参数", count: items.count) {
                ForEach(items.indices, id: \.self) { index in
                    if index > 0 { Divider().padding(.leading, 12) }
                    InspectorValueRow(label: items[index].name, value: items[index].value ?? "")
                }
            }
        }
    }

    @ViewBuilder
    private var request: some View {
        if session.isTunnel {
            tunnelNotice
        } else {
            BodySection(title: "请求正文", data: session.requestBody,
                        headers: session.requestPreviewHeaders,
                        capturedBytes: session.requestBodyBytes ?? session.requestBody.count,
                        emptyMessage: session.finished ? "此请求没有正文。" : "暂未捕获请求正文。",
                        mode: $requestPresentation)
        }
    }

    @ViewBuilder
    private var response: some View {
        if let error = session.error {
            InspectorNotice(symbol: "exclamationmark.circle", title: failureTitle, detail: error, color: WorkspaceTheme.failure)
        }
        if session.isTunnel {
            tunnelNotice
        } else {
            BodySection(title: "响应正文", data: session.responseBody,
                        headers: session.responsePreviewHeaders,
                        capturedBytes: session.responseBytes,
                        emptyMessage: emptyResponseMessage,
                        mode: $responsePresentation)
        }
    }

    private var tunnelNotice: some View {
        InspectorNotice(symbol: "lock.shield", title: "HTTPS 隧道",
                        detail: "此会话记录 CONNECT 连接。隧道内的 HTTPS 内容保持加密。", color: accent)
    }

    private var transport: String {
        return session.responseHTTPVersion ?? session.requestHTTPVersion ?? URLComponents(string: session.url)?.scheme?.uppercased() ?? "HTTP"
    }

    private var emptyResponseMessage: String {
        if session.finished { return "此响应没有正文。" }
        return isArchive ? "归档保存时暂无响应正文。" : "等待接收响应正文。"
    }

    private var status: String {
        if let code = session.statusCode { return String(code) }
        if session.error != nil { return "失败" }
        if session.finished { return "已结束" }
        return isArchive ? "记录未完成" : "进行中"
    }

    private var statusColor: Color {
        if session.error != nil { return WorkspaceTheme.failure }
        guard let code = session.statusCode else { return WorkspaceTheme.muted }
        switch code {
        case 200..<300: return WorkspaceTheme.good
        case 300..<400: return WorkspaceTheme.blue
        case 400..<500: return WorkspaceTheme.warning
        case 500..<600: return WorkspaceTheme.failure
        default: return WorkspaceTheme.muted
        }
    }

    private var failureTitle: String { session.statusCode == 403 ? "请求已拦截" : "转发失败" }

    private func contentType(from headers: [CaptureHeader]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "概览"
    case request = "请求"
    case response = "响应"
    case headers = "标头"
    case notes = "备注"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .notes: return "note.text"
        case .overview: return "square.grid.2x2"
        case .request: return "arrow.up.right"
        case .response: return "arrow.down.left"
        case .headers: return "list.bullet.indent"
        }
    }
}

private struct InspectorMetric: View {
    let label: String
    let symbol: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.headline, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorCard()
    }
}

private struct InspectorNotice: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct HeaderSection: View {
    let title: String
    let headers: [CaptureHeader]

    var body: some View {
        InspectorGroup(title: title, count: headers.count) {
            if headers.isEmpty {
                Text("暂无标头")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ForEach(headers.indices, id: \.self) { index in
                    if index > 0 { Divider().padding(.leading, 12) }
                    InspectorValueRow(label: headers[index].name, value: headers[index].value)
                }
            }
        }
    }
}

private struct InspectorGroup<Content: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(title).font(.subheadline.weight(.semibold))
                if let count {
                    Text(count, format: .number)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .inspectorCard()
        }
    }
}

private struct InspectorValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 116, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct BodySection: View {
    @EnvironmentObject private var preferences: ViewPreferences
    let title: String
    let data: Data
    let headers: [CaptureHeader]
    let capturedBytes: Int
    let emptyMessage: String
    @Binding var mode: SessionBodyPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if !data.isEmpty {
                    Text(SessionFormat.bytes(capturedBytes))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if data.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .inspectorCard()
            } else {
                let preview = BodyPreview(data: data, headers: headers, preferredMode: preferences.presentation(for: headers, override: mode))
                previewCard(preview)
            }
        }
    }

    private func previewCard(_ preview: BodyPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("正文格式", selection: Binding(get: { mode == .automatic ? .automatic : preview.mode }, set: { mode = $0 })) {
                    Text("自动").tag(SessionBodyPresentation.automatic)
                    ForEach(preview.modes) { choice in Text(choice.rawValue).tag(choice) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer(minLength: 0)
                InspectorCopyButton(value: preview.text, label: "复制预览")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            Divider()

            if preview.mode == .hexadecimal {
                ScrollView(.horizontal) {
                    code(preview.text).fixedSize(horizontal: true, vertical: false)
                }
            } else {
                code(preview.text)
            }

            if preview.truncated || capturedBytes > data.count {
                Divider()
                Text(preview.truncated ? "当前格式仅显示正文开头。" : "会话仅保留正文的前 \(SessionFormat.bytes(data.count))。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
        .inspectorCard()
    }

    private func code(_ value: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .monospaced))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }
}

private struct BodyPreview {
    let modes: [SessionBodyPresentation]
    let mode: SessionBodyPresentation
    let text: String
    let truncated: Bool

    init(data: Data, headers: [CaptureHeader], preferredMode: SessionBodyPresentation) {
        let raw = CaptureBodyDecoding.previewText(data, headers: headers)
        let formatted = raw.flatMap(Self.formattedJSON)
        var modes: [SessionBodyPresentation] = []
        if formatted != nil { modes.append(.formatted) }
        if raw != nil { modes.append(.raw) }
        modes.append(.hexadecimal)
        self.modes = modes
        mode = modes.contains(preferredMode) ? preferredMode : modes[0]

        if mode == .hexadecimal {
            let limit = 4_096
            text = Self.hexDump(data.prefix(limit))
            truncated = data.count > limit
        } else {
            let limit = 40_000
            let content = (mode == .formatted ? formatted : raw) ?? ""
            let prefix = content.prefix(limit)
            text = String(prefix)
            truncated = prefix.endIndex != content.endIndex
        }
    }

    private static func formattedJSON(_ text: String) -> String? {
        guard text.utf8.count <= 256_000,
              let first = text.first(where: { !$0.isWhitespace }),
              first == "{" || first == "[",
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private static func hexDump(_ data: Data) -> String {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02X", Int($0)) }.joined(separator: " ")
            let visible = row.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            return String(format: "%04X", offset) + "  " + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + visible
        }.joined(separator: "\n")
    }
}

enum CaptureBodyDecoding {
    private static let decodedLimit = 512 * 1024

    static func previewText(_ data: Data, headers: [CaptureHeader]) -> String? {
        let type = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        return decode(data, headers: headers).flatMap { text($0, contentType: type) }
    }

    static func text(_ data: Data, contentType: String?) -> String? {
        let encoding = contentType?.split(separator: ";").compactMap { parameter -> String.Encoding? in
            let pieces = parameter.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else { return nil }
            let name = pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard encoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        }.first ?? .utf8

        guard let value = String(data: data, encoding: encoding),
              !value.unicodeScalars.contains(where: { scalar in
                  switch scalar.value {
                  case 9, 10, 13: return false
                  case 0..<32, 127...159: return true
                  default: return false
                  }
              }) else { return nil }
        return value
    }

    static func decode(_ data: Data, headers: [CaptureHeader]) -> Data? {
        let encodings = headers
            .filter { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
            .flatMap { $0.value.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .reversed()
        var decoded = data
        for encoding in encodings {
            let inflated: Data?
            switch encoding {
            case "identity": continue
            case "gzip", "x-gzip": inflated = inflateBody(decoded, windowBits: MAX_WBITS + 16)
            case "deflate": inflated = inflateBody(decoded, windowBits: MAX_WBITS)
                ?? inflateBody(decoded, windowBits: -MAX_WBITS)
            case "br": inflated = decodeBrotli(decoded)
            default: return nil
            }
            guard let inflated else { return nil }
            decoded = inflated
        }
        return decoded
    }

    private static func inflateBody(_ data: Data, windowBits: Int32) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data(count: decodedLimit)
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.avail_in == 0 else { return nil }
        return output.prefix(Int(stream.total_out))
    }

    private static func decodeBrotli(_ data: Data) -> Data? {
        var output = Data(count: decodedLimit + 1)
        let written = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                guard let source = input.bindMemory(to: UInt8.self).baseAddress,
                      let destination = buffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destination, buffer.count, source, input.count, nil, COMPRESSION_BROTLI)
            }
        }
        guard written > 0, written <= decodedLimit else { return nil }
        return output.prefix(written)
    }

}

private struct InspectorCopyButton: View {
    let value: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: copied ? "checkmark" : "document.on.document")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? WorkspaceTheme.accent : WorkspaceTheme.muted)
                .frame(width: 21, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "已复制" : label)
        .accessibilityLabel(copied ? "已复制" : label)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.3))
            if !Task.isCancelled { copied = false }
        }
    }
}

private extension View {
    func inspectorCard() -> some View {
        background(WorkspaceTheme.chrome, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(WorkspaceTheme.rule) }
    }
}
