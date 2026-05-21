import Foundation
import ClawdmeterShared

/// Adapters from the iOS UsageModel data layer to portable
/// `TahoeLiveBindings`. Mirror of `MacTahoeAdapter` on Mac.
@MainActor
extension UsageModel {
    var tahoeLive: TahoeLiveBindings {
        TahoeLiveBindings(
            claude: row(usage: usage,                 provider: .claude, hasWeekly: true,  modelFallback: "Sonnet 4.5"),
            codex:  row(usage: codexSnapshot?.usage,  provider: .codex,  hasWeekly: true,  modelFallback: "gpt-5"),
            gemini: row(usage: geminiSnapshot?.usage, provider: .gemini, hasWeekly: false, modelFallback: "antigravity-pro")
        )
    }

    private func row(usage: UsageData?, provider: TahoeProvider, hasWeekly: Bool, modelFallback: String) -> TahoeLiveRow {
        guard let usage else { return .demo(provider) }
        let modelName: String = {
            if provider == .gemini, let m = usage.antigravityModel, !m.isEmpty { return m }
            return modelFallback
        }()
        return TahoeLiveRow(
            sessionPercent: Double(usage.sessionPct),
            weeklyPercent: hasWeekly ? Double(usage.weeklyPct) : -1,
            sessionResetIn: TahoeFmt.resetIn(minutes: usage.sessionResetMins),
            weeklyResetIn: hasWeekly ? TahoeFmt.resetIn(minutes: usage.weeklyResetMins) : "",
            modelName: modelName,
            autoReviveOn: false, // iOS doesn't surface AutoReviver state today
            autoReviveAgo: "",
            hasWeekly: hasWeekly
        )
    }
}
