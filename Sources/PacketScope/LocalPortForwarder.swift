import Darwin
import Foundation
import SwiftUI

@MainActor
final class LocalPortForwarder: ObservableObject {
    @Published private(set) var state: ProxyState = .stopped
    @Published private(set) var ports: (listen: UInt16, target: UInt16)?

    private let relay = LoopbackPortRelay()
    private var generation = UUID()
    private var isStopping = false

    func start(listenPort: UInt16, targetPort: UInt16) {
        guard !isStopping, ports == nil else { return }
        guard listenPort != 0, targetPort != 0, listenPort != targetPort else {
            state = .failed("请输入两个不同的有效端口。")
            return
        }

        let generation = UUID()
        self.generation = generation
        ports = (listenPort, targetPort)
        state = .starting
        relay.start(listenPort: listenPort, targetPort: targetPort) { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.state = state
                if case .failed = state { self.ports = nil }
            }
        }
    }

    func stop() {
        guard !isStopping, ports != nil else { return }
        isStopping = true
        generation = UUID()
        relay.stop { [weak self] in
            DispatchQueue.main.async {
                self?.ports = nil
                self?.state = .stopped
                self?.isStopping = false
            }
        }
    }

    deinit {
        relay.stop {}
    }
}

private final class LoopbackPortRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.packetscope.loopback-relay", qos: .userInitiated)
    private var listener: DispatchSourceRead?
    private var listenerSocket: RelaySocket?
    private var pendingStops: [@Sendable () -> Void] = []
    private var clients: [UUID: PortRelayConnection] = [:]

    func start(listenPort: UInt16, targetPort: UInt16, onState: @escaping @Sendable (ProxyState) -> Void) {
        queue.async { [self] in
            guard listener == nil, listenPort != targetPort, listenPort != 0, targetPort != 0 else { return }
            do {
                let socket = try RelaySocket.open()
                try socket.setOption(SO_REUSEADDR)
                try checkSocket(withLoopbackEndpoint(port: listenPort) {
                    Darwin.bind(socket.descriptor, $0, $1)
                })
                try checkSocket(Darwin.listen(socket.descriptor, SOMAXCONN))

                let source = DispatchSource.makeReadSource(fileDescriptor: socket.descriptor, queue: queue)
                source.setEventHandler { [weak self, weak socket] in
                    guard let self, let socket, self.listenerSocket === socket,
                          self.pendingStops.isEmpty else { return }
                    do {
                        try self.acceptClients(from: socket, targetPort: targetPort)
                    } catch {
                        let message = "无法接受本机连接。\(error.localizedDescription)"
                        self.stopListening { onState(.failed(message)) }
                    }
                }
                source.setCancelHandler { [weak self, socket] in
                    socket.close()
                    guard let self else { return }
                    self.listener = nil
                    self.listenerSocket = nil
                    let completions = self.pendingStops
                    self.pendingStops.removeAll()
                    completions.forEach { $0() }
                }
                listenerSocket = socket
                listener = source
                source.resume()
                onState(.running(listenPort))
            } catch {
                onState(.failed("无法监听本机端口 \(listenPort)。\(error.localizedDescription)"))
            }
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in stopListening(completion: completion) }
    }

    private func acceptClients(from socket: RelaySocket, targetPort: UInt16) throws {
        for _ in 0..<64 {
            let descriptor = Darwin.accept(socket.descriptor, nil, nil)
            if descriptor < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR || errno == ECONNABORTED { continue }
                throw relayingError()
            }
            let inbound = RelaySocket(descriptor: descriptor)
            guard clients.count < 64 else { continue }
            do {
                try inbound.configure()
                let outbound = try RelaySocket.open()
                let id = UUID()
                let pair = PortRelayConnection(
                    inbound: inbound, outbound: outbound, queue: queue,
                    onClose: { [weak self] in self?.clients[id] = nil }
                )
                clients[id] = pair
                pair.start(targetPort: targetPort)
            } catch {
                continue
            }
        }
    }

    private func stopListening(completion: @escaping @Sendable () -> Void) {
        guard let listener else {
            completion()
            return
        }
        pendingStops.append(completion)
        guard pendingStops.count == 1 else { return }
        let open = Array(clients.values)
        clients.removeAll()
        open.forEach { $0.close() }
        listener.cancel()
    }
}

