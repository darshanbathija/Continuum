import Foundation
import SwiftUI
import ClawdmeterShared

/// Adapters from the iOS UsageModel data layer to portable
/// `TahoeLiveBindings`. Mirror of `MacTahoeAdapter` on Mac.
@MainActor
extension AgentControlClient {
    /// Lower the daemon's mirrored session list into `TahoeCodeBindings`
    /// for `IOSCodeView`. Sessions are grouped by repo key with a stable
    /// hash-derived tint so the same project always shows the same color.
    /// Returns empty production bindings when the daemon hasn't returned
    /// anything yet (unpaired or just-started) so the view renders the
    /// "Sessions started on your Mac will appear here once you're paired"
    /// empty state rather than the JSX fixture.
    var tahoeCode: TahoeCodeBindings {
        let live = sessions.filter { $0.archivedAt == nil }
        // PR #35: archived sessions feed the RecentRow's re-open path
        // on iOS Code. Bucketed by repo so each card surfaces its
        // own history. Tappable because the daemon's
        // `POST /sessions/:id/unarchive` is the same RPC the Mac uses.
        let archived = sessions.filter { $0.archivedAt != nil }
        guard !live.isEmpty || !archived.isEmpty else { return .empty }
        let now = Date()

        // Group sessions by repo key. Chat sessions (repoKey == nil) bucket
        // under a namespaced synthetic key — `clawd:chat` rather than a
        // bare token, so it can't collide with any plausible file system
        // path that real repos could legitimately produce.
        let chatBucketKey = "clawd:chat-sessions"
        let grouped: [String: [AgentSession]] = Dictionary(grouping: live, by: { $0.repoKey ?? chatBucketKey })
        let archivedByRepo: [String: [AgentSession]] = Dictionary(grouping: archived, by: { $0.repoKey ?? chatBucketKey })
        let displayName: (String, [AgentSession]) -> String = { key, sessions in
            if key == chatBucketKey { return "Chat sessions" }
            return sessions.first?.repoDisplayName ?? URL(fileURLWithPath: key).lastPathComponent
        }

        // Stable ordering: emit a repo entry whenever we have live OR
        // archived sessions for that key. archivedByRepo can introduce
        // keys grouped doesn't know about, so union the key sets.
        let allKeys = Set(grouped.keys).union(archivedByRepo.keys)
        let mappedRepos: [TahoeCodeRepo] = allKeys
            .map { key -> TahoeCodeRepo in
                let liveSessions = grouped[key] ?? []
                let archivedSessions = archivedByRepo[key] ?? []
                let mapped = liveSessions
                    .sorted { $0.lastEventAt > $1.lastEventAt }
                    .map { tahoeSession($0, now: now) }
                let liveCount = mapped.filter { $0.status == .running || $0.status == .planning }.count
                let recents: [TahoeCodeRecent] = archivedSessions
                    .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
                    .prefix(4)
                    .map { session in
                        TahoeCodeRecent(
                            id: session.id.uuidString,
                            title: session.displayLabel,
                            provider: mapTahoeProvider(for: session.agent),
                            live: false,
                            ago: TahoeFmt.ago(from: session.archivedAt ?? session.lastEventAt, reference: now),
                            sessionId: session.id
                        )
                    }
                let nameSeed = liveSessions.isEmpty ? archivedSessions : liveSessions
                return TahoeCodeRepo(
                    key: key,
                    name: displayName(key, nameSeed),
                    tint: repoTint(forKey: key),
                    liveSessionCount: liveCount,
                    sessions: mapped,
                    recents: recents
                )
            }
            .sorted { $0.name < $1.name }

        let firstOpen = mappedRepos.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
        return TahoeCodeBindings(repos: mappedRepos, openSessionId: firstOpen)
    }

