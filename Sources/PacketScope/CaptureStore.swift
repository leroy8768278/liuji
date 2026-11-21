import Foundation
import SwiftUI

enum CaptureFilter: Hashable {
    case all, http, tunnels, failures, mac, phone, host(String)
    static let general: [Self] = [.all, .http, .tunnels, .mac, .phone, .failures]

    var title: String {
        switch self {
        case .all: "全部会话"
        case .http: "HTTP 请求"
        case .tunnels: "HTTPS 隧道"
        case .failures: "失败会话"
        case .mac: "Mac 会话"
        case .phone: "手机会话"
        case let .host(host): host
        }
    }

    var icon: String {
        switch self {
        case .all: "tray.full"
        case .http: "arrow.left.arrow.right"
        case .tunnels: "lock"
        case .failures: "exclamationmark.circle"
        case .mac: "laptopcomputer"
        case .phone: "iphone"
        case .host: "globe"
        }
    }

    func includes(_ session: CaptureSession) -> Bool {
        switch self {
        case .all: true
        case .http: !session.isTunnel
        case .tunnels: session.isTunnel
        case .failures: session.error != nil || (session.statusCode ?? 0) >= 400
        case .mac: session.device != .phone
        case .phone: session.device == .phone
        case let .host(host): session.host == host
        }
    }
}

enum CaptureSource: Equatable {
    case live, demo, archive(URL), history(Int)

    var title: String {
        switch self {
        case .live: "实时抓包"
        case .demo: "示例数据"
        case let .history(number): "会话 \(number)"
        case let .archive(url): url.lastPathComponent
        }
    }

    var isArchive: Bool {
        if case .history = self { return true }
        if case .archive = self { return true }
        return false
    }
}

@MainActor
final class CaptureStore: ObservableObject {
    static let defaultPort: UInt16 = 8_888
    static let sampleSessions = DemoSessions.make()

    @Published private(set) var state: ProxyState = .stopped
    @Published private(set) var isStopping = false
    @Published private(set) var activeSessionNumber = 1
    @Published private(set) var previousSessions: [Int: [CaptureSession]] = [:]
    private var pendingInPreviousSession: [UUID: Int] = [:]
    @Published private(set) var liveSessions: [CaptureSession] = []
    @Published private(set) var hostLists = CaptureHostLists()
    @Published var showFocusedHosts = false
    @Published private(set) var configuredPort: UInt16
    @Published private(set) var ruleSet: ProxyRuleSet
    @Published private(set) var source: CaptureSource = .live
    @Published private(set) var recordingEnabled = true
    @Published private(set) var recordingLimit: Int
    @Published private(set) var trafficOptions: ProxyTrafficOptions
    @Published private(set) var pendingBreakpoints: [UUID: CaptureSession] = [:]
    @Published private(set) var mobileState: ProxyState = .stopped
    @Published private(set) var mobileConfiguration: MobileProxyConfiguration?
    @Published private(set) var macRoute = MacProxyRoute.current()
    @Published private(set) var macServiceName: String?
    @Published private(set) var hasMacProxyBackup: Bool
    @Published private(set) var macProxyBusy = false
    @Published private(set) var macProxyMessage: String?
    @Published private(set) var macProxyFailed = false
    @Published var localRequestDraft: LocalRequestDraft?
    @Published var presentedTool: ProxyToolKind?
    @Published var presentedProxySettings: ProxySettingsPage?
    @Published var showRuleProfiles = false
    @Published var presentedOutputSettings: CaptureOutputPage?
    @Published private(set) var outputOptions = CaptureOutputOptions()
    @Published private(set) var outputError: String?
    let sessionSearch = WorkspaceSessionSearch()
    @Published var requestedFileAction: SessionFileAction?
    @Published var isReadingArchive = false
    private(set) var initialToolRule: ProxyRule?

    let ownedHTTPS = OwnedHTTPSSettings()
    private(set) var httpsSeed: (host: String, port: UInt16)?
    @Published private(set) var collectClientProcess = UserDefaults.standard.bool(forKey: "collectClientProcess")
    func setClientProcessCollection(_ enabled: Bool) {
        collectClientProcess = enabled
        UserDefaults.standard.set(enabled, forKey: "collectClientProcess")
        engine.setProcessCollection(enabled)
    }

    @Published private(set) var externalProxy = ExternalProxySetting()
    private(set) var suggestedExternalProxy: LoopbackHTTPProxy?

