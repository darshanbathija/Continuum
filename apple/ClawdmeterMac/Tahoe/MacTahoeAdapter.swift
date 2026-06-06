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
    /// `.usage` is optional (poller hasn't returned yet). Production rows
    /// must not fall back to the SwiftUI preview fixture because those demo
    /// values look like real quota numbers in the live Usage tab.
    var tahoeLive: TahoeLiveBindings {
        TahoeLiveBindings(
            claude: tahoeRow(model: claudeModel, provider: .claude),
            codex:  tahoeRow(model: codexModel,  provider: .codex),
            gemini: tahoeRow(model: geminiModel, provider: .gemini),
            // v0.28.0: Cursor now driven by a real AppModel (CursorSource
            // → api2.cursor.sh GetCurrentPeriodUsage) instead of the
            // static "Cursor Auto" placeholder. The same fallback path
            // tahoeRow renders for un-authed providers handles the
            // "cursor-agent not logged in" case (sessionPercent: 0,
            // resetIn: "—", modelName: "Cursor").
            cursor: tahoeRow(model: cursorModel, provider: .cursor),
            grok: tahoeRow(model: grokModel, provider: .grok)
        )
    }

    private func tahoeRow(model: AppModel, provider: TahoeProvider) -> TahoeLiveRow {
        let fallbackModelName = model.config.reviveModel.isEmpty ? provider.displayName : model.config.reviveModel
        guard let usage = model.usage else {
            return TahoeLiveRow(
                sessionPercent: 0,
                weeklyPercent: model.config.hasWeeklyWindow ? 0 : -1,
                sessionResetIn: "\u{2014}",
                weeklyResetIn: model.config.hasWeeklyWindow ? "\u{2014}" : "",
                modelName: fallbackModelName,
                autoReviveOn: false,
                autoReviveAgo: "",
                supportsAutoRevive: model.config.supportsAutoRevive,
                hasWeekly: model.config.hasWeeklyWindow,
                cursorQuota: nil
            )
        }
        let modelName: String = {
            if provider == .gemini, let m = usage.antigravityModel, !m.isEmpty {
                return m
            }
            return fallbackModelName
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
            supportsAutoRevive: model.config.supportsAutoRevive,
            hasWeekly: model.config.hasWeeklyWindow,
            cursorQuota: usage.cursorQuota
        )
    }

}