private func withLoopbackEndpoint(port: UInt16, _ action: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    let size = MemoryLayout<sockaddr_in>.size
    var endpoint = sockaddr_in()
    endpoint.sin_len = UInt8(size)
    endpoint.sin_family = sa_family_t(AF_INET)
    endpoint.sin_port = port.bigEndian
    endpoint.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
    return withUnsafePointer(to: &endpoint) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { action($0, socklen_t(size)) }
    }
}

private func relayingError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private func checkSocket(_ status: Int32) throws {
    if status < 0 { throw relayingError() }
}

private final class RelaySocket {
    private(set) var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func open() throws -> RelaySocket {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try checkSocket(descriptor)
        let socket = RelaySocket(descriptor: descriptor)
        try socket.configure()
        return socket
    }

    func configure() throws {
        try checkSocket(fcntl(descriptor, F_SETFL, O_NONBLOCK))
        try checkSocket(fcntl(descriptor, F_SETFD, FD_CLOEXEC))
        try setOption(SO_NOSIGPIPE)
    }

    func setOption(_ name: Int32) throws {
        var enabled: Int32 = 1
        let size = socklen_t(MemoryLayout.size(ofValue: enabled))
        try checkSocket(setsockopt(descriptor, SOL_SOCKET, name, &enabled, size))
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}

// Sources begin suspended. Keeping their socket in the cancellation handlers prevents
// its descriptor from being reused while either source is still registered.
private final class RelaySocketEvents {
    let socket: RelaySocket
    let reader: DispatchSourceRead
    let writer: DispatchSourceWrite
    private var reading = false
    private var writing = false

    init(socket: RelaySocket, queue: DispatchQueue) {
        self.socket = socket
        reader = DispatchSource.makeReadSource(fileDescriptor: socket.descriptor, queue: queue)
        writer = DispatchSource.makeWriteSource(fileDescriptor: socket.descriptor, queue: queue)
        reader.setCancelHandler { withExtendedLifetime(socket) {} }
        writer.setCancelHandler { withExtendedLifetime(socket) {} }
    }

    func setReading(_ enabled: Bool) {
        guard enabled != reading else { return }
        reading = enabled
        if enabled { reader.resume() } else { reader.suspend() }
    }

    func setWriting(_ enabled: Bool) {
        guard enabled != writing else { return }
        writing = enabled
        if enabled { writer.resume() } else { writer.suspend() }
    }

    func cancel() {
        reader.cancel()
        writer.cancel()
        setReading(true)
        setWriting(true)
    }
}

private final class PortRelayConnection {
    private final class Direction {
        let input: RelaySocketEvents
        let output: RelaySocketEvents
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var offset = 0
        var count = 0
        var ended = false

        init(input: RelaySocketEvents, output: RelaySocketEvents) {
            self.input = input
            self.output = output
        }
    }

    private let inbound: RelaySocketEvents
    private let outbound: RelaySocketEvents
    private let upload: Direction
    private let download: Direction
    private let onClose: () -> Void
    private var closed = false
    private var connecting = true

    init(inbound: RelaySocket, outbound: RelaySocket, queue: DispatchQueue, onClose: @escaping () -> Void) {
        self.inbound = RelaySocketEvents(socket: inbound, queue: queue)
        self.outbound = RelaySocketEvents(socket: outbound, queue: queue)
        upload = Direction(input: self.inbound, output: self.outbound)
        download = Direction(input: self.outbound, output: self.inbound)
        self.onClose = onClose
    }

    func start(targetPort: UInt16) {
        inbound.reader.setEventHandler { [weak self] in
            guard let self else { return }
            self.read(self.upload)
        }
        outbound.reader.setEventHandler { [weak self] in
            guard let self else { return }
            self.read(self.download)
        }
        inbound.writer.setEventHandler { [weak self] in
            guard let self else { return }
            self.flush(self.download)
        }
        outbound.writer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            if self.connecting {
                self.completeConnect()
            } else {
                self.flush(self.upload)
            }
        }
        let result = withLoopbackEndpoint(port: targetPort) {
            Darwin.connect(outbound.socket.descriptor, $0, $1)
        }
        if result == 0 {
            connected()
        } else if errno == EINPROGRESS || errno == EINTR {
            outbound.setWriting(true)
        } else {
            close()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        inbound.cancel()
        outbound.cancel()
        onClose()
    }

