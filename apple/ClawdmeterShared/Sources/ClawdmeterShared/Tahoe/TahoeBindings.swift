#if canImport(SwiftUI)
import SwiftUI

/// Value-type bindings that adapt the existing AppRuntime/UsageModel data
/// layer onto the Tahoe SwiftUI views. Each view takes one of these structs
/// (defaulting to the demo fixture) so it stays standalone-friendly in
/// Previews while still rendering live data when injected at the root.
///
/// **Why a value struct rather than `@EnvironmentObject`?** The Tahoe views
/// live in `ClawdmeterShared`, which can't import `ClawdmeterMac` or
/// `ClawdmeteriOS` types. The adapter pattern lives in the app targets, so
/// it can read AppModel/UsageModel and lower them into these portable shapes.

// MARK: - Per-provider live row

public struct TahoeLiveRow: Equatable, Sendable {
    public var sessionPercent: Double      // 0..100
    public var weeklyPercent: Double       // 0..100; nil-equivalent = -1
    public var sessionResetIn: String      // "2h 18m"
    public var weeklyResetIn: String       // "4d 6h"  (empty if no weekly)
    public var modelName: String           // "Sonnet 4.5" / "gpt-5" / "antigravity-pro"
    public var autoReviveOn: Bool
    public var autoReviveAgo: String       // "4h ago" / "" if never fired
    public var hasWeekly: Bool

    public init(
        sessionPercent: Double,
        weeklyPercent: Double = -1,
        sessionResetIn: String = "",
        weeklyResetIn: String = "",
        modelName: String = "",
        autoReviveOn: Bool = false,
        autoReviveAgo: String = "",
        hasWeekly: Bool = true
    ) {
        self.sessionPercent = sessionPercent
        self.weeklyPercent = weeklyPercent
        self.sessionResetIn = sessionResetIn
        self.weeklyResetIn = weeklyResetIn
        self.modelName = modelName
        self.autoReviveOn = autoReviveOn
        self.autoReviveAgo = autoReviveAgo
        self.hasWeekly = hasWeekly
    }

    /// Demo defaults — match `TahoeDemo.liveData[provider]`.
    public static func demo(_ provider: TahoeProvider) -> TahoeLiveRow {
        let d = TahoeDemo.liveData[provider] ?? TahoeDemo.liveData[.claude]!
        return TahoeLiveRow(
            sessionPercent: d.session, weeklyPercent: d.weekly,
            sessionResetIn: d.resetIn, weeklyResetIn: d.weeklyIn,
            modelName: {
                switch provider {
                case .claude: return "Sonnet 4.5"
                case .codex:  return "gpt-5"
                case .gemini: return "antigravity-pro"
                }
            }(),
            autoReviveOn: d.reviveOn, autoReviveAgo: d.reviveAgo,
            hasWeekly: true
        )
    }
}

/// All three providers, in one bag. Drives MacUsageView + MacMenubarPopover +
/// IOSLiveView.
public struct TahoeLiveBindings: Equatable, Sendable {
    public var claude: TahoeLiveRow
    public var codex:  TahoeLiveRow
    public var gemini: TahoeLiveRow

    public init(
        claude: TahoeLiveRow = .demo(.claude),
        codex:  TahoeLiveRow = .demo(.codex),
        gemini: TahoeLiveRow = .demo(.gemini)
    ) {
        self.claude = claude; self.codex = codex; self.gemini = gemini
    }

    public func row(for provider: TahoeProvider) -> TahoeLiveRow {
        switch provider {
        case .claude: return claude
        case .codex:  return codex
        case .gemini: return gemini
        }
    }

    /// All-demo default (used by Previews and as fallback).
    public static let demo = TahoeLiveBindings()
}

// MARK: - Reset-time formatting

public enum TahoeFmt {
    /// Convert minutes → "2h 18m" / "58m" / "4d 6h" / "—" (when negative or zero).
    public static func resetIn(minutes: Int) -> String {
        guard minutes > 0 else { return "\u{2014}" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        if h < 24 {
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        let d = h / 24
        let rh = h % 24
        return rh > 0 ? "\(d)d \(rh)h" : "\(d)d"
    }

    /// "4h ago" / "now" / "—" — for last-fired AutoReviver timestamps.
    public static func ago(from date: Date?, reference: Date = Date()) -> String {
        guard let date else { return "\u{2014}" }
        let mins = Int(reference.timeIntervalSince(date) / 60)
        if mins < 1 { return "now" }
        if mins < 60 { return "\(mins)m ago" }
        let h = mins / 60
        if h < 24 { return "\(h)h ago" }
        let d = h / 24
        return "\(d)d ago"
    }
}
#endif
