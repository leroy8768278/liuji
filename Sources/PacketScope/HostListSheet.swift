import SwiftUI

struct HostListSheet: View {
    @ObservedObject var store: CaptureStore
    let kind: HostListKind
    @Environment(\.dismiss) private var dismiss
    @State private var entries: Set<String> = []
    @State private var selection: String?
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).font(.title3.weight(.semibold))
            Text(kind == .focused ? "关注的主机优先显示在结构视图中。" : "匹配的新请求继续转发，并从录制中排除。")
                .foregroundStyle(.secondary)
            List(entries.sorted(), id: \.self, selection: $selection) { item in
                Text(item).font(.body.monospaced()).tag(item)
            }
            .accessibilityLabel(kind.title)
            HStack {
                TextField(kind == .focused ? "主机名" : "主机名或完整 HTTP/HTTPS 地址", text: $input)
                    .onSubmit(add)
                Button("添加", action: add).disabled(newEntry == nil)
                Button("移除") {
                    if let selection { entries.remove(selection) }
                    selection = nil
                }.disabled(selection == nil)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.replaceHostEntries(kind, with: entries)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 490, height: 330)
        .onAppear { entries = store.hostLists.entries(kind) }
    }

    private var newEntry: String? {
        guard let entry = kind.entry(input), !entries.contains(entry) else { return nil }
        return entry
    }

    private func add() {
        guard let entry = newEntry else { return }
        entries.insert(entry)
        selection = entry
        input = ""
    }
}

struct HostActionsMenu: View {
    @ObservedObject var store: CaptureStore
    let host: String
    let location: RecordingLocation?

    var body: some View {
        if let name = CaptureHostLists.host(host) {
            Button(store.hostLists.focused.contains(name) ? "取消关注主机" : "关注主机") {
                store.toggleHostEntry(.focused, entry: name)
            }
            let entries = store.hostLists.ignored
            let existing = [location?.description, location?.origin, name].compactMap { $0 }.first(where: entries.contains)
            let target = existing ?? location?.description ?? name
            Button(existing != nil ? "取消忽略录制" : "忽略录制") {
                store.toggleHostEntry(.ignored, entry: target)
            }
            .help(target)
        }
    }
}