    func setExternalProxy(_ setting: ExternalProxySetting) {
        guard !setting.enabled || setting.endpoint?.usable(excluding: port) == true else { return }
        externalProxy = setting
        UserDefaults.standard.set(try? JSONEncoder().encode(setting), forKey: "externalHTTPProxy")
        engine.setExternalProxy(setting.enabled ? setting.endpoint : nil)
    }

    private let engine = ProxyEngine()
    private let macProxyController: MacSystemProxyController
    private let readMacRoute: () -> MacProxyRoute
    private var macRouteMonitor: MacProxyRouteMonitor?
    private var macProxyTask: Task<Bool, Never>?
    private var listenerWaiters = [CheckedContinuation<UInt16, Error>]()
    let portForwarder = LocalPortForwarder()
    private let outputQueue = DispatchQueue(label: "app.packetscope.capture-output", qos: .utility)
    private var generation = UUID()
    private var mobileGeneration = UUID()
    private var clearedAt = Date.distantPast
    private var resumedAt = Date.distantPast
    private var discarded = Set<UUID>()
    @Published private var archivedSessions: [CaptureSession] = []
    private static let portPreference = "proxyPort"
    private static let rulesPreference = "proxyRules"
    private static let recordingLimitPreference = "recordingLimit"
    private static let trafficOptionsPreference = "proxyTrafficOptions"

    init(macProxyController: MacSystemProxyController = MacSystemProxyController(),
         readMacRoute: @escaping () -> MacProxyRoute = MacProxyRoute.current) {
        self.macProxyController = macProxyController
        self.readMacRoute = readMacRoute
        hasMacProxyBackup = macProxyController.hasSavedConfiguration
        let savedPort = UserDefaults.standard.integer(forKey: Self.portPreference)
        configuredPort = UInt16(exactly: savedPort).flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultPort
        let savedRules = UserDefaults.standard.data(forKey: Self.rulesPreference)
        ruleSet = savedRules.flatMap { try? JSONDecoder().decode(ProxyRuleSet.self, from: $0) } ?? ProxyRuleSet()
        let limit = UserDefaults.standard.integer(forKey: Self.recordingLimitPreference)
        recordingLimit = (50...1_000).contains(limit) ? limit : 500
        let savedTraffic = UserDefaults.standard.data(forKey: Self.trafficOptionsPreference)
        trafficOptions = savedTraffic.flatMap { try? JSONDecoder().decode(ProxyTrafficOptions.self, from: $0) } ?? ProxyTrafficOptions()
        trafficOptions.breakpointsEnabled = false
        ownedHTTPS.onChange = { [weak engine] routes in engine?.updateOwnedHTTPS(routes) }
        if let data = UserDefaults.standard.data(forKey: "externalHTTPProxy"),
           let recovered = try? JSONDecoder().decode(ExternalProxySetting.self, from: data),
           recovered.endpoint?.usable(excluding: configuredPort) == true {
            externalProxy = recovered
            engine.setExternalProxy(recovered.enabled ? recovered.endpoint : nil)
        }
        engine.setProcessCollection(collectClientProcess)
        engine.updateRules(ruleSet)
        engine.updateTrafficOptions(trafficOptions)
        refreshMacProxyStatus()
        macRouteMonitor = MacProxyRouteMonitor { [weak self] in self?.refreshMacProxyStatus() }
        if hasMacProxyBackup { restoreMacProxy() }
    }

    var sessions: [CaptureSession] {
        switch source {
        case .live: liveSessions
        case let .history(number): previousSessions[number] ?? []
        case .demo: Self.sampleSessions
        case .archive: archivedSessions
        }
    }

    func newRecordingSession() {
        previousSessions[activeSessionNumber] = liveSessions
        for row in liveSessions where !row.finished { pendingInPreviousSession[row.id] = activeSessionNumber }
        activeSessionNumber += 1
        clear()
        showLive()
    }

    func showRecordingSession(_ number: Int) {
        if number == activeSessionNumber { showLive() }
        else if previousSessions[number] != nil { source = .history(number) }
    }

    func closeViewedSession() {
        if case let .history(number) = source {
            previousSessions.removeValue(forKey: number)
            pendingInPreviousSession = pendingInPreviousSession.filter { $0.value != number }
        }
        showLive()
    }

    func showExampleOrReturnToLive() {
        if source == .live { source = .demo }
        else { showLive() }
    }

