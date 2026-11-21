import AppKit
import Darwin
import Foundation
import Network
import SwiftUI

struct CaptureOutputOptions: Sendable {
    var archiveFolder: URL?
    var mirrorFolder: URL?
    var mirrorHost = "localhost"
}

enum CaptureOutputPage: String, Identifiable {
    case archive, mirror

    var id: Self { self }

    var title: String {
        switch self {
        case .archive: "自动保存"
        case .mirror: "响应镜像"
        }
    }
}

enum CaptureOutputWriter {
    private static let maximumMirrorBytes = 256 * 1024

    static func saveArchive(sessions: [CaptureSession], folder: URL) throws {
        guard !sessions.isEmpty else { return }
        let data = try CaptureArchiveDocument(sessions: sessions).encoded()
        try write(data, folder: folder, prefix: "流迹会话", extension: "flowsession")
    }

    static func mirror(session: CaptureSession, folder: URL) throws {
        guard matchesMirror(session: session, host: session.host) else { throw OutputError.invalidResponse }
        try write(session.responseBody, folder: folder, prefix: "响应", extension: "body")
    }

    static func matchesMirror(session: CaptureSession, host: String) -> Bool {
        guard session.finished, !session.isTunnel, session.error == nil, let status = session.statusCode,
              (200...599).contains(status), session.responseBytes == session.responseBody.count,
              (1...maximumMirrorBytes).contains(session.responseBytes),
              URLComponents(string: session.url)?.scheme?.lowercased() == "http",
              let host = normalizedLoopbackHost(host) else { return false }
        return normalizedLoopbackHost(session.host) == host
    }

    static func normalizedLoopbackHost(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" { return host }
        if let address = IPv4Address(host), address.rawValue.first == 127 { return address.debugDescription }
        if let address = IPv6Address(host), address == .loopback { return "::1" }
        return nil
    }

    private static func write(_ data: Data, folder: URL, prefix: String, extension fileExtension: String) throws {
        guard folder.isFileURL else { throw OutputError.invalidFolder }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw OutputError.invalidFolder
        }

        let identity = UUID().uuidString.lowercased()
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let output = folder.appendingPathComponent("\(prefix)-\(timestamp)-\(identity).\(fileExtension)")
        let staging = folder.appendingPathComponent(".flow-output-\(identity).tmp")
        let descriptor = staging.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR) } ?? -1
        }
        guard descriptor >= 0 else { throw OutputError.cannotWrite }
        defer { try? FileManager.default.removeItem(at: staging) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        let result = staging.withUnsafeFileSystemRepresentation { source in
            output.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return Int32(-1) }
                return renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw OutputError.cannotWrite }
    }

    private enum OutputError: LocalizedError {
        case invalidFolder, invalidResponse, cannotWrite

        var errorDescription: String? {
            switch self {
            case .invalidFolder: "请选择本机文件夹。"
            case .invalidResponse: "当前响应缺少完整的本机 HTTP 正文。"
            case .cannotWrite: "无法在所选文件夹中写入新文件。"
            }
        }
    }
}

struct CaptureOutputSettingsSheet: View {
    let page: CaptureOutputPage
    let onSave: (CaptureOutputOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CaptureOutputOptions

    init(page: CaptureOutputPage, options: CaptureOutputOptions, onSave: @escaping (CaptureOutputOptions) -> Void) {
        self.page = page
        self.onSave = onSave
        _draft = State(initialValue: options)
    }

    private var folder: URL? {
        get { page == .archive ? draft.archiveFolder : draft.mirrorFolder }
        nonmutating set {
            switch page {
            case .archive: draft.archiveFolder = newValue
            case .mirror: draft.mirrorFolder = newValue
            }
        }
    }

    private var hostError: Bool {
        page == .mirror && folder != nil && CaptureOutputWriter.normalizedLoopbackHost(draft.mirrorHost) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text(page.title)
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(page == .archive
                     ? "暂停录制或停止代理时，将当前抓包保存为流迹会话。"
                     : "将指定回环主机的完整明文 HTTP 响应正文保存到文件。")
                    .foregroundStyle(WorkspaceTheme.muted)
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(WorkspaceTheme.accent)
                    Text(folder?.path ?? "未选择文件夹")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(folder?.path ?? "")
                    Button("选择文件夹…", action: chooseFolder)
                    if folder != nil {
                        Button("关闭输出") { folder = nil }
                    }
                }

                if page == .mirror {
                    TextField("匹配主机", text: $draft.mirrorHost, prompt: Text("localhost"))
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
                if hostError {
                    Label("输入 localhost、127.0.0.1 或其他回环 IP。", systemImage: "exclamationmark.circle")
                        .foregroundStyle(WorkspaceTheme.warning)
                }
            }
            .padding(11)
            .background(WorkspaceTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let host = CaptureOutputWriter.normalizedLoopbackHost(draft.mirrorHost) {
                        draft.mirrorHost = host
                    }
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hostError)
            }
        }
        .font(.system(size: 12))
        .padding(21)
        .frame(width: 500)
        .foregroundStyle(WorkspaceTheme.ink)
        .background(WorkspaceTheme.canvas)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择输出文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.begin { result in
            guard result == .OK, let selected = panel.url else { return }
            folder = selected
        }
    }
}
