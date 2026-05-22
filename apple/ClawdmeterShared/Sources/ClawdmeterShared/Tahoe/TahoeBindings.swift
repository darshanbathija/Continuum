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
                // PR #31: OpenCode's underlying model varies by user
                // auth (whichever provider they ran `opencode auth login`
                // for). Demo defaults to anthropic so the chip reads
                // meaningfully in Previews.
                case .opencode: return "via opencode"
                }
            }(),
            autoReviveOn: d.reviveOn, autoReviveAgo: d.reviveAgo,
            hasWeekly: true
        )
    }
}

/// All four providers, in one bag. Drives MacUsageView + MacMenubarPopover +
/// IOSLiveView. PR #31 added `opencode` as the 4th lane.
public struct TahoeLiveBindings: Equatable, Sendable {
    public var claude: TahoeLiveRow
    public var codex:  TahoeLiveRow
    public var gemini: TahoeLiveRow
    public var opencode: TahoeLiveRow

    public init(
        claude: TahoeLiveRow = .demo(.claude),
        codex:  TahoeLiveRow = .demo(.codex),
        gemini: TahoeLiveRow = .demo(.gemini),
        opencode: TahoeLiveRow = .demo(.opencode)
    ) {
        self.claude = claude; self.codex = codex; self.gemini = gemini
        self.opencode = opencode
    }

    public func row(for provider: TahoeProvider) -> TahoeLiveRow {
        switch provider {
        case .claude: return claude
        case .codex:  return codex
        case .gemini: return gemini
        case .opencode: return opencode
        }
    }

    /// All-demo default (used by Previews and as fallback).
    public static let demo = TahoeLiveBindings()
}

// MARK: - Code (Sessions IDE) bindings

/// Portable shape for a repository row in the Code IDE sidebar. Mirrors the
/// JSX `DEMO_REPOS` row literal so the existing MacCodeView body code keeps
/// working without restructuring — only the data source changes.
public struct TahoeCodeRepo: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var tint: OKLCH
    public var liveSessionCount: Int
    public var sessions: [TahoeCodeSession]
    public var recents: [TahoeCodeRecent]

    public init(key: String, name: String, tint: OKLCH,
                liveSessionCount: Int = 0,
                sessions: [TahoeCodeSession] = [],
                recents: [TahoeCodeRecent] = []) {
        self.key = key; self.name = name; self.tint = tint
        self.liveSessionCount = liveSessionCount
        self.sessions = sessions
        self.recents = recents
    }
}

public struct TahoeCodeSession: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var agent: TahoeProvider
    public var model: String
    public var status: Status
    public var mode: String       // plan | edit | worktree | local
    public var subtitle: String
    /// Optional plan markdown from the agent's last `ExitPlanMode` call. The
    /// Plan Halo card parses this into discrete bullet-numbered steps. Nil
    /// when the session is not in plan mode.
    public var runtimePlanText: String?
    /// Optional branch name where the agent will commit. Real sessions
    /// derive this from worktree path; demo sessions render the JSX literal.
    public var commitBranch: String?

    public enum Status: String, Hashable, Sendable {
        case running, paused, done, planning, degraded
    }

    public init(id: UUID, title: String, agent: TahoeProvider, model: String,
                status: Status, mode: String, subtitle: String,
                runtimePlanText: String? = nil,
                commitBranch: String? = nil) {
        self.id = id; self.title = title; self.agent = agent
        self.model = model; self.status = status; self.mode = mode; self.subtitle = subtitle
        self.runtimePlanText = runtimePlanText
        self.commitBranch = commitBranch
    }
}

public struct TahoeCodeRecent: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var provider: TahoeProvider
    public var live: Bool
    public var ago: String
    /// PR #35: the real `AgentSession.id` when this row represents an
    /// archived session that can be re-opened. Nil for demo fixture
    /// rows (the JSX-derived `TahoeBindings.codeDemo` placeholders)
    /// where there's no backing session. UI surfaces gate the
    /// unarchive action on this being non-nil.
    public var sessionId: UUID?
    /// v0.22.9: absolute filesystem path of the JSONL transcript when
    /// this row was sourced from disk (not a live `AgentSession`).
    /// Lets the UI fall back to "Reveal in Finder" (and, in a future
    /// release, render a read-only transcript preview) instead of
    /// disabling the row entirely.
    public var jsonlPath: String?

    public init(
        id: String,
        title: String,
        provider: TahoeProvider,
        live: Bool,
        ago: String,
        sessionId: UUID? = nil,
        jsonlPath: String? = nil
    ) {
        self.id = id; self.title = title; self.provider = provider
        self.live = live; self.ago = ago
        self.sessionId = sessionId
        self.jsonlPath = jsonlPath
    }
}