    /// PR #35: same logic as `mapAgent` below but exposed under a
    /// distinct name so the call sites that need a `TahoeProvider`
    /// (not a TahoeCodeSession field) read clearly.
    private func mapTahoeProvider(for agent: AgentKind) -> TahoeProvider {
        switch agent {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode
        case .cursor: return .cursor
        case .unknown: return .claude
        }
    }

    private func tahoeSession(_ s: AgentSession, now: Date) -> TahoeCodeSession {
        let title = s.customName ?? s.goal ?? s.repoDisplayName
        let mode: String = (s.status == .planning) ? "plan" : (s.mode == .worktree ? "worktree" : "local")
        let agoText = TahoeFmt.ago(from: s.lastEventAt, reference: now)
        let subtitle: String = {
            switch s.status {
            case .planning: return "planning \u{00B7} \(agoText)"
            case .running:  return "running \u{00B7} \(agoText)"
            case .paused:   return "paused \u{00B7} \(agoText)"
            case .done:     return "done \u{00B7} \(agoText)"
            case .degraded: return "degraded \u{00B7} \(agoText)"
            }
        }()
        let mapped: TahoeProvider = {
            switch s.agent {
            case .claude: return .claude
            case .codex:  return .codex
            case .gemini: return .gemini
            case .opencode: return .opencode  // PR #31: 4th lane in TahoeProvider
            case .cursor: return .cursor
            case .unknown:
                // X3: visual fallback for raws this client doesn't
                // recognize. Degrades to Claude styling.
                return .claude
            }
        }()
        let status: TahoeCodeSession.Status = {
            switch s.status {
            case .planning: return .planning
            case .running:  return .running
            case .paused:   return .paused
            case .done:     return .done
            case .degraded: return .degraded
            }
        }()
        let branch: String? = {
            guard let p = s.worktreePath else { return nil }
            let slug = URL(fileURLWithPath: p).lastPathComponent
            return slug.isEmpty ? nil : slug
        }()
        return TahoeCodeSession(
            id: s.id,
            title: title.isEmpty ? "Untitled session" : title,
            agent: mapped,
            model: s.model ?? mapped.displayName,
            status: status,
            mode: mode,
            subtitle: subtitle,
            runtimePlanText: s.planText,
            commitBranch: branch
        )
    }

    private func repoTint(forKey key: String) -> OKLCH {
        var h: UInt32 = 5381
        for b in key.utf8 { h = (h &* 33) &+ UInt32(b) }
        return OKLCH(l: 0.72, c: 0.16, h: Double(h % 360))
    }
}

@MainActor
extension UsageModel {
    var tahoeLive: TahoeLiveBindings {
        TahoeLiveBindings(
            claude: row(usage: usage,                 provider: .claude, hasWeekly: true,  modelFallback: "Sonnet 4.5"),
            codex:  row(usage: codexSnapshot?.usage,  provider: .codex,  hasWeekly: true,  modelFallback: "gpt-5"),
            gemini: row(usage: geminiSnapshot?.usage, provider: .gemini, hasWeekly: false, modelFallback: "antigravity-pro"),
            cursor: TahoeLiveRow(
                sessionPercent: 0,
                weeklyPercent: 0,
                sessionResetIn: "-",
                weeklyResetIn: "",
                modelName: "Cursor Auto",
                autoReviveOn: false,
                supportsAutoRevive: false,
                hasWeekly: false,
                stale: true
            )
        )
    }

    private func row(usage: UsageData?, provider: TahoeProvider, hasWeekly: Bool, modelFallback: String) -> TahoeLiveRow {
        guard let usage else {
            return TahoeLiveRow(
                sessionPercent: 0,
                weeklyPercent: hasWeekly ? 0 : -1,
                sessionResetIn: "\u{2014}",
                weeklyResetIn: hasWeekly ? "\u{2014}" : "",
                modelName: modelFallback,
                autoReviveOn: false,
                autoReviveAgo: "",
                supportsAutoRevive: false,
                hasWeekly: hasWeekly
            )
        }
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
            supportsAutoRevive: false,
            hasWeekly: hasWeekly
        )
    }
}
