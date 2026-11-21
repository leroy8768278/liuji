import AppKit
import SwiftUI

@main
struct PacketScopeApp: App {
    @NSApplicationDelegateAdaptor private var applicationDelegate: PacketScopeApplicationDelegate
    @StateObject private var store = CaptureStore()
    @StateObject private var viewPreferences = ViewPreferences()
    @AppStorage("capture.sessionListPresentation") private var presentation = SessionListPresentation.structure

    var body: some Scene {
        Window("流迹", id: "capture") {
            WorkspaceView(store: store)
                .environmentObject(viewPreferences)
                .frame(minWidth: 1_050, minHeight: 610)
                .ignoresSafeArea(.container, edges: .top)
                .tint(WorkspaceTheme.accent)
                .onAppear { applicationDelegate.captureStore = store }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_340, height: 790)
        .commands {
            SessionFileEditCommands(store: store)
            CommandGroup(after: .windowList) {
                Divider()
                Button("会话错误…") { store.presentedProxySettings = .errors }
                Button("已录制的活动连接…") { store.presentedProxySettings = .connections }
            }
            CommandGroup(replacing: .help) {
                Button("流迹使用说明") {
                    if let url = Bundle.main.url(forResource: "使用说明", withExtension: "md") { NSWorkspace.shared.open(url) }
                }
                Button("局域网地址与手机接入…") { store.presentedProxySettings = .mobile }
                Button("功能对照与验证") {
                    if let url = Bundle.main.url(forResource: "charles-5.2.3-acceptance", withExtension: "md", subdirectory: "docs") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("开源许可证") {
                    if let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") { NSWorkspace.shared.open(url) }
                }
            }
            CommandGroup(after: .toolbar) {
                Button("结构视图") { presentation = .structure }.keyboardShortcut("9")
                Button("时序视图") { presentation = .sequence }.keyboardShortcut("0")
                Divider()
                Button("高亮规则…") { viewPreferences.page = .highlights }
                Button("查看器映射…") { viewPreferences.page = .mappings }
                Button("关注的主机…") { store.showFocusedHosts = true }
            }
            CommandMenu("代理") {
                Button(store.isRunning ? "停止监听" : "开启监听") {
                    if store.isRunning { store.stop() } else { store.start() }
                }
                .disabled(store.state == .starting || store.isStopping || store.macProxyBusy)
                Button(store.isRunning && store.recordingEnabled ? "暂停录制" : "开始录制") { store.toggleRecording() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.state == .starting)
                HTTPSProxyCommand(settings: store.ownedHTTPS) { store.openHTTPS() }
                Button(store.trafficOptions.throttleEnabled ? "停止限速" : "开启限速") {
                    var options = store.trafficOptions
                    options.throttleEnabled.toggle()
                    store.setTrafficOptions(options)
                }
                .keyboardShortcut("t", modifiers: .command)
                Button(store.trafficOptions.breakpointsEnabled ? "关闭断点" : "启用断点") {
                    var options = store.trafficOptions
                    options.breakpointsEnabled.toggle()
                    store.setTrafficOptions(options)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("录制设置…") { store.presentedProxySettings = .recording }
                Button("HTTPS 调试设置…") { store.openHTTPS() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("限速设置…") { store.presentedProxySettings = .throttling }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("断点设置…") { store.presentedProxySettings = .breakpoints }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("本机反向映射…") {
                    store.openTool(.mapRemote, seed: ProxyRule(kind: .mapRemote, host: "127.0.0.1", path: "/*"))
                }
                Button("本机端口转发…") { store.presentedProxySettings = .portForwarding }
                Divider()
                Button("代理设置…") { store.presentedProxySettings = .connection }
                Button("macOS 代理…") { store.presentedProxySettings = .system }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("手机接入与访问控制…") { store.presentedProxySettings = .mobile }
                Button("外部代理设置…") { store.presentedProxySettings = .externalProxy }
            }
            CommandMenu("工具") {
                ForEach(ProxyToolKind.allCases) { tool in
                    if [.mapRemote, .blockList].contains(tool) { Divider() }
                    Button("\(tool.title)…") { store.openTool(tool) }
                        .keyboardShortcut(tool.shortcut)
                        .disabled(store.presentedTool != nil)
                }
                Divider()
                Button("镜像本机响应…") { store.presentedOutputSettings = .mirror }
                Button("自动保存会话…") { store.presentedOutputSettings = .archive }
                Toggle("识别本机客户端进程", isOn: Binding(get: { store.collectClientProcess }, set: store.setClientProcessCollection))
                Divider()
                LocalRequestCommands(store: store)
                Divider()
                Button("导入规则配置…") { store.requestedFileAction = .importRules }
                Button("导出规则配置…") { store.requestedFileAction = .exportRules }
                Button("规则配置方案…") { store.showRuleProfiles = true }
            }
        }
    }
}

private extension ProxyToolKind {
    var shortcut: KeyboardShortcut? {
        switch self {
        case .noCaching: KeyboardShortcut("n", modifiers: [.option, .command])
        case .blockCookies: KeyboardShortcut("c", modifiers: [.option, .command])
        case .mapRemote: KeyboardShortcut("m", modifiers: [.option, .command])
        case .mapLocal: KeyboardShortcut("l", modifiers: [.option, .command])
        case .rewrite: KeyboardShortcut("r", modifiers: [.option, .command])
        case .dnsOverride: KeyboardShortcut("d", modifiers: [.option, .shift, .command])
        case .blockList, .allowList: nil
        }
    }
}

@MainActor
final class PacketScopeApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var captureStore: CaptureStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = captureStore, store.hasMacProxyBackup || store.macProxyBusy else { return .terminateNow }
        Task {
            if await store.restoreMacProxyBeforeQuit() {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                let alert = NSAlert()
                alert.messageText = "尚未恢复原系统代理"
                alert.informativeText = (store.macProxyMessage ?? "") + "\n如果现在退出，指向流迹的应用可能无法联网。下次打开流迹时会重试恢复。"
                alert.addButton(withTitle: "留在流迹")
                alert.addButton(withTitle: "仍然退出")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            }
        }
        return .terminateLater
    }
}

enum WorkspaceTheme {
    static let accent = adaptive(light: 0x006F65, dark: 0x67D7C2)
    static let accentFill = adaptive(light: 0xDBF2EB, dark: 0x173C38)
    static let brand = adaptive(light: 0x093D37, dark: 0xC5F7E9)
    static let canvas = adaptive(light: 0xFFFFFF, dark: 0x1B252B)
    static let chrome = adaptive(light: 0xF7FAFA, dark: 0x182227)
    static let sidebar = adaptive(light: 0xEDF4F3, dark: 0x141F24)
    static let rule = adaptive(light: 0xE2EBEB, dark: 0x2E3C42)
    static let ink = adaptive(light: 0x152C32, dark: 0xE7F0EF)
    static let muted = adaptive(light: 0x53676B, dark: 0xA9BCBD)
    static let good = adaptive(light: 0x176A46, dark: 0x83D9AB)
    static let goodFill = adaptive(light: 0xE5F4EA, dark: 0x223D34)
    static let warning = adaptive(light: 0x8C491A, dark: 0xF0B382)
    static let warningFill = adaptive(light: 0xFBEDE0, dark: 0x423229)
    static let failure = adaptive(light: 0xA13A3A, dark: 0xF19999)
    static let failureFill = adaptive(light: 0xFBEAEA, dark: 0x422B31)
    static let blue = adaptive(light: 0x2F589C, dark: 0x9BBFF4)
    static let blueFill = adaptive(light: 0xEAF1FC, dark: 0x26364B)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}
