import Foundation

struct ProxyTrafficOptions: Codable, Equatable, Sendable {
    static let latencyRange = 0...2_000
    static let bandwidthRange = 16...10_240

    var throttleEnabled = false
    var latencyMilliseconds = 150
    var bandwidthKiBPerSecond = 256
    var breakpointsEnabled = false
    var breakpointPath = "/"

    var breakpointLocations: [BreakpointLocation]?
    var useLocalPathBreakpoint: Bool?
    var matchesLocalPath: Bool { useLocalPathBreakpoint ?? true }

    func shouldPause(_ session: CaptureSession?, phase: BreakpointPhase) -> Bool {
        guard breakpointsEnabled, let session else { return false }
        return breakpointLocations?.contains { $0.matches(session, phase: phase) } ?? false
    }

    var hasValidBreakpointPath: Bool {
        guard breakpointPath.hasPrefix("/"), breakpointPath.utf8.count <= 4_096,
              !breakpointPath.contains("?"), !breakpointPath.contains("#"), !breakpointPath.contains("*") else { return false }
        return URLComponents(string: "http://localhost" + breakpointPath)?.percentEncodedPath == breakpointPath
    }

    var latency: TimeInterval {
        Double(min(max(latencyMilliseconds, Self.latencyRange.lowerBound), Self.latencyRange.upperBound)) / 1_000
    }

    var bandwidthBytesPerSecond: Double {
        Double(min(max(bandwidthKiBPerSecond, Self.bandwidthRange.lowerBound), Self.bandwidthRange.upperBound)) * 1_024
    }
}
