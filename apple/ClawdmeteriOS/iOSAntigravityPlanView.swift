// iOS Plan tab for Antigravity 2 sessions (v0.6.0 wire v7).
//
// Mirrors the Mac AntigravityPlanPane: task headline + body + step
// checklist + annotations + open-in-Mac button. Polls the daemon's
// /sessions/:id/antigravity-plan endpoint at 3s when foregrounded.
// Gated on `agentClient.serverWireVersion >= antigravityMinimum (7)`;
// older paired Macs hide this tab and show an "Update Clawdmeter on
// Mac" banner instead.

import SwiftUI
import ClawdmeterShared

@MainActor
public final class iOSAntigravityPlanStore: ObservableObject {
    @Published public private(set) var snapshot: AntigravityPlanSnapshot?
    @Published public private(set) var loadError: String?
    @Published public private(set) var isLoading: Bool = false

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
        isLoading = (snapshot == nil)
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

public struct iOSAntigravityPlanView: View {
    @StateObject private var store: iOSAntigravityPlanStore

    public init(store: iOSAntigravityPlanStore) {
        _store = StateObject(wrappedValue: store)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let snapshot = store.snapshot {
                    if snapshot.awaitingFirstTurn {
                        awaiting
                    } else {
                        task(snapshot)
                        if !snapshot.planSteps.isEmpty {
                            Divider()
                            steps(snapshot)
                        }
                        if !snapshot.annotations.isEmpty {
                            Divider()
                            annotations(snapshot)
                        }
                        Divider()
                        footer(snapshot)
                    }
                } else if store.isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading Plan…")
                    }
                } else if let err = store.loadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Couldn't load Plan", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(err).font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { Task { await store.refresh() } }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Plan")
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .refreshable { await store.refresh() }
    }

    private var awaiting: some View {
        VStack(alignment: .center, spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("Antigravity is preparing this task…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func task(_ snapshot: AntigravityPlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !snapshot.taskHeadline.isEmpty {
                Text(snapshot.taskHeadline).font(.headline)
            }
            if !snapshot.taskBody.isEmpty {
                Text(snapshot.taskBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func steps(_ snapshot: AntigravityPlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Implementation Plan").font(.headline)
            ForEach(snapshot.planSteps) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: step.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(step.isComplete ? .green : .secondary)
                    Text(step.label)
                        .foregroundStyle(step.isComplete ? .secondary : .primary)
                }
                .padding(.leading, CGFloat(step.depth) * 16)
            }
        }
    }

    private func annotations(_ snapshot: AntigravityPlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Annotations").font(.headline)
            ForEach(snapshot.annotations) { ann in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ann.filename).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(ann.body).font(.caption.monospaced())
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }
        }
    }

    private func footer(_ snapshot: AntigravityPlanSnapshot) -> some View {
        HStack {
            if let usage = snapshot.totalUsage {
                let prefix = (usage.isEstimate ?? false) ? "~" : ""
                Text("\(prefix)\(usage.total) tokens").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let model = snapshot.model {
                Text("·").foregroundStyle(.secondary)
                Text(model).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
