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

    /// Secondary (multi-account) live columns, one per non-primary
    /// instance with a kind that maps onto a Tahoe provider column.
    /// Sorted by wireId for stable layout.
    var tahoeSecondaryColumns: [SecondaryTahoeColumn] {
        allAppModelsByWireId
            .compactMap { (wireId, model) -> SecondaryTahoeColumn? in
                guard let slash = wireId.firstIndex(of: "/") else { return nil }
                let kind = String(wireId[..<slash])
                let name = String(wireId[wireId.index(after: slash)...])
                guard name != ProviderInstanceId.primaryName else { return nil }
                let provider: TahoeProvider
                switch kind {
                case "claude": provider = .claude
                case "codex":  provider = .codex
                default: return nil
                }
                guard ProviderEnablement.isEnabled(kind) else { return nil }
                return SecondaryTahoeColumn(
                    wireId: wireId, accountName: name, provider: provider, model: model
                )
            }
            .sorted { $0.wireId < $1.wireId }
    }

    private func tahoeRow(model: AppModel, provider: TahoeProvider) -> TahoeLiveRow {
        Self.makeTahoeRow(model: model, provider: provider)
    }

    static func makeTahoeRow(model: AppModel, provider: TahoeProvider) -> TahoeLiveRow {
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


/// One multi-account gauge column: a non-primary instance's AppModel +
/// its Tahoe provider mapping. The row is computed at render time by
/// `SecondaryProviderColumn` (which observes the model) so per-poll
/// updates invalidate the gauge.
public struct SecondaryTahoeColumn: Identifiable {
    public let wireId: String
    public let accountName: String
    public let provider: TahoeProvider
    let model: AppModel
    public var id: String { wireId }
}
