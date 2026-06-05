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
    @Environment(\.tahoe) private var t
    @StateObject private var store: iOSAntigravityPlanStore

    public init(store: iOSAntigravityPlanStore) {
        _store = StateObject(wrappedValue: store)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let snapshot = store.snapshot {
                    if snapshot.awaitingFirstTurn {
                        awaiting
                    } else {
                        task(snapshot)
                        if !snapshot.planSteps.isEmpty {
                            steps(snapshot)
                        }
                        if !snapshot.annotations.isEmpty {
                            annotations(snapshot)
                        }
                        footer(snapshot)
                    }
                } else if store.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading plan...")
                            .font(TahoeFont.body(12))
                            .foregroundStyle(t.fg3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 100)
                } else if let err = store.loadError {
                    TahoeGlass(radius: 6, tone: .chip) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TahoeIcon("x", size: 12, weight: .bold)
                                Text("Could not load plan")
                                    .font(TahoeFont.body(13, weight: .bold))
                            }
                            .foregroundStyle(.orange)
                            Text(err)
                                .font(TahoeFont.body(11))
                                .foregroundStyle(t.fg3)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Retry") { Task { await store.refresh() } }
                                .font(TahoeFont.body(12, weight: .semibold))
                        }
                        .padding(12)
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

    private var header: some View {
        TahoeGlass(radius: 6, tone: .chip) {
            HStack(spacing: 8) {
                TahoeProviderGlyph(provider: .gemini, size: 20)
                Text("Antigravity Plan")
                    .font(TahoeFont.body(13, weight: .bold))
                    .foregroundStyle(t.fg)
                Spacer()
                if let model = store.snapshot?.model, !model.isEmpty {
                    Text(model)
                        .font(TahoeFont.mono(10.5, weight: .semibold))
                        .foregroundStyle(t.fg3)
                }
            }
            .padding(12)
        }
    }

    private var awaiting: some View {
        VStack(alignment: .center, spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("Antigravity is preparing this task...")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func task(_ snapshot: AntigravityPlanSnapshot) -> some View {
        TahoeGlass(radius: 6, tone: .chip) {
            VStack(alignment: .leading, spacing: 6) {
                if !snapshot.taskHeadline.isEmpty {
                    Text(snapshot.taskHeadline)
                        .font(TahoeFont.body(14, weight: .bold))
                        .foregroundStyle(t.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !snapshot.taskBody.isEmpty {
                    Text(snapshot.taskBody)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func steps(_ snapshot: AntigravityPlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IMPLEMENTATION PLAN")
                .font(TahoeFont.body(10.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(t.fg3)
            TahoeGlass(radius: 6, tone: .raised) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.planSteps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: step.isComplete ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(step.isComplete ? .green : t.fg4)
                                .frame(width: 18)
                            Text(step.label)
                                .font(TahoeFont.body(12.5))
                                .foregroundStyle(step.isComplete ? t.fg3 : t.fg)
                                .strikethrough(step.isComplete)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, CGFloat(step.depth) * 14)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        if index < snapshot.planSteps.count - 1 {
                            TahoeHair()
                        }
                    }
                }
            }
        }
    }

    private func annotations(_ snapshot: AntigravityPlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ANNOTATIONS")
                .font(TahoeFont.body(10.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(t.fg3)
            ForEach(snapshot.annotations) { ann in
                TahoeGlass(radius: 6, tone: .chip) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ann.filename)
                            .font(TahoeFont.mono(10.5, weight: .semibold))
                            .foregroundStyle(t.fg3)
                        Text(ann.body)
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(t.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func footer(_ snapshot: AntigravityPlanSnapshot) -> some View {
        HStack {
            if let usage = snapshot.totalUsage {
                let prefix = (usage.isEstimate ?? false) ? "~" : ""
                Text("\(prefix)\(usage.total) tokens")
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg3)
            }
            if let model = snapshot.model {
                Text("/")
                    .foregroundStyle(t.fg4)
                Text(model)
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg3)
            }
            Spacer()
        }
    }
}