    func showArchive(_ sessions: [CaptureSession], url: URL) {
        archivedSessions = sessions.sorted { $0.startedAt < $1.startedAt }
        source = .archive(url)
    }

    private func showLive() {
        archivedSessions = []
        source = .live
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var port: UInt16 {
        if case let .running(port) = state { return port }
        return configuredPort
    }

    func setPort(_ port: UInt16) {
        guard port > 0, !isRunning, state != .starting else { return }
        if externalProxy.enabled && externalProxy.endpoint?.port == port {
            state = .failed("监听端口与本机 HTTP 上游相同，请先调整外部代理设置。")
            return
        }
        configuredPort = port
        state = .stopped
        UserDefaults.standard.set(Int(port), forKey: Self.portPreference)
    }

    func openTool(_ kind: ProxyToolKind, seed: ProxyRule? = nil) {
        initialToolRule = seed
        presentedTool = kind
    }

    func toggleRecording() {
        if !isRunning {
            recordingEnabled = true
            resumedAt = Date()
            start()
        } else {
            recordingEnabled.toggle()
            if recordingEnabled { resumedAt = Date() }
            else { autoSaveArchive() }
        }
    }

    func setNote(_ text: String, for id: UUID) {
        let note = text.isEmpty ? nil : String(text.prefix(8_192))
        switch source {
        case .live:
            if let i = liveSessions.firstIndex(where: { $0.id == id }) { liveSessions[i].userNote = note }
        case let .history(number):
            if let i = previousSessions[number]?.firstIndex(where: { $0.id == id }) { previousSessions[number]?[i].userNote = note }
        case .archive:
            if let i = archivedSessions.firstIndex(where: { $0.id == id }) { archivedSessions[i].userNote = note }
        case .demo: break
        }
    }

    func setRecordingLimit(_ limit: Int) {
        guard (50...1_000).contains(limit) else { return }
        recordingLimit = limit
        if liveSessions.count > limit { liveSessions.removeFirst(liveSessions.count - limit) }
        UserDefaults.standard.set(limit, forKey: Self.recordingLimitPreference)
    }

    func replaceHostEntries(_ kind: HostListKind, with entries: Set<String>) {
        hostLists.replace(kind, with: entries)
    }

    func toggleHostEntry(_ kind: HostListKind, entry: String) {
        guard let key = kind.entry(entry) else { return }
        var entries = hostLists.entries(kind)
        if entries.contains(key) { entries.remove(key) } else { entries.insert(key) }
        replaceHostEntries(kind, with: entries)
    }

    func setTrafficOptions(_ options: ProxyTrafficOptions) {
        guard ProxyTrafficOptions.latencyRange.contains(options.latencyMilliseconds),
              ProxyTrafficOptions.bandwidthRange.contains(options.bandwidthKiBPerSecond),
              options.hasValidBreakpointPath else { return }
        trafficOptions = options
        engine.updateTrafficOptions(options)
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: Self.trafficOptionsPreference)
        }
    }

    func openHTTPS(for url: String? = nil) {
        httpsSeed = url.flatMap { url in
            guard let parts = URLComponents(string: url), let host = parts.host,
                  let port = UInt16(exactly: parts.port ?? 443) else { return nil }
            return (host, port)
        }
        presentedProxySettings = .ownedHTTPS
    }

    func setBreakpoint(_ location: BreakpointLocation, enabled: Bool) {
        var options = trafficOptions
        var locations = options.breakpointLocations ?? []
        locations.removeAll { $0.sameLocation(as: location) }
        if enabled {
            if !options.breakpointsEnabled && options.useLocalPathBreakpoint == nil { options.useLocalPathBreakpoint = false }
            options.breakpointsEnabled = true
            locations.append(location)
        }
        options.breakpointLocations = locations
        setTrafficOptions(options)
    }

    func resolveBreakpoint(_ id: UUID, proceed: Bool, edit: CaptureHeader? = nil) {
        engine.resolveBreakpoint(sessionID: id, proceed: proceed, edit: edit)
    }

    func terminate(_ id: UUID) { engine.terminate(sessionID: id) }

    func startMobile(_ configuration: MobileProxyConfiguration) {
        guard isRunning, mobileState != .starting else { return }
        if case .running = mobileState { return }
        let generation = UUID()
        mobileGeneration = generation
        mobileConfiguration = configuration
        mobileState = .starting
        engine.startMobile(configuration, port: 0) { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.mobileGeneration == generation else { return }
                self.mobileState = state
                if case .failed = state { self.mobileConfiguration = nil }
            }
        }
    }

    func stopMobile() {
        mobileGeneration = UUID()
        engine.stopMobile()
        mobileState = .stopped
        mobileConfiguration = nil
    }

    func saveRules(_ rules: ProxyRuleSet) {
        guard rules.rules.allSatisfy({ $0.validationError == nil }),
              let data = try? JSONEncoder().encode(rules) else { return }
        ruleSet = rules
        engine.updateRules(rules)
        UserDefaults.standard.set(data, forKey: Self.rulesPreference)
    }

    func start() {
        guard !isRunning, !isStopping, state != .starting else { return }
        showLive()
        recordingEnabled = true
        resumedAt = Date()
        state = .starting
        let generation = UUID()
        self.generation = generation
        discarded.removeAll()
        pendingBreakpoints.removeAll()
        engine.start(port: configuredPort, onState: { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.state = state
                switch state {
                case let .running(port):
                    self.finishListenerWaiters(.success(port))
                case let .failed(message):
                    self.finishListenerWaiters(.failure(NSError(domain: "PacketScope.Listener", code: 1,
                                                               userInfo: [NSLocalizedDescriptionKey: message])))
                    self.stopMobile()
                    if self.hasMacProxyBackup && !self.macProxyBusy { self.restoreMacProxy() }
                case .stopped:
                    self.isStopping = false
                    self.finishListenerWaiters(.failure(CancellationError()))
                case .starting: break
                }
            }
        }, onSession: { [weak self] session in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.receive(session)
            }
        })
    }

    func stop() {
        guard !macProxyBusy else { return }
        if hasMacProxyBackup { restoreMacProxy(stopListener: true) }
        else { stopListener() }
    }

    private func stopListener() {
        guard isRunning || state == .starting else { return }
        isStopping = true
        if isRunning && recordingEnabled { autoSaveArchive() }
        stopMobile()
        engine.stop()
    }

    func refreshMacProxyStatus() {
        let route = readMacRoute()
        if let address = route.loopbackHTTP(excluding: port) { suggestedExternalProxy = address }
        if route != macRoute {
            macRoute = route
            if hasMacProxyBackup && !macProxyBusy && isRunning && !route.matches(port: port) {
                macProxyFailed = true
                macProxyMessage = "系统代理的生效地址已改变。可查看当前地址并恢复之前的配置。"
            }
        }
        let service = MacSystemProxyController.activeServiceName()
        if service != macServiceName { macServiceName = service }
    }

    private func finishListenerWaiters(_ result: Result<UInt16, Error>) {
        let waiting = listenerWaiters
        listenerWaiters.removeAll()
        for waiter in waiting { waiter.resume(with: result) }
    }

    func prepareForLocalRequest() async throws -> UInt16 {
        guard !isStopping else { throw LocalRequestError("监听正在停止，请稍后重试。") }
        let port = try await readyListener()
        try Task.checkCancellation()
        showLive()
        if !recordingEnabled { toggleRecording() }
        return port
    }

    private func readyListener() async throws -> UInt16 {
        if case let .running(port) = state { return port }
        return try await withCheckedThrowingContinuation { continuation in
            listenerWaiters.append(continuation)
            if state != .starting { start() }
        }
    }

    func startMacCapture() {
        guard !isStopping, !macProxyBusy else { return }
        changeMacProxy {
            let port = try await self.readyListener()
            self.refreshMacProxyStatus()
            let controller = self.macProxyController
            let hadRecoveryRecord = controller.hasSavedConfiguration
            let result: String
            if self.macRoute.matches(port: port) {
                result = "系统 HTTP 和 HTTPS 代理已指向流迹。"
            } else {
                result = try await Task.detached { try controller.enable(port: port) }.value
                for _ in 0..<12 {
                    self.refreshMacProxyStatus()
                    if self.macRoute.matches(port: port) || !self.isRunning { break }
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            // The listener can fail while the system authorization dialog is open.
            guard self.isRunning else {
                _ = try await Task.detached { try controller.restore() }.value
                throw NSError(domain: "PacketScope.Listener", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "监听已停止，请重新开始 Mac 抓包。"])
            }
            guard self.macRoute.matches(port: port) else {
                if !hadRecoveryRecord && controller.hasSavedConfiguration {
                    _ = try await Task.detached { try controller.restore() }.value
                }
                throw NSError(domain: "PacketScope.SystemProxy", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "系统当前生效的 HTTP 和 HTTPS 代理未指向流迹。请检查其他代理程序或自动代理。"])
            }
            self.showLive()
            if !self.recordingEnabled { self.resumedAt = Date() }
            self.recordingEnabled = true
            return result
        }
    }

    func restoreMacProxy(stopListener: Bool = false) {
        guard !macProxyBusy else { return }
        changeMacProxy {
            let controller = self.macProxyController
            let result = try await Task.detached { try controller.restore() }.value
            if stopListener { self.stopListener() }
            return result
        }
    }

    private func changeMacProxy(_ work: @escaping @MainActor () async throws -> String) {
        macProxyBusy = true
        macProxyMessage = nil
        macProxyFailed = false
        macProxyTask = Task {
            do { macProxyMessage = try await work() }
            catch {
                macProxyFailed = true
                macProxyMessage = error.localizedDescription
                presentedProxySettings = .system
            }
            hasMacProxyBackup = macProxyController.hasSavedConfiguration
            refreshMacProxyStatus()
            macProxyBusy = false
            macProxyTask = nil
            return !macProxyFailed
        }
    }

    func restoreMacProxyBeforeQuit() async -> Bool {
        if let task = macProxyTask { _ = await task.value }
        guard hasMacProxyBackup else { return true }
        restoreMacProxy()
        if let task = macProxyTask { return await task.value }
        return !hasMacProxyBackup
    }

    func setOutputOptions(_ options: CaptureOutputOptions) {
        outputOptions = options
        outputError = nil
    }

    func clear() {
        clearedAt = Date()
        liveSessions.removeAll()
    }

    func removeSessions(keeping id: UUID? = nil, removing removedID: UUID? = nil) {
        let removed = liveSessions.filter { session in
            if let removedID { return session.id == removedID }
            return session.id != id
        }
        discarded.formUnion(removed.lazy.filter { !$0.finished }.map(\.id))
        let removedIDs = Set(removed.map(\.id))
        liveSessions.removeAll { removedIDs.contains($0.id) }
    }

    func receive(_ session: CaptureSession) {
        if session.isPausedAtBreakpoint == true {
            if pendingBreakpoints[session.id] == nil && presentedProxySettings == nil { presentedProxySettings = .breakpoints }
            pendingBreakpoints[session.id] = session
        }
        else if pendingBreakpoints[session.id] != nil { pendingBreakpoints.removeValue(forKey: session.id) }
        if let folder = outputOptions.mirrorFolder,
           CaptureOutputWriter.matchesMirror(session: session, host: outputOptions.mirrorHost) {
            writeOutput { try CaptureOutputWriter.mirror(session: session, folder: folder) }
        }
        if let owner = pendingInPreviousSession[session.id] {
            if let index = previousSessions[owner]?.firstIndex(where: { $0.id == session.id }) {
                var updated = session
                updated.userNote = previousSessions[owner]?[index].userNote
                previousSessions[owner]?[index] = updated
            }
            if session.finished { pendingInPreviousSession.removeValue(forKey: session.id) }
            return
        }
        guard session.startedAt >= clearedAt else { return }
        let index = liveSessions.firstIndex(where: { $0.id == session.id })
        if hostLists.shouldDiscard(session, alreadyRecorded: index != nil, discarded: &discarded) { return }
        if let index {
            var updated = session
            updated.userNote = liveSessions[index].userNote
            liveSessions[index] = updated
        } else if recordingEnabled, session.startedAt >= resumedAt,
                  liveSessions.count < recordingLimit || session.startedAt >= liveSessions[0].startedAt {
            let index = liveSessions.firstIndex { $0.startedAt > session.startedAt } ?? liveSessions.endIndex
            liveSessions.insert(session, at: index)
            if liveSessions.count > recordingLimit { liveSessions.removeFirst() }
        }
    }

    private func autoSaveArchive() {
        guard let folder = outputOptions.archiveFolder, !liveSessions.isEmpty else { return }
        let sessions = liveSessions
        writeOutput { try CaptureOutputWriter.saveArchive(sessions: sessions, folder: folder) }
    }

    private func writeOutput(_ write: @escaping @Sendable () throws -> Void) {
        outputQueue.async { [weak self] in
            do { try write() }
            catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.outputError = message }
            }
        }
    }
}
