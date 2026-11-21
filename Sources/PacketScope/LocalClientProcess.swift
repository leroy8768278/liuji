import Darwin
import Foundation

struct LocalClientProcess: Codable, Equatable, Sendable {
    let pid: Int32
    let name: String
    var label: String { "\(name) (PID \(pid))" }
}

/// This object is accessed on the proxy queue and shared by a tunnel and its HTTP stream.
final class ClientProcessLookup {
    var result: LocalClientProcess?
}

final class LocalClientProcessResolver {
    private let queue = DispatchQueue(label: "app.packetscope.client-process", qos: .utility)
    private var nextScan = DispatchTime.now()
    private var pending: [UInt16: [(UInt16, (LocalClientProcess?) -> Void)]] = [:]

    func resolve(port: UInt16, peer: UInt16, completed: @escaping (LocalClientProcess?) -> Void) {
        queue.async { [self] in
            let first = pending.isEmpty
            guard pending[port, default: []].count < 256 else { completed(nil); return }
            pending[port, default: []].append((peer, completed))
            if first { queue.asyncAfter(deadline: max(nextScan, .now())) { self.scan() } }
        }
    }

    private func scan() {
        let requests = pending
        pending.removeAll()
        for (port, clients) in requests {
            let processes = Self.lookup(port: port, peers: Set(clients.map(\.0)))
            for (peer, callback) in clients { callback(processes[peer]) }
        }
        nextScan = .now() + .seconds(1)
    }

    static func lookup(port: UInt16, peers: Set<UInt16>) -> [UInt16: LocalClientProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-w", "-nP", "-a", "-u", String(getuid()), "-i4TCP@127.0.0.1:\(port)", "-sTCP:ESTABLISHED", "-Fpn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2), execute: timeout)
        defer { timeout.cancel() }
        var data = Data()
        let reader = pipe.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 32_768), !chunk.isEmpty {
            if data.count + chunk.count > 512 * 1024 {
                if task.isRunning { task.terminate() }
                try? reader.close()
                return [:]
            }
            data.append(chunk)
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return [:] }
        let pairs = clientPIDs(String(decoding: data, as: UTF8.self), port: port, peers: peers)
        return pairs.compactMapValues { pid in
            var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
            let count = buffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            guard count > 0 else { return nil }
            return LocalClientProcess(pid: pid, name: String(cString: buffer))
        }
    }

    static func clientPIDs(_ output: String, port: UInt16, peers: Set<UInt16>) -> [UInt16: Int32] {
        var result: [UInt16: Set<Int32>] = [:]
        var pid: Int32?
        let prefix = "127.0.0.1:"
        let suffix = "->127.0.0.1:\(port)"
        for field in output.split(separator: "\n") {
            if field.first == "p" { pid = Int32(field.dropFirst()); continue }
            guard field.first == "n", let pid, pid != getpid() else { continue }
            let socket = field.dropFirst()
            guard socket.hasPrefix(prefix), socket.hasSuffix(suffix),
                  let peer = UInt16(socket.dropFirst(prefix.count).dropLast(suffix.count)),
                  peers.contains(peer) else { continue }
            result[peer, default: []].insert(pid)
        }
        return result.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
}
