import SwiftUI

struct SessionTreeView: View {
    @EnvironmentObject private var viewPreferences: ViewPreferences
    @ObservedObject var store: CaptureStore
    let sessions: [CaptureSession]
    let query: String
    @Binding var selectedID: UUID?
    @Binding var revealID: UUID?
    let makeContextMenu: (CaptureSession) -> SessionContextMenu
    @FocusState private var treeFocused: Bool
    @State private var collapsedGroups: Set<SessionStructure.GroupID> = [.otherHosts]
    @State private var collapsedSearchGroups: Set<SessionStructure.GroupID> = []

    private var collapseState: Binding<Set<SessionStructure.GroupID>> {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $collapsedGroups : $collapsedSearchGroups
    }

    var body: some View {
        let tree = SessionStructure(sessions, focusedHosts: store.hostLists.focused)
        let collapsed = collapseState.wrappedValue
        let selectedAncestors = selectedID.flatMap { tree.ancestors[$0] } ?? []
        let rows = tree.rows(collapsed: collapsed)
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(rows) { row in
                        switch row.content {
                        case let .group(id, title, symbol, count):
                            groupRow(id, title: title, symbol: symbol, count: count,
                                     depth: row.depth, containsSelection: selectedAncestors.contains(id))
                                .id(row.id)
                        case let .session(session, title):
                            sessionRow(session, title: title, depth: row.depth)
                                .id(row.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($treeFocused)
            .onAppear {
                guard let selectedID else { return }
                let folded = selectedAncestors.first(where: collapsed.contains)
                scroll.scrollTo(folded.map(SessionStructure.RowID.group) ?? .session(selectedID))
            }
            .onMoveCommand { direction in
                switch direction {
                case .up, .down:
                    moveSelection(up: direction == .up, in: rows, scroll: scroll)
                case .left, .right:
                    let folded = selectedAncestors.firstIndex(where: collapsed.contains)
                    if direction == .right, let folded {
                        collapseState.wrappedValue.remove(selectedAncestors[folded])
                    } else if direction == .left,
                              let group = selectedAncestors.prefix(folded ?? selectedAncestors.count).last {
                        collapseState.wrappedValue.insert(group)
                        scroll.scrollTo(SessionStructure.RowID.group(group))
                    }
                default: return
                }
            }
            .onChange(of: revealID, initial: true) { _, target in
                guard let target, let groups = tree.ancestors[target] else { return }
                collapseState.wrappedValue.subtract(groups)
                revealID = nil
                DispatchQueue.main.async { scroll.scrollTo(SessionStructure.RowID.session(target)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.sidebar)
        .onChange(of: query) { collapsedSearchGroups.removeAll() }
        .onChange(of: store.hostLists.focused.isEmpty) { _, empty in
            if !empty { collapsedGroups.insert(.otherHosts) }
        }
    }

    private func moveSelection(up: Bool, in rows: [SessionStructure.Row], scroll: ScrollViewProxy) {
        let ids = rows.compactMap { row -> UUID? in
            if case let .session(id) = row.id { return id }
            return nil
        }
        let index = selectedID.flatMap { ids.firstIndex(of: $0) }
        let next = up ? (index ?? ids.count) - 1 : (index ?? -1) + 1
        guard ids.indices.contains(next) else { return }
        selectedID = ids[next]
        scroll.scrollTo(SessionStructure.RowID.session(ids[next]))
    }

    private func groupRow(_ group: SessionStructure.GroupID, title: String, symbol: String, count: Int,
                          depth: Int, containsSelection: Bool) -> some View {
        let folded = collapseState.wrappedValue.contains(group)
        return Button {
            if folded { collapseState.wrappedValue.remove(group) } else { collapseState.wrappedValue.insert(group) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(WorkspaceTheme.muted)
                    .frame(width: 9)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WorkspaceTheme.accent)
                    .frame(width: 13)
                Text(title)
                    .font(.system(size: 11, weight: depth == 0 ? .semibold : .medium, design: .monospaced))
                    .foregroundStyle(WorkspaceTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(count.formatted())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(WorkspaceTheme.muted)
            }
            .padding(.leading, 5 + indentation(depth))
            .padding(.trailing, 5)
            .frame(height: 24)
            .background(folded && containsSelection ? WorkspaceTheme.accentFill : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if case let .authority(authority) = group {
                HostActionsMenu(store: store, host: authority.host, location: authority.recordingOrigin)
                if let url = authority.recordingOrigin?.origin {
                    Divider()
                    LocationDebugActions(store: store, url: url, allPaths: true)
                }
            }
        }
        .help(title)
        .accessibilityLabel("\(title)，\(count) 条会话")
        .accessibilityValue(folded ? "已折叠" : "已展开")
    }

    private func sessionRow(_ session: CaptureSession, title: String, depth: Int) -> some View {
        let selected = selectedID == session.id
        let appearance = appearance(for: session)
        let highlight = viewPreferences.highlight(for: session)
        return Button {
            selectedID = session.id
            treeFocused = true
        } label: {
            HStack(spacing: 5) {
                if let highlight {
                    Circle().fill(highlight.color).frame(width: 7, height: 7).help(highlight.title + "高亮")
                }
                Image(systemName: appearance.symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(appearance.color)
                    .frame(width: 13)
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(selected ? WorkspaceTheme.brand : WorkspaceTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if session.device == .phone {
                    Image(systemName: "iphone").font(.system(size: 10)).foregroundStyle(WorkspaceTheme.muted)
                }
                Text(appearance.label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(appearance.color)
                    .fixedSize()
            }
            .padding(.leading, 19 + indentation(depth))
            .padding(.trailing, 5)
            .frame(height: 24)
            .background(selected ? WorkspaceTheme.accentFill : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(appearance.activity.map { "\(session.url) · \($0)" } ?? session.url)
        .contextMenu { makeContextMenu(session) }
        .accessibilityLabel("\(session.isTunnel ? title : session.method) \(session.url) \((session.device ?? .mac).title) \(highlight.map { $0.title + "高亮" } ?? "")")
        .accessibilityValue(appearance.activity.map { "\(appearance.label)，\($0)" } ?? appearance.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private struct Appearance {
        let label: String
        let symbol: String
        let color: Color
        var activity: String? = nil
    }

    private func appearance(for session: CaptureSession) -> Appearance {
        let code = session.statusCode
        if session.isTunnel {
            if session.error != nil || code.map({ !(200..<300).contains($0) }) == true {
                return Appearance(label: "失败", symbol: "exclamationmark.circle", color: WorkspaceTheme.failure)
            }
            if session.finished { return Appearance(label: "已结束", symbol: "lock", color: WorkspaceTheme.muted) }
            guard code != nil else {
                return Appearance(label: "连接中", symbol: "clock", color: WorkspaceTheme.muted)
            }
            switch session.tunnelActivity {
            case .upload?:
                return Appearance(label: "已建立", symbol: "arrow.up.right", color: WorkspaceTheme.accent, activity: "最近上传")
            case .download?:
                return Appearance(label: "已建立", symbol: "arrow.down.left", color: WorkspaceTheme.accent, activity: "最近下载")
            case nil:
                return Appearance(label: "已建立", symbol: "lock", color: WorkspaceTheme.good)
            }
        }
        let label = code.map(String.init) ?? (session.error == nil ? "—" : "错误")
        if session.error != nil || (code ?? 0) >= 400 {
            return Appearance(label: label, symbol: "doc.text", color: WorkspaceTheme.failure)
        }
        return Appearance(label: label, symbol: "doc.text", color: WorkspaceTheme.muted)
    }

    private func indentation(_ depth: Int) -> CGFloat { CGFloat(min(depth, 6)) * 10 }
}
