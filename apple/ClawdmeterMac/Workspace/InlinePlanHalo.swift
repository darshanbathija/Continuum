import SwiftUI
import ClawdmeterShared

/// Glowing card that surfaces a session's pending plan inline in the
/// transcript, with Refine + Approve actions. Used by the chat thread
/// when the agent has surfaced a plan and the user hasn't yet approved.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. Owns its
/// own `@State auraGlow` for the breathing-glow animation; reads the
/// `session.planText` value prop only — never the parent workspace's
/// @State. Independent body-invalidation scope.
struct InlinePlanHalo: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    let onRefine: () -> Void
    let onApprove: () -> Void
    let canApprove: Bool

    private var steps: [String] {
        guard let plan = session.planText else { return [] }
        return TahoePlanParser.steps(from: plan, cap: 8)
    }

    var body: some View {
        // A6 (foundation): body-invalidation tap. No-op in production.
        BodyInvalidationCounter.bump("InlinePlanHalo")
        // Per DESIGN.md: the plan halo aura is STATIC. No repeating-pulse
        // breathing animation — the halo conveys state once, not ambiently.
        return ZStack {
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [t.accentGlow.color(opacity: t.muted ? 0.10 : 0.30), .clear],
                        center: .init(x: 0.5, y: 0.30),
                        startRadius: 0,
                        endRadius: 520
                    )
                )
                .blur(radius: 8)
                .padding(-28)
                .allowsHitTesting(false)

            TahoeGlass(radius: 20, tone: .raised) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom)
                            )
                            .frame(width: 28, height: 28)
                            .overlay(TahoeIcon("sparkles", size: 14).foregroundStyle(.white))
                            .shadow(color: t.accentDeep.color(opacity: 0.35), radius: 6, x: 0, y: 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Plan ready · review before run")
                                .font(TahoeFont.body(11.5, weight: .semibold))
                                .tracking(0.4)
                                .textCase(.uppercase)
                                .foregroundStyle(t.fg3)
                            Text("\(steps.count) steps · est. \(estimatedToolCalls) tool calls · \(estimatedCost)")
                                .font(TahoeFont.body(14, weight: .bold))
                                .foregroundStyle(t.fg)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                // DESIGN.md Plan Card: step badges use hair2/fg2,
                                // EXCEPT step 1 which uses accent@18% fill + accent
                                // text to mark the entry point.
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(index == 0 ? t.accentAlpha(0.18) : t.hair2)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Text("\(index + 1)")
                                            .font(TahoeFont.mono(11, weight: .bold))
                                            .foregroundStyle(index == 0 ? t.accent : t.fg2)
                                    )
                                Text(step)
                                    .font(TahoeFont.body(13))
                                    .foregroundStyle(t.fg)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 14)

                    TahoeHairline()

                    HStack(spacing: 8) {
                        TahoeGhostButton(size: .m, action: onRefine) {
                            TahoeIcon("chat", size: 11)
                            Text("Refine")
                        }
                        TahoeGhostButton(size: .m, action: onRefine) {
                            Text("Edit plan")
                        }
                        Spacer(minLength: 10)
                        if let branch = session.worktreePath.map({ URL(fileURLWithPath: $0).lastPathComponent }), !branch.isEmpty {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("Will commit to")
                                    .font(TahoeFont.body(10.5, weight: .semibold))
                                    .foregroundStyle(t.fg4)
                                HStack(spacing: 5) {
                                    TahoeIcon("branch", size: 10)
                                    Text(branch)
                                        .font(TahoeFont.mono(11))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .foregroundStyle(t.fg3)
                            }
                            .frame(maxWidth: 190)
                        }
                        TahoeAccentButton(size: .m, disabled: !canApprove, action: onApprove) {
                            Text("Approve & run")
                            Text("⇧⏎")
                                .fontWeight(.regular)
                                .opacity(0.75)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var estimatedToolCalls: Int {
        max(3, min(12, steps.count + 3))
    }

    private var estimatedCost: String {
        if session.agent == .codex { return "~$0.12" }
        if session.agent == .gemini { return "~$0.08" }
        return "~$0.18"
    }
}
