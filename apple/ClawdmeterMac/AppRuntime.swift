import Foundation
import Combine
import ClawdmeterShared
import OSLog

private let runtimeLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AppRuntime")

/// App-level owner for all provider models. Lives for the app's lifetime as
/// a `@StateObject` in `ClawdmeterMacApp`.
///
/// Why: codex's diagnosis — `MenuBarExtra` label `.task` modifiers on macOS
/// Tahoe are unreliable for starting app-owned work, and `MenuBarExtra` scenes
/// don't invalidate from per-child @ObservedObject changes consistently. By
/// owning both models here and forwarding their `objectWillChange` to this
/// runtime, every per-model `@Published` change re-invalidates the parent
/// scene, which reliably re-snapshots the menu bar label.
@MainActor
final class AppRuntime: ObservableObject {

    let claudeModel: AppModel
    let codexModel: AppModel

    private var cancellables = Set<AnyCancellable>()
    private var usageQueryService: UsageQueryService?

    init() {
        let claudeTokenProvider = KeychainTokenProvider()
        // Mirror Claude Code's local OAuth token into our shared, iCloud-synced
        // Keychain entry so the iPhone and Watch apps can read the same token
        // with zero manual setup. Best-effort — no token, no mirror.
        if let token = claudeTokenProvider.currentAccessToken {
            PastedAnthropicTokenProvider.shared().setToken(token)
            runtimeLogger.info("Mirrored Claude token (\(token.count, privacy: .public) chars) into iCloud Keychain")
        }
        self.claudeModel = AppModel(
            config: .claude,
            source: AnthropicSource(tokenProvider: claudeTokenProvider),
            tokenProvider: claudeTokenProvider
        )

        let codexTokenProvider = CodexTokenProvider()
        self.codexModel = AppModel(
            config: .codex,
            source: CodexSource(tokenProvider: codexTokenProvider),
            tokenProvider: codexTokenProvider
        )

        // Don't forward objectWillChange — it was saturating main thread with
        // SwiftUI invalidations and starving the per-poller main-queue hops
        // for the slower provider. Let each MenuBarGaugeView observe its own
        // model directly.

        // Start both pollers immediately. AppModel.start() is idempotent.
        claudeModel.start()
        codexModel.start()

        // Vend the Mach service the widget extension queries. Created here
        // (after the models) so the service can hand back live in-memory
        // snapshots from the moment it accepts its first connection.
        self.usageQueryService = UsageQueryService(runtime: self)

        runtimeLogger.info("AppRuntime.init COMPLETE instance=\(ObjectIdentifier(self).hashValue)")
    }

    deinit {
        runtimeLogger.warning("AppRuntime.deinit")
    }
}
