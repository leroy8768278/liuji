import Combine
import SwiftUI

@MainActor
struct SessionFileEditCommands: Commands {
    @ObservedObject var store: CaptureStore
    @ObservedObject private var search: WorkspaceSessionSearch

    init(store: CaptureStore) {
        self.store = store
        search = store.sessionSearch
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建会话") { store.newRecordingSession() }.keyboardShortcut("n")
                .disabled(store.isReadingArchive)
            Button("打开会话…") { store.requestedFileAction = .open }.keyboardShortcut("o")
            Button("关闭当前查看的会话") {
                if case .history = store.source, !store.sessions.isEmpty { search.confirmClose = true }
                else { store.closeViewedSession() }
            }.disabled(store.source == .live)
            Button("清空实时会话…") { search.confirmClear = true }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.source != .live || store.liveSessions.isEmpty)
        }
        CommandGroup(replacing: .saveItem) {
            Group {
                Button("保存会话") { store.requestedFileAction = .save }.keyboardShortcut("s")
                Button("会话另存为…") { store.requestedFileAction = .saveAs }.keyboardShortcut("s", modifiers: [.command, .shift])
            }.disabled(store.sessions.isEmpty || store.isReadingArchive)
            Divider()
            Button("导入 HAR…") { store.requestedFileAction = .importHAR }.disabled(store.isReadingArchive)
            Button("导出 HAR…") { store.requestedFileAction = .exportHAR }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.isReadingArchive || !store.sessions.contains { !$0.isTunnel })
        }
        CommandGroup(after: .windowList) {
            Menu("录制会话") {
                Button("会话 \(store.activeSessionNumber) · 实时") { store.showRecordingSession(store.activeSessionNumber) }
                ForEach(store.previousSessions.keys.sorted(by: >), id: \.self) { number in
                    Button("会话 \(number) · \(store.previousSessions[number]?.count ?? 0) 条") { store.showRecordingSession(number) }
                }
            }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("查找选中请求的内容…") { search.openSelection = true }.keyboardShortcut("f")
                .disabled(search.selectedID == nil)
            Button("在会话中查找…") { search.showSearch = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.sessions.isEmpty)
            Button("下一个匹配会话") { search.move(1, sessions: store.sessions) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(search.matches.isEmpty)
            Button("上一个匹配会话") { search.move(-1, sessions: store.sessions) }
                .keyboardShortcut("g", modifiers: [.command, .option, .shift])
                .disabled(search.matches.isEmpty)
        }
    }
}

@MainActor
final class WorkspaceSessionSearch: ObservableObject {
    @Published var selectedID: UUID?
    @Published var showSearch = false
    @Published var openSelection = false
    @Published var confirmClear = false
    @Published var confirmClose = false
    @Published var query = ""
    @Published private(set) var matches: [UUID] = []
    let reveal = PassthroughSubject<UUID, Never>()

    func reset() {
        matches = []
        query = ""
    }

    func setMatches(_ ids: [UUID]) { matches = ids }

    func move(_ step: Int, sessions: [CaptureSession]) {
        let available = Set(sessions.map(\.id))
        matches.removeAll { !available.contains($0) }
        guard !matches.isEmpty else { return }
        let current = selectedID.flatMap { matches.firstIndex(of: $0) }
        let next = current.map { ($0 + step + matches.count) % matches.count } ?? (step > 0 ? 0 : matches.count - 1)
        reveal.send(matches[next])
    }
}

struct WorkspaceFindFlow: ViewModifier {
    @ObservedObject var store: CaptureStore
    @ObservedObject var search: WorkspaceSessionSearch
    @Binding var selectedID: UUID?
    @Binding var single: CaptureSession?
    let reveal: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selectedID, initial: true) { search.selectedID = selectedID }
            .onChange(of: store.source) { search.reset() }
            .onChange(of: store.activeSessionNumber) { search.reset() }
            .onReceive(search.reveal, perform: reveal)
            .onChange(of: search.openSelection) {
                if search.openSelection {
                    single = store.sessions.first { $0.id == selectedID }
                    search.openSelection = false
                }
            }
            .sheet(isPresented: $search.showSearch) {
                WorkspaceFindSheet(search: search, sessions: store.sessions)
            }
            .confirmationDialog("关闭这个录制会话？", isPresented: $search.confirmClose) {
                Button("另存为…") { store.requestedFileAction = .saveAs }
                Button("关闭会话", role: .destructive) { store.closeViewedSession() }
                Button("取消", role: .cancel) {}
            } message: { Text("关闭后将移除此会话在内存中的记录。") }
            .confirmationDialog("清空当前实时会话？", isPresented: $search.confirmClear) {
                Button("清空", role: .destructive) { store.clear() }
                Button("取消", role: .cancel) {}
            }
    }
}

private struct WorkspaceFindSheet: View {
    @ObservedObject var search: WorkspaceSessionSearch
    let sessions: [CaptureSession]
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var searched = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("在会话中查找").font(.title3.bold())
            TextField("URL、请求或响应标头、正文预览", text: $search.query)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { run() }
            if busy { ProgressView().controlSize(.small) }
            else if searched && search.matches.isEmpty { Text("当前会话中没有匹配项。").font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("查找") { run() }.keyboardShortcut(.defaultAction)
                    .disabled(busy || search.query.isEmpty)
            }
        }.padding(20).frame(width: 460)
            .onAppear { focused = true }
            .onChange(of: search.query) {
                task?.cancel()
                busy = false
                searched = false
                search.setMatches([])
            }
            .onDisappear { task?.cancel() }
    }

    private func run() {
        guard !busy, !search.query.isEmpty else { return }
        busy = true
        searched = false
        let term = search.query
        let snapshot = sessions
        task = Task {
            let scan = Task.detached(priority: .userInitiated) {
                var ids = [UUID]()
                for item in snapshot {
                    if Task.isCancelled { break }
                    if SessionFindIndex(item).contains(term) { ids.append(item.id) }
                }
                return ids
            }
            let ids = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
            guard !Task.isCancelled else { return }
            busy = false
            searched = true
            search.setMatches(ids)
            if let id = ids.first {
                dismiss()
                search.reveal.send(id)
            }
        }
    }
}
