import SwiftUI
import ClawdmeterShared

/// Sessions tab content for the Mac dashboard. Phase 1: placeholder list
/// bound to `RepoIndex.snapshot`. Phase 2 adds session list per repo;
/// Phase 3 adds the terminal/structured-card detail view.
///
/// Per the design review (Pass 1 + Pass 7):
/// - Information hierarchy: tab strip → repo sidebar → session detail
/// - Empty state: warm "No sessions yet" with terra-cotta ⊕ CTA
/// - Repo grouping: disclosure-triangle expand/collapse
/// - Status badges: 8pt color dot + text label
struct SessionsView: View {

    @ObservedObject var model: SessionsModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HSplitView {
            repoSidebar
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(backgroundColor)
    }

    // MARK: - Repo sidebar

    private var repoSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Repos")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(secondaryText)
                Spacer()
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: { Task { await model.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Refresh repo list")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if model.repos.isEmpty {
                emptyState
            } else {
                List(model.repos, id: \.key, selection: $model.selectedRepoKey) { repo in
                    repoRow(repo)
                        .tag(repo.key)
                }
                .listStyle(.sidebar)
            }

            Spacer(minLength: 0)

            // New session button (terra-cotta, full-width)
            Button(action: { /* Phase 2: open new-session sheet */ }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("New session")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(terraCotta)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .disabled(model.repos.isEmpty)
        }
    }

    private func repoRow(_ repo: AgentRepo) -> some View {
        HStack(spacing: 8) {
            // 8pt color dot — terra-cotta when active sessions, dim grey otherwise.
            Circle()
                .fill(repo.hasActiveSessions ? terraCotta : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
            Text(repo.displayName)
                .lineLimit(1)
            Spacer()
            // Phase 2 will show session count badge here.
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(secondaryText)
            Text("No repos yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(primaryText)
            Text("Repos appear after you run Claude or Codex in them, or after you add a scan root in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Detail column (right side)

    @ViewBuilder
    private var detailColumn: some View {
        if let selected = model.selectedRepo {
            // Phase 2 fills this with session list + new-session affordance.
            VStack(alignment: .leading, spacing: 16) {
                Text(selected.displayName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(primaryText)
                Text(selected.key)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(secondaryText)
                    .textSelection(.enabled)

                Divider()

                // Phase 2 placeholder.
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "rectangle.dashed",
                    description: Text("Sessions for \(selected.displayName) will appear here once Phase 2 ships the session lifecycle.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "Pick a repo",
                systemImage: "sidebar.left",
                description: Text("Select a repo from the sidebar to start a session.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Theme helpers

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.96, green: 0.96, blue: 0.96)
    }

    private var primaryText: Color {
        colorScheme == .dark ? .white : .black
    }

    private var secondaryText: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.55)
            : Color.black.opacity(0.55)
    }
}

/// Lightweight ObservableObject the SessionsView observes. Phase 1: just
/// wraps `RepoIndex`. Phase 2 will add session list + selection state.
@MainActor
public final class SessionsModel: ObservableObject {

    @Published public var repos: [AgentRepo] = []
    @Published public var selectedRepoKey: String?
    @Published public var isRefreshing: Bool = false
    @Published public var selectedSessionId: UUID?

    public var selectedRepo: AgentRepo? {
        guard let key = selectedRepoKey else { return nil }
        return repos.first { $0.key == key }
    }

    public let repoIndex: RepoIndex
    public let registry: AgentSessionRegistry
    public let supervisor: TmuxSupervisor
    private var refreshTask: Task<Void, Never>?

    public init(
        repoIndex: RepoIndex,
        registry: AgentSessionRegistry,
        supervisor: TmuxSupervisor
    ) {
        self.repoIndex = repoIndex
        self.registry = registry
        self.supervisor = supervisor
    }

    public var selectedSession: AgentSession? {
        guard let id = selectedSessionId else { return nil }
        return registry.sessions.first { $0.id == id }
    }

    public func sessions(for repoKey: String) -> [AgentSession] {
        registry.sessions.filter { $0.repoKey == repoKey }
    }

    /// Trigger a refresh of the repo list. Idempotent.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = await repoIndex.refresh()
        self.repos = snapshot
    }

    /// Subscribe to periodic background refreshes (E6: 60s cadence).
    /// Called once at app startup. The returned task lives for the app lifetime.
    public func startPeriodicRefresh() -> Task<Void, Never> {
        // Initial paint comes from the in-memory snapshot (instant). The
        // 60s timer rebuilds in the background.
        Task { [weak self] in
            guard let self else { return }
            // Initial sync paint.
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }
}
