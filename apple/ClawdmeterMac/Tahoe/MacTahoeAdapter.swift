import Foundation
import ClawdmeterShared

/// Adapters from the existing AppRuntime data layer to the portable
/// `TahoeLiveBindings` value type that the Tahoe SwiftUI views consume.
///
/// Keeps the views in `ClawdmeterShared/Tahoe/` free of any AppRuntime
/// import — they continue to render the demo fixture in Previews, while
/// `MacRootView.body` calls `runtime.tahoeLive` at render time to feed
/// real `UsageData` snapshots in.
@MainActor
extension AppRuntime {
    /// Compose live bindings from the three per-provider AppModels. Each
    /// `.usage` is optional (poller hasn't returned yet); we fall back to a
    /// demo row in that case so the layout doesn't collapse with empty
    /// strings.
    var tahoeLive: TahoeLiveBindings {
        TahoeLiveBindings(
            claude: tahoeRow(model: claudeModel, provider: .claude),
            codex:  tahoeRow(model: codexModel,  provider: .codex),
            gemini: tahoeRow(model: geminiModel, provider: .gemini)
        )
    }

    private func tahoeRow(model: AppModel, provider: TahoeProvider) -> TahoeLiveRow {
        guard let usage = model.usage else { return .demo(provider) }
        let modelName: String = {
            if provider == .gemini, let m = usage.antigravityModel, !m.isEmpty {
                return m
            }
            return model.config.reviveModel.isEmpty ? provider.displayName : model.config.reviveModel
        }()
        return TahoeLiveRow(
            sessionPercent: Double(usage.sessionPct),
            weeklyPercent: model.config.hasWeeklyWindow ? Double(usage.weeklyPct) : -1,
            sessionResetIn: TahoeFmt.resetIn(minutes: usage.sessionResetMins),
            weeklyResetIn: model.config.hasWeeklyWindow ? TahoeFmt.resetIn(minutes: usage.weeklyResetMins) : "",
            modelName: modelName,
            autoReviveOn: model.config.supportsAutoRevive ? model.autoReviver.isEnabled : false,
            autoReviveAgo: model.config.supportsAutoRevive
                ? TahoeFmt.ago(from: nil) // AutoReviver doesn't currently surface lastFiredAt;
                                          // when added, plumb here.
                : "",
            hasWeekly: model.config.hasWeeklyWindow
        )
    }
}
