import Foundation
import ClawdmeterShared
import OSLog

private let loopbackLogger = Logger(subsystem: "com.clawdmeter.mac", category: "MacLoopbackClient")

/// Factory for the Mac in-process `AgentControlClient` that talks to the
/// local `AgentControlServer` over `127.0.0.1`. Same code path as iOS, so
/// the Mac Code IDE + Mac Chat get the unified daemon-client API the iOS
/// app has always used (PR #24a / D2).
///
/// Bootstrap sequence (A1 — synchronous):
/// 1. `AppRuntime.init` starts `AgentControlServer` synchronously, which
///    binds `boundPort` + `boundWsPort` before returning.
/// 2. `AppDelegate.applicationDidFinishLaunching` (or `AppRuntime.init`
///    tail) constructs the client via `MacLoopbackClient.make(from:)`,
///    handing in the live server reference.
/// 3. Client uses `server.localLoopbackToken` (per-launch random UUID)
///    as the Bearer auth value — not the pairing token, so iOS pairing
///    is independent.
/// 4. Mac SwiftUI surfaces hold the resulting `AgentControlClient` and
///    invoke RPCs exactly the way iOS does.
///
/// Returns `nil` if the server failed to bind (port-bind retry per
/// `AgentControlServer.portFallbackRange` exhausted). Callers should
/// surface this as an alert — see PR #24a Step 3 / critical-gap fix.
@MainActor
enum MacLoopbackClient {

    /// Build the loopback client from a started `AgentControlServer`.
    /// Returns `nil` if the server has no bound ports (catastrophic
    /// bind failure — Mac IDE actions won't work, surface to user).
    /// `@MainActor` because `AgentControlServer.boundPort`/`boundWsPort`
    /// are main-actor-isolated; callers are also main-actor-bound
    /// (AppRuntime.init runs on main).
    static func make(from server: AgentControlServer) -> AgentControlClient? {
        guard let httpPort = server.boundPort,
              let wsPort = server.boundWsPort
        else {
            loopbackLogger.error("MacLoopbackClient.make: server has no bound ports — bind likely failed in start()")
            return nil
        }
        loopbackLogger.info("MacLoopbackClient.make: connecting to 127.0.0.1:\(httpPort) (ws: \(wsPort)) with loopback token")
        return AgentControlClient(
            host: "127.0.0.1",
            httpPort: Int(httpPort),
            wsPort: Int(wsPort),
            token: server.localLoopbackToken,
            // The in-process daemon is this binary — seed the wire version so
            // Mac surfaces gating on `supportsExecutionHosts` (Settings →
            // Devices, host pickers) work from first paint. The Mac never runs
            // `refreshAll()` on this client the way iOS does.
            assumeServerWireVersion: AgentControlWireVersion.current
        )
    }
}
