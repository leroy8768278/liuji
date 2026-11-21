import SwiftUI
import UniformTypeIdentifiers

enum SessionFileAction: Equatable {
    case open, save, saveAs, importHAR, exportHAR, importRules, exportRules
    case saveSelection(UUID), saveResponse(UUID)
}

private enum SessionExportDocument: FileDocument {
    case archive(CaptureArchiveDocument), har(HARExportDocument)
    case response(Data), rules(RuleConfigurationDocument)

    static let readableContentTypes: [UTType] = []
    static let writableContentTypes = [CaptureArchiveDocument.contentType, HARExportDocument.contentType, .data,
                                       RuleConfigurationDocument.contentType]

    var contentType: UTType {
        switch self {
        case .archive: CaptureArchiveDocument.contentType
        case .har: HARExportDocument.contentType
        case .response: .data
        case .rules: RuleConfigurationDocument.contentType
        }
    }

    var defaultFilename: String {
        switch self {
        case .archive: "流迹会话"
        case .har: "流迹-HTTP"
        case .response: "流迹-响应预览.bin"
        case .rules: "流迹-规则"
        }
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data: Data
        switch self {
        case let .archive(archive): data = try archive.encoded()
        case let .har(har): data = try har.encoded()
        case let .response(body): data = body
        case let .rules(rules): data = try rules.encoded()
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct SessionFileFlow: ViewModifier {
    @ObservedObject var store: CaptureStore
    @State private var showImporter = false
    @State private var importAction: SessionFileAction = .open
    @State private var saveDestination: URL?
    @State private var exportingSource: CaptureSource?
    @State private var showExporter = false
    @State private var exportDocument: SessionExportDocument?
    @State private var importedRules: ProxyRuleSet?
    @State private var fileError: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: store.requestedFileAction) { _, action in
                guard let action else { return }
                store.requestedFileAction = nil
                exportingSource = nil
                switch action {
                case .open, .importRules, .importHAR:
                    importAction = action
                    showImporter = true
                case .save, .saveAs:
                    if action == .save, let destination = archiveDestination {
                        saveArchive(destination)
                        return
                    }
                    exportingSource = store.source
                    exportDocument = .archive(CaptureArchiveDocument(sessions: store.sessions))
                    showExporter = true
                case .exportHAR:
                    exportDocument = .har(HARExportDocument(sessions: store.sessions))
                    showExporter = true
                case .exportRules:
                    exportDocument = .rules(RuleConfigurationDocument(rules: store.ruleSet))
                    showExporter = true
                case let .saveSelection(id):
                    guard let session = store.sessions.first(where: { $0.id == id }) else { return }
                    exportDocument = .archive(CaptureArchiveDocument(sessions: [session]))
                    showExporter = true
                case let .saveResponse(id):
                    guard let session = store.sessions.first(where: { $0.id == id }), !session.responseBody.isEmpty else { return }
                    exportDocument = .response(session.responseBody)
                    showExporter = true
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes) { result in
                switch result {
                case let .success(url):
                    if importAction == .importRules { readRules(url) }
                    else { openArchive(url, har: importAction == .importHAR) }
                case let .failure(error): fileError = error.localizedDescription
                }
            }
            .fileExporter(isPresented: $showExporter, document: exportDocument,
                          contentType: exportDocument?.contentType ?? CaptureArchiveDocument.contentType,
                          defaultFilename: exportDocument?.defaultFilename) { result in
                switch result {
                case let .success(url) where exportingSource == store.source: saveDestination = url
                case let .failure(error): fileError = error.localizedDescription
                default: break
                }
            }
            .onChange(of: showExporter) { if !showExporter { exportDocument = nil } }
            .onChange(of: store.source) { saveDestination = nil }
            .onChange(of: store.activeSessionNumber) { saveDestination = nil }
            .onOpenURL { openArchive($0, har: $0.pathExtension.lowercased() == "har") }
            .confirmationDialog("应用导入的规则？", isPresented: Binding(get: { importedRules != nil }, set: { if !$0 { importedRules = nil } })) {
                Button("应用规则") {
                    if let importedRules { store.saveRules(importedRules) }
                    importedRules = nil
                }
            } message: {
                Text("导入的 \(importedRules?.rules.count ?? 0) 条规则将替换当前代理规则。")
            }
            .alert("无法处理文件", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
                Button("好") { fileError = nil }
            } message: {
                Text(fileError ?? "")
            }
    }

    private var importTypes: [UTType] {
        switch importAction {
        case .importRules: return [RuleConfigurationDocument.contentType]
        case .importHAR: return [UTType(filenameExtension: "har") ?? .packetScopeHAR, .packetScopeHAR]
        default: return [CaptureArchiveDocument.contentType]
        }
    }

    private var archiveDestination: URL? {
        if let saveDestination { return saveDestination }
        if case let .archive(url) = store.source, url.pathExtension.lowercased() == "flowsession" { return url }
        return nil
    }

    private func saveArchive(_ url: URL) {
        let document = CaptureArchiveDocument(sessions: store.sessions)
        store.isReadingArchive = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try document.encoded().write(to: url, options: .atomic) }
            }.value
            store.isReadingArchive = false
            if case let .failure(error) = result { fileError = error.localizedDescription }
        }
    }

    private func readRules(_ url: URL) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try RuleConfigurationDocument.read(from: url).rules }
            }.value
            switch result {
            case let .success(rules): importedRules = rules
            case let .failure(error): fileError = error.localizedDescription
            }
        }
    }

    private func openArchive(_ url: URL, har: Bool) {
        guard url.isFileURL, !store.isReadingArchive else { return }
        store.isReadingArchive = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try har ? HARImport.read(url) : CaptureArchiveDocument.read(from: url).sessions }
            }.value

            store.isReadingArchive = false
            switch result {
            case let .success(sessions): store.showArchive(sessions, url: url)
            case let .failure(error): fileError = error.localizedDescription
            }
        }
    }

}