    private func completeConnect() {
        var connectionError: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: connectionError))
        if getsockopt(outbound.socket.descriptor, SOL_SOCKET, SO_ERROR, &connectionError, &length) == 0, connectionError == 0 {
            connected()
        } else {
            close()
        }
    }

    private func connected() {
        connecting = false
        outbound.setWriting(false)
        inbound.setReading(true)
        outbound.setReading(true)
    }

    private func read(_ direction: Direction) {
        guard !closed, !direction.ended, direction.count == 0 else { return }
        let received = direction.buffer.withUnsafeMutableBytes {
            Darwin.recv(direction.input.socket.descriptor, $0.baseAddress, $0.count, 0)
        }
        if received > 0 {
            direction.count = received
            flush(direction)
        } else if received == 0 {
            direction.ended = true
            direction.input.setReading(false)
            Darwin.shutdown(direction.output.socket.descriptor, SHUT_WR)
            if upload.ended && download.ended { close() }
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            close()
        }
    }

    private func flush(_ direction: Direction) {
        guard !closed, direction.count > 0 else { return }
        while direction.offset < direction.count {
            let sent = direction.buffer.withUnsafeBytes {
                Darwin.send(direction.output.socket.descriptor, $0.baseAddress?.advanced(by: direction.offset),
                            direction.count - direction.offset, 0)
            }
            if sent > 0 {
                direction.offset += sent
            } else if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                direction.input.setReading(false)
                direction.output.setWriting(true)
                return
            } else if sent == 0 || errno != EINTR {
                close()
                return
            }
        }
        direction.output.setWriting(false)
        direction.offset = 0
        direction.count = 0
        direction.input.setReading(true)
    }
}

struct LocalPortForwardingSheet: View {
    @ObservedObject var forwarder: LocalPortForwarder
    @Environment(\.dismiss) private var dismiss
    @State private var listen = ""
    @State private var target = ""

    private var validPorts: (UInt16, UInt16)? {
        guard let input = UInt16(listen), let output = UInt16(target),
              input > 0, output > 0, input != output else { return nil }
        return (input, output)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("本机端口转发")
                .font(.system(size: 21, weight: .semibold))
            Text("在 127.0.0.1 的两个端口之间转发 TCP 数据。")
                .font(.subheadline)
                .foregroundStyle(WorkspaceTheme.muted)
            HStack(spacing: 14) {
                field("监听端口", text: $listen, example: "9000")
                Image(systemName: "arrow.right")
                    .foregroundStyle(WorkspaceTheme.muted)
                    .accessibilityHidden(true)
                    .padding(.top, 20)
                field("目标端口", text: $target, example: "8080")
            }
            .disabled(forwarder.ports != nil)
            status
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if forwarder.ports != nil {
                    Button("停止转发") { forwarder.stop() }
                } else {
                    Button("启动转发") {
                        if let (input, output) = validPorts {
                            forwarder.start(listenPort: input, targetPort: output)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validPorts == nil)
                }
            }
        }
        .padding(24)
        .frame(width: 435)
        .foregroundStyle(WorkspaceTheme.ink)
        .background(WorkspaceTheme.canvas)
        .onAppear {
            if let ports = forwarder.ports {
                listen = String(ports.listen)
                target = String(ports.target)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, example: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.subheadline.weight(.medium))
            TextField(label, text: text, prompt: Text(example))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    @ViewBuilder private var status: some View {
        switch forwarder.state {
        case .stopped:
            EmptyView()
        case .starting:
            Text("正在启动监听…").font(.caption).foregroundStyle(WorkspaceTheme.muted)
        case let .running(port):
            Text("正在监听 127.0.0.1:\(port)").font(.caption).foregroundStyle(WorkspaceTheme.good)
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(WorkspaceTheme.failure)
        }
    }
}
