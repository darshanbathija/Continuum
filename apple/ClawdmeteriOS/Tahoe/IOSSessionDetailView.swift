import SwiftUI
import ClawdmeterShared

/// iOS Session Detail — pushed from the Code list. Nav bar chip + thread +
/// PlanHaloMini + composer. Ports `ios-other.jsx::IOSSessionDetail`.
///
/// v0.12 button-wiring pass: the plan halo Refine / Approve & run buttons
/// and the composer Send button now reach the real daemon via
/// `AgentControlClient.approvePlan` / `sendPrompt`. Composer is a real
/// `TextField` (was a placeholder `Text` label), and pull-to-refresh
/// wires `agentClient.refreshAll()`.
public struct IOSSessionDetailView: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var agentClient: AgentControlClient
    var sessionId: UUID
    var data: TahoeCodeBindings
    var onBack: () -> Void

    @State private var composerText: String = ""
    @State private var sending: Bool = false
    @State private var refineAlertShown: Bool = false
    @State private var refineText: String = ""
    @State private var lastError: String?
    @State private var configSheetPresented: Bool = false
    @StateObject private var chatStore: iOSChatStore

    public init(
        agentClient: AgentControlClient,
        sessionId: UUID,
        data: TahoeCodeBindings,
        onBack: @escaping () -> Void
    ) {
        self.agentClient = agentClient
        self.sessionId = sessionId
        self.data = data
        self.onBack = onBack
        _chatStore = StateObject(wrappedValue: iOSChatStore(sessionId: sessionId, client: agentClient))
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

    /// True when this session has a real plan that can be approved.
    /// Disables Approve & run otherwise so users don't fire a no-op.
    private var hasRealPlan: Bool {
        guard let raw = session?.runtimePlanText else { return false }
        return !raw.isEmpty && session?.status == .planning
    }

    private var realAgentSession: AgentSession? {
        agentClient.sessions.first { $0.id == sessionId }
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

                if session != nil && !data.isDemo {
                    IOSRoundIconBtn("sliders", action: openConfigSheet)
                } else if data.isDemo {
                    IOSRoundIconBtn("sliders")
                }
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
                        IOSPlanHaloMini(
                            steps: planSteps,
                            canApprove: true,
                            onRefine: { refineAlertShown = true },
                            onApprove: { Task { await approvePlan() } }
                        )
                    } else if session == nil {
                        emptyState(
                            title: "Session unavailable",
                            body: "This session may have been archived on your Mac. Go back to see what's still running."
                        )
                    } else if chatStore.snapshot.items.isEmpty {
                        emptyState(
                            title: "No transcript yet",
                            body: "Messages appear here after the Mac publishes this session's chat snapshot."
                        )
                        if !planSteps.isEmpty {
                            IOSPlanHaloMini(
                                steps: planSteps,
                                canApprove: hasRealPlan,
                                onRefine: { refineAlertShown = true },
                                onApprove: { Task { await approvePlan() } }
                            )
                        }
                    } else {
                        ForEach(chatStore.snapshot.items) { item in
                            IOSWireChatItemRow(item: item, provider: session?.agent ?? .claude)
                        }
                        if !planSteps.isEmpty {
                            IOSPlanHaloMini(
                                steps: planSteps,
                                canApprove: hasRealPlan,
                                onRefine: { refineAlertShown = true },
                                onApprove: { Task { await approvePlan() } }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            .refreshable {
                await agentClient.refreshAll()
            }

            // Composer — real TextField when a session is open. Tapping send
            // invokes `agentClient.sendPrompt(sessionId:text:)`. In demo
            // bindings the placeholder text reads "Refine the plan…" but
            // the send call is short-circuited (no real session).
            TahoeGlass(radius: 22, tone: .raised) {
                HStack(spacing: 8) {
                    TextField(composerPlaceholder, text: $composerText, axis: .vertical)
                        .font(TahoeFont.body(14))
                        .foregroundStyle(t.fg)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.send)
                        .disabled(session == nil && !data.isDemo)
                    Spacer(minLength: 4)
                    Button(action: { Task { await sendComposer() } }) {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                         startPoint: .top, endPoint: .bottom))
                            if sending {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            } else {
                                TahoeIcon("arrowU", size: 16, weight: .bold).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
                        .opacity(canSend ? 1.0 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend || sending)
                }
                .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 10)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 14)
        }
        .alert("Refine the plan", isPresented: $refineAlertShown) {
            TextField("What should change?", text: $refineText)
                .textInputAutocapitalization(.sentences)
            Button("Send", action: { Task { await sendRefine() } })
                .disabled(refineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel, action: { refineText = "" })
        } message: {
            Text("Your message is sent to the agent as a plan-mode follow-up. The agent revises the plan and you re-approve.")
        }
        .alert("Couldn't send",
               isPresented: Binding(
                get: { lastError != nil },
                set: { if !$0 { lastError = nil } }
               ),
               actions: { Button("OK", role: .cancel) { lastError = nil } },
               message: { Text(lastError ?? "") })
        .sheet(isPresented: $configSheetPresented) {
            NavigationStack {
                if let realAgentSession {
                    iOSSessionControlsStrip(session: realAgentSession, client: agentClient)
                        .navigationTitle("Session controls")
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.triangle")
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: sessionId) {
            await chatStore.refresh()
            chatStore.start()
        }
        .onDisappear {
            chatStore.stop()
        }
    }

    // MARK: - Computed UX state

    private var composerPlaceholder: String {
        if data.isDemo { return "Refine the plan…" }
        if session == nil { return "Session unavailable" }
        return "Send a follow-up…"
    }

    private var canSend: Bool {
        guard session != nil else { return false }
        return !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    @MainActor
    private func sendComposer() async {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session != nil else { return }
        // Demo bindings short-circuit — clear the text but don't hit the
        // wire (the demo session id wouldn't resolve on the daemon side).
        if data.isDemo {
            composerText = ""
            return
        }
        sending = true
        defer { sending = false }
        // Audit P2 fix: previously the composer text was cleared
        // unconditionally on every send. If the Mac was offline / the
        // token expired / the daemon rejected the request, the user's
        // typed-out prompt was just gone. Clear only on success; on
        // failure keep the text so the user can retry.
        let ok = await agentClient.sendPrompt(sessionId: sessionId, text: trimmed, asFollowUp: true)
        if ok { composerText = "" }
    }

    @MainActor
    private func sendRefine() async {
        let trimmed = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session != nil, !data.isDemo else { return }
        sending = true
        defer { sending = false }
        let ok = await agentClient.sendPrompt(sessionId: sessionId, text: trimmed, asFollowUp: true)
        if ok { refineText = "" }
    }

    @MainActor
    private func approvePlan() async {
        guard session != nil else { return }
        guard !data.isDemo else { return }  // demo plan, no real id to approve
        sending = true
        defer { sending = false }
        await agentClient.approvePlan(sessionId: sessionId)
    }

    private func openConfigSheet() {
        configSheetPresented = true
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

private struct IOSWireChatItemRow: View {
    @Environment(\.tahoe) private var t
    var item: ChatItem
    var provider: TahoeProvider

    var body: some View {
        switch item {
        case .message(let message):
            messageRow(message)
        case .toolRun(_, let pairs):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pairs) { pair in
                    HStack(spacing: 8) {
                        TahoeIcon("doc", size: 11).foregroundStyle(t.fg3)
                        Text(pair.call.title)
                            .font(TahoeFont.body(11.5, weight: .semibold))
                            .foregroundStyle(t.fg2)
                        Text(pair.call.body)
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(pair.call.isError ? .red : t.fg3)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 4).padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        switch message.kind {
        case .userText:
            HStack {
                Spacer()
                TahoeGlass(radius: 20, tone: .raised) {
                    Text(message.body)
                        .font(TahoeFont.body(13))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 320, alignment: .trailing)
            }
        case .assistantText:
            HStack(alignment: .top, spacing: 9) {
                TahoeProviderGlyph(provider: provider, size: 24)
                Text(message.body)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        case .toolCall, .toolResult:
            HStack(spacing: 8) {
                TahoeIcon(message.kind == .toolCall ? "doc" : "check", size: 11).foregroundStyle(t.fg3)
                Text(message.title)
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text(message.body)
                    .font(TahoeFont.mono(11))
                    .foregroundStyle(message.isError ? .red : t.fg3)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        case .meta:
            Text(message.body)
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
    /// Whether Approve & run is enabled. False when the session is not
    /// actually in plan-mode (the daemon would reject a no-op approval).
    var canApprove: Bool
    var onRefine: () -> Void
    var onApprove: () -> Void

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
                            TahoeGhostButton(size: .l, action: onRefine) { Text("Refine") }
                                .frame(maxWidth: .infinity)
                            TahoeAccentButton(size: .l, action: onApprove) { Text("Approve & run") }
                                .frame(maxWidth: .infinity * 2)
                                .opacity(canApprove ? 1.0 : 0.5)
                                .disabled(!canApprove)
                        }
                        .padding(10)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}
