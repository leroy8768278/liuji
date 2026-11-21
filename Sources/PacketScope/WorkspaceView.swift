import AppKit
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var viewPreferences: ViewPreferences
    @ObservedObject var store: CaptureStore
    @State private var filter: CaptureFilter = .all
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var revealTreeID: UUID?
    @AppStorage("capture.sessionListPresentation") private var presentation = SessionListPresentation.structure
    @AppStorage("capture.focusedOnly") private var focusedOnly = false
    @State private var ordering: SessionOrdering = .newest
    @State private var hiddenHosts = Set<String>()
    @State private var inspectionSessionID: UUID?
    @State private var inspectionSelection: SessionInspectorSelection?
    @State private var inspectionRevision = 0
    @State private var searchSession: CaptureSession?
    @State private var jsonValidation: String?

    private var visibleSessions: [CaptureSession] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = store.sessions.reversed().filter { session in
            (presentation != .sequence || !focusedOnly || store.hostLists.isFocused(session.host)) &&
            !hiddenHosts.contains(session.host) && filter.includes(session) && (term.isEmpty || session.url.localizedStandardContains(term) ||
                session.method.localizedStandardContains(term) || session.statusCode.map(String.init) == term)
        }
        switch ordering {
        case .newest: return matches
        case .oldest: return Array(matches.reversed())
        case .status: return matches.sorted { ($0.statusCode ?? 600) < ($1.statusCode ?? 600) }
        case .duration: return matches.sorted { ($0.elapsed ?? -1) > ($1.elapsed ?? -1) }
        }
    }

    var body: some View {
        let visible = visibleSessions
        VStack(spacing: 0) {
            toolbar
            rule
            if presentation == .structure {
                HSplitView {
                    navigator(visible)
                        .frame(minWidth: 308, idealWidth: 336, maxWidth: 530, maxHeight: .infinity)
                    inspector(visible)
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                }
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 216)
                    WorkspaceTheme.rule.frame(width: 1)
                    HSplitView {
                        SessionList(filter: filter, sessions: visible, query: $query, selectedID: $selectedID, focusedOnly: $focusedOnly,
                                    hasSessions: !store.sessions.isEmpty, isRunning: store.isRunning,
                                    openConnection: { store.presentedProxySettings = .connection },
                                    isArchive: store.source.isArchive, makeContextMenu: menu(for:))
                            .frame(minWidth: 420, idealWidth: 565, maxWidth: .infinity, maxHeight: .infinity)
                        inspector(visible).frame(minWidth: 365, idealWidth: 490, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            rule
            statusBar
        }
        .background(WorkspaceTheme.canvas)
        .foregroundStyle(WorkspaceTheme.ink)
        .onChange(of: visible.map(\.id), initial: true) { _, identifiers in
            if selectedID.map({ identifiers.contains($0) }) != true { selectedID = identifiers.first }
        }
        .onChange(of: store.source) {
            query = ""
            filter = .all
            hiddenHosts = []
        }
        .onChange(of: store.activeSessionNumber) {
            query = ""
            filter = .all
            hiddenHosts = []
        }
        .modifier(SessionFileFlow(store: store))
        .modifier(WorkspaceFindFlow(store: store, search: store.sessionSearch, selectedID: $selectedID, single: $searchSession) { id in
            if let target = store.sessions.first(where: { $0.id == id }) {
                hiddenHosts.remove(target.host)
                if !store.hostLists.isFocused(target.host) { focusedOnly = false }
            }
            filter = .all
            query = ""
            selectedID = id
            if presentation == .structure { revealTreeID = id }
        })
        .sheet(item: $store.presentedProxySettings) { page in
            switch page {
            case .ownedHTTPS: OwnedHTTPSSettingsSheet(settings: store.ownedHTTPS, initialHost: store.httpsSeed?.host, initialPort: store.httpsSeed?.port ?? 443)
            case .errors, .connections: SessionActivitySheet(store: store, errors: page == .errors)
            case .externalProxy: ExternalProxySettingsSheet(store: store)
            case .connection: ConnectionSheet(store: store)
            case .mobile: MobileProxySheet(store: store)
            case .portForwarding: LocalPortForwardingSheet(forwarder: store.portForwarder)
            default: ProxySettingsSheet(store: store, page: page)
            }
        }
        .sheet(item: $store.localRequestDraft) { LocalRequestComposerSheet(store: store, draft: $0) }
        .sheet(item: $store.presentedTool) { tool in
            ProxyToolsSheet(initialKind: tool, rules: store.ruleSet, initialRule: store.initialToolRule, onSave: store.saveRules)
        }
        .sheet(item: $viewPreferences.page) { page in ViewPreferencesSheet(preferences: viewPreferences, page: page) }
        .sheet(item: $searchSession) { SessionFindSheet(session: $0) }
        .sheet(isPresented: $store.showFocusedHosts) { HostListSheet(store: store, kind: .focused) }
        .sheet(isPresented: $store.showRuleProfiles) {
            RuleProfilesSheet(currentRules: store.ruleSet, onApply: store.saveRules)
        }
        .sheet(item: $store.presentedOutputSettings) { page in
            CaptureOutputSettingsSheet(page: page, options: store.outputOptions, onSave: store.setOutputOptions)
        }
        .alert("JSON 响应校验", isPresented: Binding(get: { jsonValidation != nil }, set: { if !$0 { jsonValidation = nil } })) {
            Button("好") { jsonValidation = nil }
        } message: { Text(jsonValidation ?? "") }
    }

    private func inspector(_ sessions: [CaptureSession]) -> some View {
        Group {
            if let session = sessions.first(where: { $0.id == selectedID }) {
                SessionInspector(session: session, isArchive: store.source.isArchive,
                                 externalSelection: inspectionSessionID == session.id ? inspectionSelection : nil, selectionRevision: inspectionRevision,
                                 updateNote: store.source == .demo ? nil : { store.setNote($0, for: session.id) })
            } else {
                WorkspacePlaceholder(symbol: "doc.text.magnifyingglass", title: "会话详情",
                                     message: "选择一条会话，查看请求和响应。")
            }
        }
        .background(WorkspaceTheme.canvas)
    }

    private func navigator(_ sessions: [CaptureSession]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话结构").font(.system(size: 12, weight: .semibold))
                Text(sessions.count.formatted()).font(.system(size: 10, design: .monospaced)).foregroundStyle(WorkspaceTheme.muted)
                Spacer(minLength: 8)
                Menu {
                    ForEach(CaptureFilter.general, id: \.self) { item in
                        Button { filter = item } label: {
                            if filter == item { Label(item.title, systemImage: "checkmark") }
                            else { Text(item.title) }
                        }
                    }
                    if !hiddenHosts.isEmpty { Button("显示隐藏的主机") { hiddenHosts.removeAll() } }
                } label: {
                    Label(filter.title, systemImage: "line.3.horizontal.decrease.circle").lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            rule
            if sessions.isEmpty { structureEmpty }
            else {
                SessionTreeView(store: store, sessions: sessions, query: query, selectedID: $selectedID,
                                revealID: $revealTreeID, makeContextMenu: menu(for:))
            }
            rule
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(WorkspaceTheme.muted)
                TextField("筛选 URL、方法或状态码", text: $query).textFieldStyle(.plain).accessibilityLabel("搜索会话")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 11)
            .frame(height: 31)
            rule
            sourceButton
        }
        .background(WorkspaceTheme.sidebar)
    }

    @ViewBuilder private var structureEmpty: some View {
        if !store.sessions.isEmpty {
            WorkspacePlaceholder(symbol: "magnifyingglass", title: "没有匹配的会话", message: "调整筛选条件后重试。")
        } else if store.source.isArchive {
            WorkspacePlaceholder(symbol: "archivebox", title: "空会话归档", message: "归档中没有会话。")
        } else {
            WorkspacePlaceholder(symbol: "waveform.path", title: store.isRunning ? "正在等待流量" : "开始抓包",
                                 message: "点击「Mac 抓包」接入系统流量，或单独设置客户端代理。",
                                 connectionAction: { store.presentedProxySettings = .system })
        }
    }

    private func menu(for session: CaptureSession) -> SessionContextMenu {
        let isLive = store.source == .live
        return SessionContextMenu(session: session, presentation: presentation, ordering: ordering, isLive: isLive,
                                  canTerminate: isLive && store.isRunning && !session.finished, store: store) { action in
            switch action {
            case .copyURL: CopyText.toPasteboard(session.url)
            case .copyCommand:
                if let command = session.localCurlCommand { CopyText.toPasteboard(command) }
            case .copyResponse:
                let data = CaptureBodyDecoding.decode(session.responseBody, headers: session.responsePreviewHeaders)
                let mime = session.responsePreviewHeaders.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
                if let data, let text = CaptureBodyDecoding.text(data, contentType: mime) {
                    CopyText.toPasteboard(text)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(session.responseBody, forType: .init("public.data"))
                }
            case .saveResponse: store.requestedFileAction = .saveResponse(session.id)
            case .export: store.requestedFileAction = .saveSelection(session.id)
            case .find:
                selectedID = session.id
                searchSession = session
            case .viewerMappings: viewPreferences.page = .mappings
            case .validate:
                selectedID = session.id
                jsonValidation = validateJSON(session)
            case let .inspect(selection):
                selectedID = session.id
                inspectionSessionID = session.id
                inspectionSelection = selection
                inspectionRevision += 1
            case .reveal:
                if presentation == .structure && !store.hostLists.isFocused(session.host) { focusedOnly = false }
                if presentation == .sequence { revealTreeID = session.id }
                selectedID = session.id
                presentation = presentation == .structure ? .sequence : .structure
            case .filterToHost:
                selectedID = session.id
                query = ""
                filter = .host(session.host)
            case .hideHost:
                hiddenHosts.insert(session.host)
                if filter == .host(session.host) { filter = .all }
            case .terminate: store.terminate(session.id)
            case .clear: store.removeSessions(removing: session.id)
            case .clearOthers: store.removeSessions(keeping: session.id)
            case let .rule(kind):
                store.openTool(kind, seed: ProxyRule(kind: kind, host: session.host, path: session.pathForRule))
            case let .sort(order): ordering = order
            }
        }
    }

    private func validateJSON(_ session: CaptureSession) -> String {
        guard session.finished, session.responseBytes == session.responseBody.count,
              let data = CaptureBodyDecoding.decode(session.responseBody, headers: session.responsePreviewHeaders) else {
            return "需要完整且可解码的响应才能校验。"
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return "响应正文是有效的 JSON。"
        } catch {
            return "响应正文不是有效的 JSON。"
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(WorkspaceTheme.brand)
                .frame(width: 36, height: 36)
                .background(WorkspaceTheme.accentFill, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("流迹").font(.system(size: 16, weight: .bold))
                Text("HTTP 调试代理").font(.system(size: 10, weight: .medium)).foregroundStyle(WorkspaceTheme.muted)
            }
            SessionPresentationPicker(presentation: $presentation).padding(.leading, 8)
            Spacer(minLength: 16)
            if !store.pendingBreakpoints.isEmpty {
                Button { store.presentedProxySettings = .breakpoints } label: {
                    Label("\(store.pendingBreakpoints.count) 条请求已暂停", systemImage: "pause.circle")
                        .padding(.horizontal, 11).frame(height: 32)
                }
                .buttonStyle(WorkspaceButtonStyle())
            }
            Button { store.openTool(.mapRemote) } label: {
                Label("工具规则", systemImage: "wrench.and.screwdriver")
                    .padding(.horizontal, 11)
                    .frame(height: 32)
            }
            .buttonStyle(WorkspaceButtonStyle())
            Button { store.presentedProxySettings = .system } label: {
                Label("Mac 抓包", systemImage: "laptopcomputer")
                    .padding(.horizontal, 11)
                    .frame(height: 32)
            }
            .buttonStyle(WorkspaceButtonStyle())
            Button { store.presentedProxySettings = .mobile } label: {
                Label("手机接入", systemImage: "iphone")
                    .padding(.horizontal, 11).frame(height: 32)
            }
            .buttonStyle(WorkspaceButtonStyle())
            Button { store.clear() } label: {
                Image(systemName: "trash")
                    .frame(width: 34, height: 32)
            }
            .buttonStyle(WorkspaceButtonStyle())
            .disabled(store.liveSessions.isEmpty || store.source != .live)
            .help("清空当前会话")
            .accessibilityLabel("清空当前会话")
            Button {
                if store.isRunning { store.stop() } else { store.start() }
            } label: {
                Label(store.isRunning ? "停止监听" : "开启监听",
                      systemImage: store.isRunning ? "stop.fill" : "record.circle")
                    .padding(.horizontal, 14)
                    .frame(height: 32)
            }
            .buttonStyle(WorkspaceButtonStyle(prominent: true))
            .disabled(store.state == .starting || store.isStopping || store.macProxyBusy)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.leading, 86)
        .padding(.trailing, 20)
        .frame(height: 60)
        .background(WorkspaceTheme.chrome)
    }

    private var sidebar: some View {
        let sessions = store.sessions
        let hosts = Dictionary(grouping: sessions.filter { !hiddenHosts.contains($0.host) }, by: \.host)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarHeading("会话")
                    ForEach(CaptureFilter.general, id: \.self) { item in
                        sidebarRow(item, count: sessions.filter(item.includes).count)
                    }
                    if !hiddenHosts.isEmpty {
                        Button("显示隐藏的主机") { hiddenHosts.removeAll() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(WorkspaceTheme.accent)
                            .padding(10)
                    }
                    rule.padding(.horizontal, 9).padding(.vertical, 12)
                    sidebarHeading("主机")
                    if hosts.isEmpty {
                        Text("收到请求后显示主机")
                            .font(.system(size: 11))
                            .foregroundStyle(WorkspaceTheme.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(hosts.keys.sorted(), id: \.self) { host in
                            sidebarRow(.host(host), count: hosts[host]?.count ?? 0)
                                .contextMenu { HostActionsMenu(store: store, host: host, location: nil) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 22)
            }
            rule.padding(.horizontal, 20)
            sourceButton.padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(WorkspaceTheme.sidebar)
    }

    private var sourceButton: some View {
        Button {
            store.showExampleOrReturnToLive()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: store.source == .live ? "play.rectangle" : "arrow.uturn.backward")
                Text(store.source == .live ? "查看示例会话" : "返回实时抓包")
                Spacer()
            }
            .padding(.horizontal, 11)
            .frame(height: 31)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(WorkspaceTheme.accent)
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WorkspaceTheme.muted)
            .padding(.horizontal, 10)
            .padding(.bottom, 5)
    }

    private func sidebarRow(_ item: CaptureFilter, count: Int) -> some View {
        Button { filter = item } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon).frame(width: 16)
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(count.formatted())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(filter == item ? WorkspaceTheme.accent : WorkspaceTheme.muted)
            }
            .font(.system(size: 12, weight: filter == item ? .semibold : .medium))
            .foregroundStyle(filter == item ? WorkspaceTheme.brand : WorkspaceTheme.ink)
            .padding(.horizontal, 10)
            .frame(height: 33)
            .background(filter == item ? WorkspaceTheme.accentFill : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityAddTraits(filter == item ? .isSelected : [])
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusLabel).fontWeight(.semibold)
            if case let .failed(message) = store.state {
                Text(message).lineLimit(1).help(message)
            }
            if store.isRunning { Text(store.recordingEnabled ? "录制中" : "录制已暂停") }
            if store.isRunning || store.hasMacProxyBackup {
                Button(store.macRoute.matches(port: store.port) ? "系统代理指向流迹" : "检查系统代理") {
                    store.presentedProxySettings = .system
                }
                .buttonStyle(.link)
            }
            if case .running = store.mobileState { Text("手机接入已开启") }
            if let message = store.outputError {
                Label("写入失败", systemImage: "exclamationmark.circle").help(message)
            }
            Spacer()
            if store.isReadingArchive { Text("正在读取会话…") }
            Text(store.source == .live ? "实时会话 \(store.activeSessionNumber)" : store.source.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.source.title)
            Text("·").accessibilityHidden(true)
            Text("\(store.sessions.count.formatted()) 条会话")
            Text("·").accessibilityHidden(true)
            Text("\(SessionFormat.bytes(store.sessions.reduce(0) { $0 + $1.responseBytes })) 响应流量")
        }
        .font(.system(size: 11))
        .foregroundStyle(WorkspaceTheme.muted)
        .padding(.horizontal, 18)
        .frame(height: 31)
        .background(WorkspaceTheme.chrome)
    }

    private var statusColor: Color {
        switch store.state {
        case .running: WorkspaceTheme.good
        case .starting: WorkspaceTheme.warning
        case .failed: WorkspaceTheme.failure
        case .stopped: WorkspaceTheme.muted
        }
    }

    private var statusLabel: String {
        switch store.state {
        case .starting: "正在启动"
        case .stopped: "代理已停止"
        case .failed: "代理启动失败"
        case let .running(port): "正在监听 127.0.0.1:\(port)"
        }
    }

    private var rule: some View { WorkspaceTheme.rule.frame(height: 1) }
}

struct WorkspaceButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? .white : WorkspaceTheme.ink)
            .background(prominent ? Color(red: 0.02, green: 0.37, blue: 0.33) : WorkspaceTheme.canvas,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if !prominent { RoundedRectangle(cornerRadius: 7).strokeBorder(WorkspaceTheme.rule) }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct WorkspacePlaceholder: View {
    let symbol: String
    let title: String
    let message: String
    var connectionAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(WorkspaceTheme.accent)
                .frame(width: 56, height: 56)
                .background(WorkspaceTheme.accentFill, in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(WorkspaceTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            if let connectionAction {
                Button(action: connectionAction) {
                    Label("查看接入方式", systemImage: "arrow.right.circle")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                }
                .buttonStyle(WorkspaceButtonStyle())
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