public struct TahoeCodeBindings: Sendable {
    public var repos: [TahoeCodeRepo]
    public var openSessionId: UUID?
    /// `true` when the bindings are the SwiftUI Preview / demo fixture.
    /// Views check this to decide whether to render the JSX placeholder
    /// thread / plan / PR data; in production (`isDemo == false`) the
    /// views render empty-state placeholders for any surface that isn't
    /// backed by real live data yet.
    public var isDemo: Bool

    public init(repos: [TahoeCodeRepo] = [], openSessionId: UUID? = nil, isDemo: Bool = false) {
        self.repos = repos
        self.openSessionId = openSessionId
        self.isDemo = isDemo
    }

    /// Empty production state — distinct from `.demo`. Use this when the
    /// real session list hasn't returned anything yet (poller hasn't fired,
    /// daemon not paired, user archived everything).
    public static let empty = TahoeCodeBindings(repos: [], openSessionId: nil, isDemo: false)

    /// Demo fixture — mirrors `TahoeDemo.repos`, with UUIDs minted per
    /// session so the open-id selection works the same as it did before.
    public static let demo: TahoeCodeBindings = {
        let demoSessionId = UUID()
        let sessionsByRepo: [String: [TahoeCodeSession]] = [
            "defx-frontend": [
                TahoeCodeSession(id: demoSessionId, title: "Refactor settlement store dedupe",
                                 agent: .claude, model: "Sonnet 4.5",
                                 status: .running, mode: "plan", subtitle: "plan \u{00B7} 2m ago"),
                TahoeCodeSession(id: UUID(), title: "Add USDT pair to order book",
                                 agent: .codex, model: "gpt-5",
                                 status: .paused, mode: "edit", subtitle: "paused \u{00B7} 18m"),
                TahoeCodeSession(id: UUID(), title: "Wire WS reconnect backoff",
                                 agent: .claude, model: "Opus 4",
                                 status: .done, mode: "edit", subtitle: "done \u{00B7} 1h"),
            ],
            "ccwatch": [
                TahoeCodeSession(id: UUID(), title: "Tahoe-style redesign pass",
                                 agent: .claude, model: "Sonnet 4.5",
                                 status: .planning, mode: "plan", subtitle: "planning \u{00B7} just now"),
            ],
            "internal-tools": [],
        ]
        let recentsByRepo: [String: [TahoeCodeRecent]] = [
            "defx-frontend": [
                TahoeCodeRecent(id: "r1", title: "fix(perp): margin tier rounding", provider: .claude, live: true,  ago: "now"),
                TahoeCodeRecent(id: "r2", title: "investigate flaky e2e suite",     provider: .codex,  live: false, ago: "12m"),
            ],
            "ccwatch": [],
            "internal-tools": [],
        ]
        let tints: [String: OKLCH] = [
            "defx-frontend":  OKLCH(l: 0.72, c: 0.16, h: 35),
            "ccwatch":        OKLCH(l: 0.72, c: 0.16, h: 220),
            "internal-tools": OKLCH(l: 0.72, c: 0.18, h: 310),
        ]
        let repos: [TahoeCodeRepo] = ["defx-frontend", "ccwatch", "internal-tools"].map { key in
            TahoeCodeRepo(
                key: key, name: key,
                tint: tints[key] ?? OKLCH(l: 0.72, c: 0.16, h: 220),
                liveSessionCount: key == "defx-frontend" ? 2 : 0,
                sessions: sessionsByRepo[key] ?? [],
                recents: recentsByRepo[key] ?? []
            )
        }
        return TahoeCodeBindings(repos: repos, openSessionId: demoSessionId, isDemo: true)
    }()
}

// MARK: - Plan parsing

/// Shared markdown-bullet parser for `AgentSession.planText`. Splits on
/// newlines, strips list prefixes (`- `, `* `, `• `, `1. `..`99. `), drops
/// empty lines, caps at `cap` entries. Used by `MacCodeView.PlanHalo`
/// and `MacCodeView.ReviewPlan`.
public enum TahoePlanParser {
    public static func steps(from raw: String, cap: Int) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = trimmed
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                var s = String(line).trimmingCharacters(in: .whitespaces)
                // Bullet markers
                for prefix in ["- ", "* ", "\u{2022} "] {
                    if s.hasPrefix(prefix) {
                        s = String(s.dropFirst(prefix.count))
                        return s.isEmpty ? nil : s
                    }
                }
                // Numbered list: any 1-3 digit prefix followed by `. ` or `) `.
                // Strips `1. `, `10. `, `99) ` — was previously cap'd at 9. with
                // a hardcoded list, dropping double-digit prefixes verbatim.
                if let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }),
                   dot != s.startIndex {
                    let head = s[s.startIndex..<dot]
                    if head.count <= 3, head.allSatisfy({ $0.isNumber }) {
                        let after = s.index(after: dot)
                        if after < s.endIndex, s[after] == " " {
                            s = String(s[s.index(after: after)..<s.endIndex])
                            return s.isEmpty ? nil : s
                        }
                    }
                }
                return s.isEmpty ? nil : s
            }
        return Array(parsed.prefix(cap))
    }
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
