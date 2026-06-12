// Mac Sessions IDE Plan pane for Antigravity 2 (v0.6.0).
//
// Renders three sections vertically:
//   1. Task headline + body (from brain/<uuid>/task.md)
//   2. Implementation plan checklist (from implementation_plan.md)
//   3. Annotations + "Open in Antigravity" deep-link
//
// Data flows in via AntigravityPlanStore — a small @MainActor
// ObservableObject that:
//   - Polls the daemon's /sessions/:id/antigravity-plan endpoint at 3s
//     intervals (WS subscribe lands in a follow-up; HTTP poll is fine
//     for v0.6.0 since the brain dir doesn't change very often).
//   - Manages the loading + error states.
//
// Empty states surfaced:
//   - awaitingFirstTurn: spinner + "Antigravity is preparing this task…"
//   - non-Gemini session: hidden (returns nil view from container)
//   - error: error pill with retry

import SwiftUI
import ClawdmeterShared

/// View model for the Plan pane. @MainActor since it drives SwiftUI.
@MainActor
public final class AntigravityPlanStore: ObservableObject {
    @Published public private(set) var snapshot: AntigravityPlanSnapshot?
    @Published public private(set) var loadError: String?
    @Published public private(set) var isLoading: Bool = false

    /// Closure that fetches the snapshot from the daemon. Tests can pass
    /// a fake; production passes the AgentControlClient HTTP fetch.
    private let fetch: (UUID) async throws -> AntigravityPlanSnapshot
    private let sessionId: UUID
    private var pollTask: Task<Void, Never>?

    public init(
        sessionId: UUID,
        fetch: @escaping (UUID) async throws -> AntigravityPlanSnapshot
    ) {
        self.sessionId = sessionId
        self.fetch = fetch
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                // 3s poll cadence — brain dir mtime changes ~1-2 times per
                // user turn, ample for live-tail without hammering disk.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        isLoading = (snapshot == nil) // first load shows spinner
        do {
            let next = try await fetch(sessionId)
            snapshot = next
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

/// The Plan pane SwiftUI view. Owns its AntigravityPlanStore lifecycle.
public struct AntigravityPlanPane: View {
    @StateObject private var store: AntigravityPlanStore

    public init(store: AntigravityPlanStore) {
        _store = StateObject(wrappedValue: store)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let snapshot = store.snapshot {
                    if snapshot.awaitingFirstTurn {
                        awaitingFirstTurnView
                    } else {
                        taskSection(snapshot: snapshot)
                        if !snapshot.planSteps.isEmpty {
                            Divider()
                            planSection(snapshot: snapshot)
                        }
                        if !snapshot.annotations.isEmpty {
                            Divider()
                            annotationsSection(snapshot: snapshot)
                        }
                        Divider()
                        footer(snapshot: snapshot)
                    }
                } else if store.isLoading {
                    initialLoadingView
                } else if let err = store.loadError {
                    errorView(err)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Antigravity Plan").font(.system(size: 13, weight: .semibold))
            Spacer()
            if let model = store.snapshot?.model {
                Text(model).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    private var awaitingFirstTurnView: some View {
        VStack(alignment: .center, spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("Antigravity is preparing this task…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var initialLoadingView: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Loading Plan…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't load Plan", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Retry", action: ContinuumAnalytics.wrapButton(
                    "retry",
                    {
 Task { await store.refresh() } 
                    }
                ))
        }
    }

    private func taskSection(snapshot: AntigravityPlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !snapshot.taskHeadline.isEmpty {
                Text(snapshot.taskHeadline)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !snapshot.taskBody.isEmpty {
                Text(snapshot.taskBody)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func planSection(snapshot: AntigravityPlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Implementation Plan").font(.system(size: 12, weight: .semibold))
            ForEach(snapshot.planSteps) { step in
                stepRow(step)
            }
        }
    }

    private func stepRow(_ step: WirePlanStep) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: step.isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(step.isComplete ? .green : .secondary)
                .font(.system(size: 12))
            Text(step.label)
                .font(.system(size: 12))
                .foregroundStyle(step.isComplete ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(step.depth) * 16)
    }

    private func annotationsSection(snapshot: AntigravityPlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Annotations").font(.system(size: 12, weight: .semibold))
            ForEach(snapshot.annotations) { ann in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ann.filename).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Text(ann.body).font(.system(size: 11, design: .monospaced))
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }
        }
    }

    private func footer(snapshot: AntigravityPlanSnapshot) -> some View {
        HStack {
            if let usage = snapshot.totalUsage {
                let prefix = (usage.isEstimate ?? false) ? "~" : ""
                Text("\(prefix)\(usage.total) tokens")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !snapshot.brainUUID.isEmpty {
                Button(action: ContinuumAnalytics.wrapButton(
                        "antigravityplanpane_l221",
                        {
                    if let url = URL(string: "antigravity://brain/\(snapshot.brainUUID)") {
                        NSWorkspace.shared.open(url)
                    }
                
                        }
                    )) {
                    Label("Open in Antigravity", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
