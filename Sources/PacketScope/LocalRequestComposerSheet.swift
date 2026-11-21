import SwiftUI

struct LocalRequestCommands: View {
    @ObservedObject var store: CaptureStore
    @ObservedObject private var search: WorkspaceSessionSearch

    init(store: CaptureStore) {
        self.store = store
        search = store.sessionSearch
    }

    var body: some View {
        let session = search.selectedID.flatMap { id in store.sessions.first { $0.id == id } }
        let draft = session.flatMap { LocalRequestDraft(session: $0, mode: .compose) }
        Button("编写本机请求…") { store.localRequestDraft = draft }
            .keyboardShortcut("m")
            .disabled(draft == nil)
        Button("新建本机请求…") { store.localRequestDraft = LocalRequestDraft() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        Button("重复本机请求…") {
            store.localRequestDraft = session.flatMap { LocalRequestDraft(session: $0, mode: .repeatRequest) }
        }.keyboardShortcut("r", modifiers: [.shift, .command])
            .disabled(draft == nil)
    }
}

struct LocalRequestComposerSheet: View {
    @ObservedObject var store: CaptureStore
    @State var draft: LocalRequestDraft
    @State private var sender = LocalRequestSender()
    @State private var sending = false
    @State private var message: String?
    @State private var preparing: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let readOnly = draft.mode == .repeatRequest
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.mode.title).font(.title2.bold())
            HStack {
                Picker("方法", selection: $draft.method) {
                    ForEach(LocalRequestDraft.methods, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 90)
                TextField("本机 HTTP 地址", text: $draft.url)
            }.disabled(sending || readOnly)
            Text("请求头").font(.headline)
            TextEditor(text: $draft.headers).font(.body.monospaced()).frame(height: 75)
                .border(Color.secondary.opacity(0.3)).disabled(sending || readOnly)
            Text("Accept、Accept-Language、Content-Type 或 X-Debug- 标头，每行一项。")
                .font(.caption).foregroundStyle(.secondary)
            Text("请求正文").font(.headline)
            TextEditor(text: $draft.body).font(.body.monospaced()).frame(height: 108)
                .border(Color.secondary.opacity(0.3)).disabled(sending || readOnly)
            Text("单次发送至本机回环地址，localhost 使用 127.0.0.1。请求和响应可在实时会话中查看，重定向停在本次响应。")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).foregroundStyle(WorkspaceTheme.failure).textSelection(.enabled) }
            HStack {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                Button(sending ? "取消发送" : "取消") {
                    preparing?.cancel()
                    sender.cancel()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Button(sending ? "发送中…" : (readOnly ? "重复一次" : "发送一次"), action: submit)
                    .disabled(sending || store.isStopping)
            }
        }
        .padding(22).frame(width: 555)
        .textFieldStyle(.roundedBorder)
        .onDisappear { preparing?.cancel(); sender.cancel() }
    }

    private func submit() {
        guard !sending else { return }
        do {
            let request = try draft.prepared()
            message = nil
            sending = true
            preparing = Task {
                do {
                    let port = try await store.prepareForLocalRequest()
                    try Task.checkCancellation()
                    sender.send(request, via: port) { result in
                        sending = false
                        switch result {
                        case .success: dismiss()
                        case let .failure(error): message = error.localizedDescription
                        }
                    }
                } catch {
                    sending = false
                    message = error.localizedDescription
                }
            }
        } catch { message = error.localizedDescription }
    }
}
