import SwiftUI
import ClawdmeterShared

/// Mid-session controls strip — sticky chip row above the chat thread.
/// Lets the user swap model / effort / mode / plan-code from inside a
/// running session, plus interrupt + autopilot toggle.
///
/// Sessions v2 Phase 3.
struct iOSSessionControlsStrip: View {
    let session: AgentSession
    @ObservedObject var client: AgentControlClient

    @State private var showingModelPicker: Bool = false
    @State private var showingEffortSheet: Bool = false
    @State private var pendingSwapBanner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusDot
                Text(session.status.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("Session status \(session.status.rawValue)")
                if let modelEntry = currentModelEntry {
                    chip(modelEntry.displayName, accessibilityLabel: "Model: \(modelEntry.displayName). Double-tap to change.") {
                        showingModelPicker = true
                    }
                    .disabled(cursorSwapUnavailable)
                }
                if let effort = session.effort {
                    chip(effortLabel(effort), accessibilityLabel: "Effort: \(longEffortLabel(effort)). Double-tap to change.") {
                        showingEffortSheet = true
                    }
                    .disabled(cursorSwapUnavailable)
                }
                chip(
                    session.mode == .worktree ? "Worktree" : "Local",
                    accessibilityLabel: "Mode: \(session.mode == .worktree ? "worktree" : "local"). Double-tap to change."
                ) { Task { await toggleExecutionMode() } }
                    .disabled(cursorSwapUnavailable)
                Spacer()
            }

            // Plan/Code toggle + Interrupt for both agents. Claude
            // toggles between `--permission-mode plan` and
            // `--permission-mode acceptEdits`; Codex toggles between
            // `--sandbox read-only` and `--sandbox workspace-write`.
            HStack(spacing: 8) {
                Button(action: { Task { await togglePlanMode() } }) {
                    Label(session.status == .planning ? "Plan" : "Code",
                          systemImage: session.status == .planning ? "doc.text.below.ecg" : "play.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(SessionsV2Theme.accent)
                .frame(minHeight: 44)
                .accessibilityLabel(session.status == .planning ? "Plan mode on" : "Plan mode off")
                .accessibilityHint("Double-tap to switch between plan and code mode.")
                .disabled(cursorSwapUnavailable)

                Button(role: .destructive, action: { Task { await client.interruptSession(sessionId: session.id) } }) {
                    Label("Interrupt", systemImage: "stop.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 44)
                .accessibilityLabel("Interrupt session")
                .accessibilityHint("Sends an escape key to stop the agent.")

                // Revive a degraded session by restarting its direct runtime.
                // Gated on the paired Mac's wire version (older Macs 404 the route).
                if session.status == .degraded && client.supportsRevive {
                    Button(action: { Task { await client.revive(sessionId: session.id) } }) {
                        Label("Revive", systemImage: "arrow.clockwise.circle")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Revive degraded session")
                    .accessibilityHint("Restarts the session runtime and reconnects.")
                }
                Spacer()
            }

            if let banner = pendingSwapBanner {
                Text(banner)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SessionsV2Theme.surfaceElev0)
        .sheet(isPresented: $showingModelPicker) {
            NavigationStack {
                iOSModelPickerList(
                    catalog: client.modelCatalog,
                    agent: session.agent,
                    customProviderId: session.customProviderId,
                    selectedModelId: .init(
                        get: { session.model },
                        set: { newId in
                            if let newId,
                               let entry = client.modelCatalog.entry(
                                forId: newId,
                                customProviderId: session.customProviderId
                               ) {
                                Task { await changeModel(to: entry) }
                            }
                        }
                    )
                )
            }
        }
        .sheet(isPresented: $showingEffortSheet) {
            NavigationStack {
                List {
                    Section("Reasoning effort") {
                        ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                            Button {
                                Task { await changeEffort(to: effort) }
                                showingEffortSheet = false
                            } label: {
                                HStack {
                                    Text(effortLabel(effort))
                                    Spacer()
                                    if session.effort == effort {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(SessionsV2Theme.accent)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Effort")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Status indicator

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch session.status {
        case .planning: return .gray
        case .running:  return .green
        case .paused:   return SessionsV2Theme.warn
        case .done:     return SessionsV2Theme.accent
        case .degraded: return .secondary
        }
    }

    // MARK: - Chip

    @ViewBuilder
    private func chip(_ label: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .frame(minWidth: 62, minHeight: 38)
                .background(SessionsV2Theme.surfaceElev1, in: RoundedRectangle(cornerRadius: SessionsV2Theme.Radius.chip))
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Helpers

    private var currentModelEntry: ModelCatalogEntry? {
        guard let id = session.model else { return nil }
        return client.modelCatalog.entry(forId: id, customProviderId: session.customProviderId)
    }

    private var cursorSwapUnavailable: Bool {
        session.agent == .cursor && !hasCursorResumeId
    }

    private var hasCursorResumeId: Bool {
        let candidate = session.runtimeBinding?.externalSessionId
            ?? session.runtimeBinding?.externalThreadId
        return candidate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func effortLabel(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .minimal: return "Min"
        case .low:     return "Low"
        case .medium:  return "Med"
        case .high:    return "High"
        case .xhigh:   return "xHigh"
        case .max:     return "Max"
        }
    }

    /// Long form for VoiceOver readouts so "xHigh" doesn't get
    /// mispronounced.
    private func longEffortLabel(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .minimal: return "minimal"
        case .low:     return "low"
        case .medium:  return "medium"
        case .high:    return "high"
        case .xhigh:   return "extra high"
        case .max:     return "max"
        }
    }

    // MARK: - Actions

    @MainActor
    private func changeModel(to entry: ModelCatalogEntry) async {
        guard !cursorSwapUnavailable else { return }
        let modelArg = entry.cliAlias ?? entry.id
        pendingSwapBanner = "Switching to \(entry.displayName)…"
        _ = await client.changeModel(
            sessionId: session.id,
            request: ChangeModelRequest(model: modelArg, effort: session.effort)
        )
        pendingSwapBanner = nil
    }

    @MainActor
    private func changeEffort(to effort: ReasoningEffort) async {
        guard !cursorSwapUnavailable else { return }
        pendingSwapBanner = "Switching effort to \(effortLabel(effort))…"
        _ = await client.changeEffort(sessionId: session.id, effort: effort)
        pendingSwapBanner = nil
    }

    @MainActor
    private func togglePlanMode() async {
        guard !cursorSwapUnavailable else { return }
        let newPlan = !(session.status == .planning)
        _ = await client.changeMode(sessionId: session.id, mode: session.mode, planMode: newPlan)
    }

    @MainActor
    private func toggleExecutionMode() async {
        guard !cursorSwapUnavailable else { return }
        let newMode: SessionMode = session.mode == .worktree ? .local : .worktree
        pendingSwapBanner = "Switching to \(newMode == .worktree ? "worktree" : "local")…"
        _ = await client.changeMode(sessionId: session.id, mode: newMode)
        pendingSwapBanner = nil
    }
}
