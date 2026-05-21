import SwiftUI
import ClawdmeterShared

/// iOS Session Detail — pushed from the Code list. Nav bar chip + thread +
/// PlanHaloMini + composer. Ports `ios-other.jsx::IOSSessionDetail`.
///
/// Codex review P1 fix: previously rendered hardcoded demo content for every
/// session. Now accepts the session id selected in `IOSCodeView`, looks it
/// up in the bindings, and renders the real title / provider / status /
/// plan text. Thread + plan halo fall back to the JSX placeholder ONLY
/// when `data.isDemo == true`; production sessions show empty / loading
/// state until streaming wire lands.
public struct IOSSessionDetailView: View {
    @Environment(\.tahoe) private var t
    var sessionId: UUID
    var data: TahoeCodeBindings
    var onBack: () -> Void

    public init(sessionId: UUID, data: TahoeCodeBindings, onBack: @escaping () -> Void) {
        self.sessionId = sessionId
        self.data = data
        self.onBack = onBack
    }

    /// Find the session this screen represents. Returns nil if it was
    /// archived/removed while the detail was open — in which case we render
    /// a graceful empty state and let the user back out.
    private var session: TahoeCodeSession? {
        for repo in data.repos {
            if let s = repo.sessions.first(where: { $0.id == sessionId }) { return s }
        }
        return nil
    }

    /// Parsed plan steps from the real session, when present. Used by the
    /// PlanHalo mini card. Demo bindings fall back to the JSX fixture plan.
    private var planSteps: [String] {
        if let raw = session?.runtimePlanText, !raw.isEmpty {
            let parsed = TahoePlanParser.steps(from: raw, cap: 8)
            if !parsed.isEmpty { return parsed }
        }
        return data.isDemo ? TahoeDemo.plan : []
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Custom nav bar — title chip shows real session metadata.
            HStack(spacing: 10) {
                Button(action: onBack) {
                    TahoeIcon("chevL", size: 16).foregroundStyle(t.fg)
                        .frame(width: 40, height: 38)
                        .background { Capsule().fill(t.glassTintHi) }
                        .overlay { Capsule().stroke(t.hairline, lineWidth: 0.5) }
                }
                .buttonStyle(.plain)

                TahoeGlass(radius: 14, tone: .chip) {
                    HStack(spacing: 9) {
                        TahoeProviderGlyph(provider: session?.agent ?? .claude, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session?.title ?? "Session unavailable")
                                .font(TahoeFont.body(12.5, weight: .bold))
                                .foregroundStyle(t.fg)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Circle().fill(statusColor(session?.status ?? .done))
                                    .frame(width: 7, height: 7)
                                    .shadow(color: (session?.status == .running) ? statusColor(.running) : .clear, radius: 3, x: 0, y: 0)
                                Text(session?.subtitle ?? "—")
                                    .font(TahoeFont.body(10.5))
                                    .foregroundStyle(t.fg3)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)

                IOSRoundIconBtn("sliders")
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)

            // Thread
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if data.isDemo {
                        // Preview / demo bindings only — JSX placeholder
                        // thread keeps Xcode Previews looking alive.
                        ForEach(Array(TahoeDemo.thread.enumerated()), id: \.offset) { _, msg in
                            IOSThreadMsg(msg: msg, providerOverride: session?.agent)
                        }
                        IOSPlanHaloMini(steps: planSteps)
                    } else if session == nil {
                        emptyState(
                            title: "Session unavailable",
                            body: "This session may have been archived on your Mac. Go back to see what's still running."
                        )
                    } else {
                        // Production: the live message stream isn't piped
                        // through to iOS yet. Show a placeholder until the
                        // bridge lands, and render the plan halo only when
                        // a real plan text is present.
                        emptyState(
                            title: "Live transcript coming soon",
                            body: "Open this session on your Mac to see the full thread. Plan steps will appear here as the agent prepares them."
                        )
                        if !planSteps.isEmpty {
                            IOSPlanHaloMini(steps: planSteps)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            // Composer — disabled in production until send wire lands; in
            // demo bindings the placeholder text reads "Refine the plan…".
            TahoeGlass(radius: 22, tone: .raised) {
                HStack(spacing: 8) {
                    TahoeIcon("plus", size: 18).foregroundStyle(t.fg3)
                    Text(data.isDemo ? "Refine the plan…" : "Composer not yet wired")
                        .font(TahoeFont.body(14))
                        .foregroundStyle(t.fg3)
                    Spacer()
                    TahoeIcon("mic", size: 16).foregroundStyle(t.fg3)
                    Button(action: {}) {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                         startPoint: .top, endPoint: .bottom))
                            TahoeIcon("arrowU", size: 16, weight: .bold).foregroundStyle(.white)
                        }
                        .frame(width: 38, height: 38)
                        .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
                        .opacity(data.isDemo ? 1.0 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .disabled(!data.isDemo)
                }
                .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 10)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 14)
        }
    }

