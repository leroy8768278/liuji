import Darwin
import Foundation

// Executable harness for scripts/test-owned-https.py. All traffic is loopback.
@main
enum OwnedHTTPSProbe {
    static func main() {
        let args = CommandLine.arguments
        let originPort = UInt16(args[1])!
        let engine = ProxyEngine()
        do {
            let route = try OwnedHTTPSRoute(host: args[2], port: originPort,
                                           file: URL(fileURLWithPath: args[3]), password: "fixture")
            engine.updateOwnedHTTPS([route])
        } catch {
            print("CONFIG_ERROR", error.localizedDescription)
            exit(2)
        }
        var options = ProxyTrafficOptions()
        options.breakpointsEnabled = true
        options.useLocalPathBreakpoint = false
        options.breakpointLocations = [BreakpointLocation(url: "https://localhost:\(originPort)/owned-check",
                                                          includeAllPaths: false, phase: .both)!]
        engine.updateTrafficOptions(options)
        engine.start(port: 0, onState: { state in
            switch state {
            case let .running(port): print("PORT", port)
            case let .failed(message): fputs(message, stderr); exit(1)
            default: break
            }
            fflush(stdout)
        }, onSession: { session in
            if session.isPausedAtBreakpoint == true, let phase = session.breakpointPhase {
                print("PAUSED", phase.rawValue)
                engine.resolveBreakpoint(sessionID: session.id, proceed: true,
                    edit: CaptureHeader(name: "X-Debug-Phase", value: phase.rawValue))
            }
            if session.finished {
                print("FINISHED", session.method, session.url, session.statusCode ?? -1,
                      String(decoding: session.responseBody, as: UTF8.self))
            }
            fflush(stdout)
        })
        dispatchMain()
    }
}
