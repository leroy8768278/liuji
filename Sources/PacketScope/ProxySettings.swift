import AppKit
import SwiftUI

enum ProxySettingsPage: String, Identifiable {
    case connection, system, mobile, externalProxy, recording, throttling, breakpoints, portForwarding, ownedHTTPS, errors, connections
    var id: Self { self }
}

struct ProxySettingsSheet: View {
    @ObservedObject var store: CaptureStore
    let page: ProxySettingsPage
    @Environment(\.dismiss) private var dismiss
    @State private var options = ProxyTrafficOptions()
    @State private var recordingLimit = 500
    @State private var showIgnored = false

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(title).font(.system(size: 21, weight: .semibold))
            switch page {
            case .recording: recording
            case .throttling: throttling
            case .breakpoints: breakpoints
            case .system: systemSettings
            default: EmptyView()
            }
            HStack {
                Spacer()
                if page == .system {
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("保存") {
                        if page == .recording { store.setRecordingLimit(recordingLimit) }
                        else { store.setTrafficOptions(options) }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(page == .breakpoints && !options.hasValidBreakpointPath)
                }
            }
        }
        .sheet(isPresented: $showIgnored) { HostListSheet(store: store, kind: .ignored) }
        .padding(24)
        .frame(width: 480)
        .foregroundStyle(WorkspaceTheme.ink)
        .background(WorkspaceTheme.canvas)
        .onAppear {
            options = store.trafficOptions
            recordingLimit = store.recordingLimit
            if page == .system { store.refreshMacProxyStatus() }
        }
    }

    private var title: String {
        switch page {
        case .recording: "录制设置"
        case .throttling: "限速设置"
        case .breakpoints: "断点设置"
        case .system: "macOS 代理"
        default: "代理设置"
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper("保留最近 \(recordingLimit) 条会话", value: $recordingLimit, in: 50...1_000, step: 50)
            Button("管理忽略录制的主机…") { showIgnored = true }
            Text("暂停录制时，代理会继续转发；已列出的会话仍会显示结束状态。")
                .font(.caption).foregroundStyle(WorkspaceTheme.muted)
        }
    }

    private var throttling: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("启用限速", isOn: $options.throttleEnabled)
            Stepper("单向首次延迟 \(options.latencyMilliseconds) ms", value: $options.latencyMilliseconds,
                    in: ProxyTrafficOptions.latencyRange, step: 25)
            Stepper("每连接单向带宽 \(options.bandwidthKiBPerSecond) KiB/s", value: $options.bandwidthKiBPerSecond,
                    in: ProxyTrafficOptions.bandwidthRange, step: 16)
        }
    }

    private var breakpoints: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("启用断点", isOn: $options.breakpointsEnabled)
            Toggle("所有回环主机的本机请求路径", isOn: Binding(
                get: { options.matchesLocalPath }, set: { options.useLocalPathBreakpoint = $0 }
            ))
            if options.matchesLocalPath {
                TextField("本机请求路径", text: $options.breakpointPath, prompt: Text("/api/status"))
                    .textFieldStyle(.roundedBorder)
                if !options.hasValidBreakpointPath {
                    Text("输入以 / 开头的路径。").font(.caption).foregroundStyle(WorkspaceTheme.warning)
                }
            }
            if let locations = options.breakpointLocations, !locations.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(locations) { location in
                            HStack {
                                Text(location.title).lineLimit(1).truncationMode(.middle).help(location.title)
                                Spacer()
                                Picker("阶段", selection: phaseBinding(location)) {
                                    ForEach(BreakpointPhase.allCases, id: \.self) { Text($0.title).tag($0) }
                                }.labelsHidden().fixedSize()
                                Button { options.breakpointLocations?.removeAll { $0.id == location.id } } label: {
                                    Image(systemName: "minus.circle")
                                }.accessibilityLabel("移除断点")
                            }
                        }
                    }
                }.frame(maxHeight: 150)
            }
            Text("在会话上右键添加断点。命中后可检查标头、继续或中止，等待上限为 60 秒。")
                .font(.caption).foregroundStyle(WorkspaceTheme.muted)
            if !store.pendingBreakpoints.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.pendingBreakpoints.values.sorted { $0.startedAt < $1.startedAt }) { session in
                            BreakpointPendingRow(store: store, session: session)
                                .id("\(session.id)-\(session.breakpointPhase?.rawValue ?? "")")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func phaseBinding(_ location: BreakpointLocation) -> Binding<BreakpointPhase> {
        Binding(get: {
            options.breakpointLocations?.first { $0.id == location.id }?.phase ?? location.phase
        }, set: { phase in
            if let index = options.breakpointLocations?.firstIndex(where: { $0.id == location.id }) {
                options.breakpointLocations?[index].phase = phase
            }
        })
    }

    private var systemSettings: some View {
        let route = store.macRoute
        let connected = route.matches(port: store.port)
        let capturing = connected && store.isRunning && store.recordingEnabled && store.source == .live
        return VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                addressRow("当前网络服务", store.macServiceName ?? "未检测到")
                addressRow("流迹监听", store.isRunning ? "127.0.0.1:\(store.port)" : "尚未启动 · 端口 \(store.port)")
                Divider()
                addressRow("系统 HTTP 代理", route.http)
                addressRow("系统 HTTPS 代理", route.https)
                addressRow("系统 SOCKS 代理", route.socks)
                addressRow("流迹出口", store.externalProxy.enabled ? (store.externalProxy.endpoint?.label ?? "直连") : "直连")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceTheme.sidebar, in: RoundedRectangle(cornerRadius: 8))
            if route.usesAutomaticConfiguration {
                Text("当前使用自动代理（PAC 或自动发现）。可在系统设置中调整，或给单个客户端指定流迹。")
            } else if !connected {
                Text("开始后，当前网络服务的 HTTP 和 HTTPS 会指向流迹。要沿用原来的本机代理出口，可在「外部代理设置」中选择。停止监听或退出时会恢复原设置。")
            } else if capturing {
                Label("系统代理已指向流迹，正在录制", systemImage: "checkmark.circle")
                    .foregroundStyle(WorkspaceTheme.good)
            }
            if case let .failed(message) = store.state {
                Text(message).foregroundStyle(WorkspaceTheme.failure)
            }
            if let message = store.macProxyMessage {
                Text(message)
                    .foregroundStyle(store.macProxyFailed ? WorkspaceTheme.failure : WorkspaceTheme.muted)
                    .textSelection(.enabled)
            }
            HStack {
                Button("开始 Mac 抓包", action: store.startMacCapture)
                    .buttonStyle(.borderedProminent)
                    .disabled(capturing || !route.isAvailable || route.usesAutomaticConfiguration || store.macProxyBusy || store.isStopping)
                if store.hasMacProxyBackup {
                    Button("恢复原系统代理") { store.restoreMacProxy() }.disabled(store.macProxyBusy)
                }
                if store.macProxyBusy { ProgressView().controlSize(.small) }
            }
            HStack {
                Button("监听端口与单个客户端…") { store.presentedProxySettings = .connection }
                Button("外部代理设置…") { store.presentedProxySettings = .externalProxy }
                Spacer()
                Button("系统设置…") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
                Button("刷新") { store.refreshMacProxyStatus() }
            }
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addressRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(WorkspaceTheme.muted)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}
