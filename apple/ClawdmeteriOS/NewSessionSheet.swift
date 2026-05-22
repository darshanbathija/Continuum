import SwiftUI
import ClawdmeterShared

/// Sessions v2 Phase 2 — full new-session sheet matching the design spec:
/// Repo → Goal → Agent → Model picker → Effort dial → Mode chip → Plan
/// toggle → Start (sticky bottom). Sends a complete `NewSessionRequest`
/// with effort + optional A/B pair config.
///
/// Made internal (was private) so the Tahoe Code surface (`IOSCodeView`)
/// can present it from its `+` buttons. Pairing flows present this via
/// `PairingCTAButtons.swift`.
struct NewSessionSheet: View {
    @ObservedObject var client: AgentControlClient
    @Binding var isPresented: Bool

    @State private var repoKey: String = ""
    @State private var baseBranch: String = "main"
    @State private var goal: String = ""
    @State private var agent: AgentKind = .claude
    @State private var modelId: String?
    @State private var effort: ReasoningEffort = .medium
    @State private var mode: SessionMode = .worktree
    @State private var planMode: Bool = true
    @State private var runAsABPair: Bool = false
    @State private var isStarting: Bool = false
    @State private var openOnMacUnsupportedAlert: String?
    /// v0.7.4 handoff UX: when the Mac executed a Codex SDK resume on
    /// the draft's codexThreadId, surface the agent's response inline
    /// via a sheet instead of silently dismissing. Identifiable struct
    /// so `.sheet(item:)` knows when to present.
    @State private var codexResumeResult: CodexResumeResult?
    /// Phase 8: pre-flight cost + weekly-cap estimate. Refreshes when
    /// any input the daemon would care about changes (repo, agent,
    /// model, effort, goal length). Debounced via the .task(id:) below.
    @State private var preflight: PreflightResponse?
    @State private var preflightLoading: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    Picker("Repo", selection: $repoKey) {
                        ForEach(client.repos, id: \.key) { repo in
                            Text(repo.displayName).tag(repo.key)
                        }
                    }
                    TextField("Base branch", text: $baseBranch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Goal") {
                    TextField("What should the agent do?", text: $goal, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(3...6)
                }

                Section("Agent") {
                    // v0.7.10: agent toggle resets model + effort to
                    // the picked agent's defaults so the model picker
                    // below doesn't sit on a stale Claude id when the
                    // user flips to Codex / Gemini.
                    Picker("Agent", selection: Binding(
                        get: { agent },
                        set: { newAgent in
                            guard newAgent != agent else { return }
                            let defaults = ComposerStore.ChipDefaults.for(
                                agent: newAgent, catalog: client.modelCatalog
                            )
                            agent = newAgent
                            modelId = defaults.modelId
                            effort = defaults.effort ?? .medium
                        }
                    )) {
                        Text("Claude").tag(AgentKind.claude)
                        Text("Codex").tag(AgentKind.codex)
                        Text("Gemini").tag(AgentKind.gemini)
                    }
                    .pickerStyle(.segmented)

                    iOSModelPicker(selectedModelId: $modelId, catalog: client.modelCatalog, agent: agent)

                    iOSEffortDial(selected: $effort, supportsEffort: currentModelSupportsEffort)
                }

                Section("Run mode") {
                    // v0.7.9: Mode picker removed. Every new session
                    // lands in a city-named worktree by default; the
                    // SessionMode enum stays in the wire for
                    // back-compat with persisted v3 sessions.

                    // Plan mode applies to both agents. Claude maps it
                    // to `--permission-mode plan`; Codex maps it to
                    // `--sandbox read-only`. Approve & run flips the
                    // sandbox afterwards.
                    Toggle("Plan mode", isOn: $planMode)

                    Toggle("Run as A/B pair (Claude + Codex)", isOn: $runAsABPair)
                        .toggleStyle(.switch)
                        .tint(SessionsV2Theme.accent)
                }

                preflightSection

                if client.hasWireVersionMismatch {
                    Section {
                        Label("Mac is running a different version. Update the Mac app.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(SessionsV2Theme.warn)
                    }
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack(spacing: 8) {
                        Button(action: openOnMac) {
                            Label("Open on Mac", systemImage: "desktopcomputer")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !client.isConfigured)
                        .help("Send the prompt to the paired Mac's empty-state composer instead of starting a session here.")
                        .accessibilityLabel("Send draft to Mac")
                        Button(action: startSession) {
                            if isStarting {
                                ProgressView()
                            } else {
                                Label("Start", systemImage: "play.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SessionsV2Theme.accent)
                        .disabled(repoKey.isEmpty || isStarting)
                        .accessibilityLabel("Start new session")
                    }
                }
            }
            .task {
                await client.refreshModelCatalog()
                if repoKey.isEmpty, let first = client.repos.first {
                    repoKey = first.key
                }
            }
            .task(id: preflightInputs) {
                await refreshPreflight()
            }
            .alert("Couldn't open on Mac",
                   isPresented: Binding(
                    get: { openOnMacUnsupportedAlert != nil },
                    set: { if !$0 { openOnMacUnsupportedAlert = nil } }
                   ),
                   actions: { Button("OK", role: .cancel) { openOnMacUnsupportedAlert = nil } },
                   message: { Text(openOnMacUnsupportedAlert ?? "") })
            // v0.7.4: present the SDK-resumed response inline when the Mac
            // returns `.deliveredWithCodexResume`. Dismissing the sheet
            // also closes NewSession (we're done — the response is read).
            .sheet(item: $codexResumeResult, onDismiss: {
                isPresented = false
            }) { result in
                CodexResumeResultSheet(result: result) {
                    codexResumeResult = nil
                }
            }
        }
    }

    /// Tuple of every input the preflight estimate depends on. Used as
    /// the `.task(id:)` key so SwiftUI re-runs the refresh whenever any
    /// input changes (Form binding edits invalidate the task naturally).
    private var preflightInputs: String {
        "\(repoKey)|\(agent.rawValue)|\(modelId ?? "")|\(effort.rawValue)|\(goal.count)"
    }

    @MainActor
    private func refreshPreflight() async {
        // Need all three keys before the daemon can answer.
        guard !repoKey.isEmpty,
              let modelId, !modelId.isEmpty,
              client.isConfigured else {
            preflight = nil
            return
        }
        preflightLoading = true
        defer { preflightLoading = false }
        let query = PreflightQuery(
            repoKey: repoKey,
            agent: agent,
            model: modelId,
            effort: currentModelSupportsEffort ? effort : nil,
            goalLength: goal.count
        )
        preflight = await client.fetchPreflight(query: query)
    }

    @ViewBuilder
    private var preflightSection: some View {
        if let preflight {
            Section {
                CostBannerView(
                    response: preflight,
                    currentModel: modelId ?? "",
                    onSwap: { newModel in
                        modelId = newModel
                    }
                )
            } header: {
                Text("Estimated cost")
            } footer: {
                if preflight.staleData {
                    Text("Estimate based on cached usage; may be off until the next analytics refresh.")
                }
            }
        } else if preflightLoading {
            Section {
                HStack {
                    ProgressView()
                    Text("Calculating estimate…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var currentModelSupportsEffort: Bool {
        guard let id = modelId,
              let entry = client.modelCatalog.entry(forId: id)
        else { return true }
        return entry.supportsEffort
    }

    private func startSession() {
        guard !repoKey.isEmpty else { return }
        isStarting = true
        Task {
            _ = await client.createSession(NewSessionRequest(
                repoKey: repoKey,
                agent: agent,
                model: modelId,
                planMode: planMode,
                goal: goal.isEmpty ? nil : goal,
                useWorktree: mode == .worktree,
                baseBranch: baseBranch.isEmpty ? nil : baseBranch,
                effort: currentModelSupportsEffort ? effort : nil,
                abPair: runAsABPair ? (agent == .claude ? .codex : .claude) : nil
            ))
            await MainActor.run {
                isStarting = false
                isPresented = false
            }
        }
    }

    /// X1 cross-Apple handoff: post the current composer state as a
    /// `compose-draft` WS envelope to the paired Mac. The Mac's empty-state
    /// composer pre-fills with this text + chip suggestions. No session is
    /// spawned here — the user finishes on the Mac.
    private func openOnMac() {
        let draft = ComposeDraft(
            text: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            repoKey: repoKey.isEmpty ? nil : repoKey,
            suggestedAgent: agent,
            suggestedModel: modelId,
            suggestedEffort: currentModelSupportsEffort ? effort : nil
        )
        Task {
            // Refresh /health first so the wire-version gate inside
            // postComposeDraft has fresh data to consult.
            await client.refreshHealth()
            let result = await client.postComposeDraft(draft)
            await MainActor.run {
                switch result {
                case .delivered:
                    isPresented = false
                case .deliveredWithCodexResume(let threadId, let response):
                    // v0.7.4: surface the agent's response inline. Open a
                    // result sheet on top of NewSession; user can read the
                    // response and copy the threadId for a follow-up
                    // draft if they want to continue the same SDK turn.
                    codexResumeResult = CodexResumeResult(
                        threadId: threadId,
                        response: response
                    )
                case .macUnsupported(let v):
                    openOnMacUnsupportedAlert = "Your Mac is on wire version \(v); Open on Mac needs ≥\(AgentControlWireVersion.composeDraftMinimum). Update Clawdmeter on the Mac."
                case .failed(let msg):
                    openOnMacUnsupportedAlert = msg
                }
            }
        }
    }
}

// MARK: - Codex SDK resume result (v0.7.4)

/// Identifiable payload for `.sheet(item:)` so SwiftUI knows when to
/// present + dismiss. Set on `.deliveredWithCodexResume`.
private struct CodexResumeResult: Identifiable, Equatable {
    let id = UUID()
    let threadId: String
    let response: String
}

/// Sheet shown after the Mac executes a Codex SDK resume turn. Displays
/// the agent's response text and offers a "Continue on Mac" deep link.
private struct CodexResumeResultSheet: View {
    let result: CodexResumeResult
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                        Text("Mac executed your prompt")
                            .font(.headline)
                    }
                    Text("Thread \(String(result.threadId.prefix(8)))…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text(result.response.isEmpty
                         ? "(no response text)"
                         : result.response)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    Button {
                        UIPasteboard.general.string = result.threadId
                    } label: {
                        Label("Copy thread ID", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("Codex response")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
            // v0.7.7 Handoff: advertise the thread to the user's Mac
            // via Continuity. The user picks up the Handoff icon in
            // the Mac dock and the Mac focuses the matching Sessions
            // tab (handled in `Application(_:continue:restorationHandler:)`).
            .userActivity(
                "com.clawdmeter.continue-codex-thread",
                isActive: !result.threadId.isEmpty
            ) { activity in
                activity.title = "Continue Codex thread"
                activity.targetContentIdentifier = result.threadId
                activity.userInfo = ["threadId": result.threadId]
                activity.requiredUserInfoKeys = ["threadId"]
                activity.isEligibleForHandoff = true
                activity.isEligibleForSearch = false
                activity.isEligibleForPublicIndexing = false
            }
        }
    }
}