    private func statusColor(_ s: TahoeCodeSession.Status) -> Color {
        switch s {
        case .running:  return Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0)
        case .planning: return t.fg3
        case .paused:   return Color(.sRGB, red: 0xFE/255.0, green: 0xBC/255.0, blue: 0x2E/255.0)
        case .done:     return t.accent
        case .degraded: return Color(.sRGB, red: 1, green: 0x5F/255.0, blue: 0x57/255.0)
        }
    }

    @ViewBuilder
    private func emptyState(title: String, body: String) -> some View {
        VStack(spacing: 8) {
            TahoeIcon("chat", size: 22).foregroundStyle(t.fg4)
            Text(title)
                .font(TahoeFont.body(14, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text(body)
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct IOSThreadMsg: View {
    @Environment(\.tahoe) private var t
    var msg: TahoeDemo.DemoThreadMsg
    /// Real session's provider, when available. Lets the demo placeholder
    /// pick up the actual agent's glyph instead of always rendering Claude.
    var providerOverride: TahoeProvider?

    var body: some View {
        switch msg {
        case .user(let text):
            HStack {
                Spacer()
                TahoeGlass(radius: 20, tone: .raised) {
                    Text(text)
                        .font(TahoeFont.body(13))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity * 0.82, alignment: .trailing)
            }
        case .tool(let tool, let target, _):
            HStack(spacing: 8) {
                TahoeIcon(tool == "grep" ? "search" : "doc", size: 11).foregroundStyle(t.fg3)
                Text(tool).font(TahoeFont.body(11.5, weight: .semibold)).foregroundStyle(t.fg2)
                Text(target).font(TahoeFont.mono(11)).foregroundStyle(t.fg3).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        case .assistant(let text):
            HStack(alignment: .top, spacing: 9) {
                TahoeProviderGlyph(provider: providerOverride ?? .claude, size: 24)
                Text(text)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }
}

private struct IOSPlanHaloMini: View {
    @Environment(\.tahoe) private var t
    /// Plan steps to render. Pre-parsed by the parent — empty means hide.
    var steps: [String]

    var body: some View {
        if steps.isEmpty {
            EmptyView()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(RadialGradient(
                        colors: [t.accentGlow.color(opacity: 0.30), .clear],
                        center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 400))
                    .blur(radius: 6).padding(-20).allowsHitTesting(false)

                TahoeGlass(radius: 20, tone: .raised) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(width: 26, height: 26)
                                .overlay { TahoeIcon("sparkles", size: 13).foregroundStyle(.white) }
                                .shadow(color: t.accentDeep.color(opacity: 0.35), radius: 6, x: 0, y: 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("PLAN READY")
                                    .font(TahoeFont.body(11, weight: .bold))
                                    .tracking(0.4)
                                    .foregroundStyle(t.fg3)
                                Text("\(steps.count) step\(steps.count == 1 ? "" : "s")")
                                    .font(TahoeFont.body(13, weight: .bold))
                                    .foregroundStyle(t.fg)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(steps.prefix(3).enumerated()), id: \.offset) { i, step in
                                HStack(alignment: .top, spacing: 9) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(t.hair2)
                                        Text("\(i+1)").font(TahoeFont.mono(10, weight: .bold)).foregroundStyle(t.fg2)
                                    }
                                    .frame(width: 18, height: 18)
                                    Text(step)
                                        .font(TahoeFont.body(12.5))
                                        .foregroundStyle(t.fg)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if steps.count > 3 {
                                Text("+ \(steps.count - 3) more step\(steps.count - 3 == 1 ? "" : "s")…")
                                    .font(TahoeFont.body(11.5))
                                    .foregroundStyle(t.fg3)
                                    .padding(.leading, 27)
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)

                        TahoeHair()

                        HStack(spacing: 8) {
                            TahoeGhostButton(size: .l) { Text("Refine") }
                                .frame(maxWidth: .infinity)
                            TahoeAccentButton(size: .l) { Text("Approve & run") }
                                .frame(maxWidth: .infinity * 2)
                        }
                        .padding(10)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}
