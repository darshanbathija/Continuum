import Foundation
import ClawdmeterShared
// Codex fix: OSLog is Apple-only. The Ubuntu/Zorin Swift toolchain
// fails with `no such module 'OSLog'` if we import it unconditionally
// from this Linux target. Gate the Apple-platform logger and provide
// a stderr-print fallback on Linux.
#if canImport(OSLog)
import OSLog
private let trayLogger = Logger(subsystem: "com.clawdmeter.linux", category: "TrayPollLoop")
#endif

private func trayLogWarning(_ message: String) {
#if canImport(OSLog)
    trayLogger.warning("\(message, privacy: .public)")
#else
    FileHandle.standardError.write(Data(("TrayPollLoop WARN: " + message + "\n").utf8))
#endif
}

/// Drives the AppIndicator gauge refresh at the 60s poll cadence.
///
/// Subscribes to the shared `UsagePoller`'s event stream (replaces the
/// Mac AppRuntime that hosts the same poller under SwiftUI). Each
/// `.usage(UsageData)` event re-renders the gauge PNG via
/// `CairoGaugeRenderer` and tells `AppIndicatorTray` to point at the new
/// path with the new label text.
///
/// Phase 4 build-out: real subscription path once UsagePoller is the
/// shared `actor` form (waiting on D8 actor migration).
public actor TrayPollLoop {
    public let provider: CairoGaugeRenderer.Provider
    private let renderer: CairoGaugeRenderer
    private let tray: AppIndicatorTray
    private var pollTask: Task<Void, Never>?
    private var lastSnapshot: UsageData?

    public init(provider: CairoGaugeRenderer.Provider, tray: AppIndicatorTray) {
        self.provider = provider
        self.renderer = CairoGaugeRenderer()
        self.tray = tray
    }

    /// Start the loop. Cancels any prior task.
    public func start(usageStream: AsyncStream<UsageData>) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for await snapshot in usageStream {
                guard let self else { break }
                await self.handle(snapshot: snapshot)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func handle(snapshot: UsageData) async {
        lastSnapshot = snapshot
        do {
            let url = try await renderer.renderAndWrite(provider: provider, usage: snapshot)
            let label = formatLabel(provider: provider, usage: snapshot)
            tray.setIcon(at: url, label: label)
        } catch {
            // P2-Linux-2: render failed (tmpfs full / permissions / Cairo
            // surface error). The previous icon stays, but emit a warning
            // so a tray rendering regression isn't invisible.
            trayLogWarning("Gauge render failed for \(provider.rawValue): \(error.localizedDescription)")
        }
    }

    private func formatLabel(provider: CairoGaugeRenderer.Provider, usage: UsageData) -> String {
        let prefix = provider == .claude ? "Cl" : "Cx"
        return "\(prefix) \(usage.sessionPct)%"
    }
}
