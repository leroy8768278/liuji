import SwiftUI

struct SessionList: View {
    @EnvironmentObject private var viewPreferences: ViewPreferences
    let filter: CaptureFilter
    let sessions: [CaptureSession]
    @Binding var query: String
    @Binding var selectedID: UUID?
    @Binding var focusedOnly: Bool
    let hasSessions: Bool
    let isRunning: Bool
    let openConnection: () -> Void
    var isArchive = false
    let makeContextMenu: (CaptureSession) -> SessionContextMenu
    @FocusState private var tableFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(filter.title)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(sessions.count.formatted())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(WorkspaceTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(WorkspaceTheme.accentFill, in: Capsule())
                    .accessibilityLabel("\(sessions.count) 条会话")
                Spacer(minLength: 8)
                searchField
            }
            .padding(.horizontal, 17)
            .frame(height: 61)
            WorkspaceTheme.rule.frame(height: 1)
            HStack {
                Toggle("仅显示关注的主机", isOn: $focusedOnly).toggleStyle(.checkbox)
                Spacer()
            }
            .font(.system(size: 11))
            .padding(.horizontal, 17)
            .frame(height: 28)
            columns(status: Text("状态"), method: Text("方法"), address: Text("请求地址"), time: Text("耗时"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkspaceTheme.muted)
                .frame(height: 30)
                .background(WorkspaceTheme.chrome)
            WorkspaceTheme.rule.frame(height: 1)
            if sessions.isEmpty {
                WorkspacePlaceholder(symbol: emptySymbol, title: emptyTitle, message: emptyMessage,
                                     connectionAction: hasSessions || isArchive ? nil : openConnection)
            } else {
                table
            }
        }
        .background(WorkspaceTheme.canvas)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WorkspaceTheme.muted)
                .accessibilityHidden(true)
            TextField("搜索 URL、方法或状态码", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索会话")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(WorkspaceTheme.muted)
                    .accessibilityLabel("清除搜索")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(width: 173, height: 28)
        .background(WorkspaceTheme.chrome, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(WorkspaceTheme.rule) }
    }

    private var table: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sessions) { session in row(session).id(session.id) }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($tableFocused)
            .onAppear {
                if let selectedID { scroll.scrollTo(selectedID) }
            }
            .onChange(of: selectedID) { _, id in
                if let id { scroll.scrollTo(id) }
            }
            .onMoveCommand { direction in
                guard direction == .up || direction == .down else { return }
                let index = selectedID.flatMap { id in sessions.firstIndex { $0.id == id } }
                let next = direction == .up ? (index ?? sessions.count) - 1 : (index ?? -1) + 1
                guard sessions.indices.contains(next) else { return }
                selectedID = sessions[next].id
                scroll.scrollTo(sessions[next].id)
            }
        }
    }

    private func row(_ session: CaptureSession) -> some View {
        let selected = selectedID == session.id
        let highlight = viewPreferences.highlight(for: session)
        return sessionButton(session, height: 49) {
            columns(
                status: statusBadge(session), method: HStack(spacing: 4) {
                    if let highlight {
                        Circle().fill(highlight.color).frame(width: 7, height: 7).help(highlight.title + "高亮")
                            .accessibilityLabel(highlight.title + "高亮")
                    }
                    methodBadge(session.method)
                },
                address: VStack(alignment: .leading, spacing: 4) {
                    Text(session.isTunnel ? session.host : session.route)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text((session.device == .phone ? "手机 · " : "") + (session.isTunnel ? session.url : session.host))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(WorkspaceTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                },
                time: elapsed(session)
            )
        }
    }

    private func sessionButton<Content: View>(_ session: CaptureSession, height: CGFloat,
                                              @ViewBuilder content: () -> Content) -> some View {
        let selected = selectedID == session.id
        return Button {
            selectedID = session.id
            tableFocused = true
        } label: {
            VStack(spacing: 0) {
                content().frame(height: height)
                WorkspaceTheme.rule.frame(height: 1)
            }
            .background(selected ? WorkspaceTheme.accentFill.opacity(0.73) : WorkspaceTheme.canvas)
            .overlay(alignment: .leading) {
                if selected { WorkspaceTheme.accent.frame(width: 3).padding(.bottom, 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.url)
        .contextMenu { makeContextMenu(session) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func statusBadge(_ session: CaptureSession) -> some View {
        let status = statusStyle(for: session)
        return Text(status.label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(status.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(status.fill, in: RoundedRectangle(cornerRadius: 5))
    }

    private func methodBadge(_ method: String) -> some View {
        Text(method)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(methodColor(method))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func elapsed(_ session: CaptureSession) -> some View {
        Text(session.elapsed.map(SessionFormat.duration) ?? "—")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(WorkspaceTheme.muted)
            .lineLimit(1)
    }

    private func columns<Status: View, Method: View, Address: View, Time: View>(
        status: Status, method: Method, address: Address, time: Time
    ) -> some View {
        HStack(spacing: 11) {
            status.frame(width: 42, alignment: .leading)
            method.frame(width: 59, alignment: .leading)
            address.frame(maxWidth: .infinity, alignment: .leading)
            time.frame(width: 59, alignment: .trailing)
        }
        .padding(.horizontal, 17)
    }

    private func statusStyle(for session: CaptureSession) -> (label: String, text: Color, fill: Color) {
        if session.error != nil {
            return (session.statusCode.map { String($0) } ?? "错误", WorkspaceTheme.failure, WorkspaceTheme.failureFill)
        }
        guard let status = session.statusCode else { return ("等待", WorkspaceTheme.muted, WorkspaceTheme.chrome) }
        switch status {
        case 100..<300: return (String(status), WorkspaceTheme.good, WorkspaceTheme.goodFill)
        case 300..<400: return (String(status), WorkspaceTheme.blue, WorkspaceTheme.blueFill)
        case 400..<500: return (String(status), WorkspaceTheme.warning, WorkspaceTheme.warningFill)
        default: return (String(status), WorkspaceTheme.failure, WorkspaceTheme.failureFill)
        }
    }

    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET", "HEAD": WorkspaceTheme.blue
        case "CONNECT": WorkspaceTheme.accent
        case "DELETE": WorkspaceTheme.failure
        default: WorkspaceTheme.ink
        }
    }

    private var emptySymbol: String {
        if hasSessions { return "magnifyingglass" }
        if isArchive { return "archivebox" }
        return isRunning ? "antenna.radiowaves.left.and.right" : "waveform.path"
    }

    private var emptyTitle: String {
        if hasSessions { return "没有匹配的会话" }
        if isArchive { return "空会话归档" }
        return isRunning ? "正在等待流量" : "开始抓包"
    }

    private var emptyMessage: String {
        if hasSessions { return "调整搜索条件，或从侧边栏切换会话筛选。" }
        if isArchive { return "此归档中没有会话记录。" }
        return isRunning ? "在客户端配置此代理后发出请求。" : "开启代理，再将客户端接入本机监听端口。"
    }
}

enum SessionListPresentation: String, CaseIterable {
    case sequence, structure

    var label: String { self == .sequence ? "时间顺序" : "结构视图" }
    var shortLabel: String { self == .sequence ? "时序" : "结构" }
    var symbol: String { self == .sequence ? "clock" : "list.bullet.indent" }
}

struct SessionPresentationPicker: View {
    @Binding var presentation: SessionListPresentation

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SessionListPresentation.allCases, id: \.self) { option in
                Button {
                    presentation = option
                } label: {
                    Label(option.shortLabel, systemImage: option.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(presentation == option ? WorkspaceTheme.accent : WorkspaceTheme.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 23)
                        .background(presentation == option ? WorkspaceTheme.accentFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(presentation == option ? .isSelected : [])
                .help(option.label)
            }
        }
        .padding(2)
        .background(WorkspaceTheme.chrome, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(WorkspaceTheme.rule) }
    }
}
