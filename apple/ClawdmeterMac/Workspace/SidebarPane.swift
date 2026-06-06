import SwiftUI
import AppKit
import ClawdmeterShared

struct SidebarPane: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var workbenchState: WorkbenchState
    @ObservedObject var presentationStore: SessionPresentationStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Used to pause the 1Hz "external activity" tick when the window isn't
    // active (app backgrounded / occluded by another window). The tick only
    // drives cosmetic relative-time / "live now" freshness, so there's
    // nothing to refresh while the user can't see it.
    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var searchFocused: Bool

    /// Persisted sidebar grouping + sorting + status-filter preferences.
    /// All three are local to the Mac UI — iOS has its own equivalents.
    @AppStorage("clawdmeter.sidebar.grouping") private var groupingRaw: String = SessionGrouping.status.rawValue
    @AppStorage("clawdmeter.sidebar.sorting")  private var sortingRaw: String  = SessionSorting.recency.rawValue
    @AppStorage("clawdmeter.sidebar.status")   private var statusRaw: String   = SessionStatusFilter.all.rawValue

    /// History section is collapsed by default — older external sessions
    /// clutter the sidebar and most of the time the user wants the active
    /// repos at the top. Tapping the History row expands the list.
    @AppStorage("clawdmeter.sidebar.historyExpanded") private var historyExpanded: Bool = false

    /// v0.29.33: opt-in to filesystem session discovery. Default false → the
    /// sidebar shows only Managed (explicitly-added) repos and RepoIndex does
    /// NO ~/.claude / ~/.codex / folder scan, so opening Code triggers no
    /// folder/cross-app permission prompt. The "Discover parallel sessions"
    /// button flips this shared key (RepoIndex reads the same UserDefaults
    /// key via ProviderEnablement) and refreshes → status-quo discovery.
    @AppStorage("clawdmeter.code.discoverParallelSessions") private var discoverParallelSessions: Bool = false

    /// v0.5.4: rename sheet state. v0.5.9: split into a dedicated bool
    /// + data target — the `Binding(get:set:)` pattern for `isPresented:`
    /// didn't reliably trigger alert presentation; the canonical pattern
    /// is `@State Bool` + `presenting:` payload.
    @State private var renameTarget: AgentSession?
    @State private var renameInput: String = ""
    @State private var showingRenameAlert: Bool = false
    /// Add Repo flow sheets. "Open project" doesn't need a sheet — it pops
    /// NSOpenPanel directly. Clone + Quick Start each get a SwiftUI sheet.
    @State private var showingCloneRepoSheet: Bool = false
    @State private var showingQuickStartRepoSheet: Bool = false
    // v0.5.10 — parallel state for Recent JSONL row rename. Keyed by path
    // (not session id) because these rows aren't Clawdmeter-owned
    // sessions; they're files we surface.
    @State private var renameJSONLTarget: RecentSession?
    @State private var renameJSONLInput: String = ""
    @State private var showingRenameJSONLAlert: Bool = false
    @State private var collapsedStatusGroupIDs: Set<String> = []
    @State private var collapsedPrioritySectionIDs: Set<String> = []
    @State private var sidebarViewportHeight: CGFloat = 0
    @State private var sidebarContentHeight: CGFloat = 0
    @State private var hoveredSessionId: UUID?
    @State private var hoveredRecentPath: String?
    @State private var colorTagTarget: AgentSession?
    @State private var colorTagInput: String = ""
    @State private var showingColorTagAlert = false
    @State private var comparisonPair: SessionComparisonPair?
    @State private var externalActivityNow: Date = Date()
    @State private var requestedRepoIdentityKeys: Set<String> = []

    /// A11: single-slot cache for the sidebar projection. Persists across
    /// body re-evals (reference type held via @State) so SwiftUI ticking
    /// the body for unrelated reasons (registry mutation that doesn't
    /// touch any displayed field, presentationStore change, etc.) doesn't
    /// re-bucket every session. Cache hits short-circuit the heavy
    /// grouper/canonicalizer call. The key bundles every input the
    /// projection reads — see `SidebarProjectionKey` for the contract.
    @State private var projectionCache = SingleSlotProjectionCache<SidebarProjectionKey, SidebarProjection>()

    private var grouping: SessionGrouping {
        SessionGrouping(rawValue: groupingRaw) ?? .repo
    }
    private var sorting: SessionSorting {
        SessionSorting(rawValue: sortingRaw) ?? .recency
    }
    private var statusFilter: SessionStatusFilter {
        SessionStatusFilter(rawValue: statusRaw) ?? .all
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            sidebarHeader
            TahoeHairline()
            content
        }
        .background(Color.clear)
        // v0.5.4 / v0.5.9 rename sheet. Explicit bool + presenting:
        // payload is the SwiftUI pattern that reliably presents — the
        // earlier Binding(get:set:) form silently no-op'd because the
        // closure-captured state read isn't tracked as a dependency.
        .alert(
            "Rename session",
            isPresented: $showingRenameAlert,
            presenting: renameTarget
        ) { target in
            TextField("Name", text: $renameInput)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                commitSessionRename(target, name: renameInput)
            }
            Button("Clear name", role: .destructive) {
                commitSessionRename(target, name: nil)
            }
            Button("Cancel", role: .cancel) {
                resetSessionRenameState()
            }
        } message: { target in
            Text("Currently: \(sessionTitle(target))")
        }
        // v0.5.10 — Recent JSONL row rename alert. Same canonical Bool
        // + presenting payload pattern as the session-rename alert.
        .alert(
            "Rename session",
            isPresented: $showingRenameJSONLAlert,
            presenting: renameJSONLTarget
        ) { target in
            TextField("Name", text: $renameJSONLInput)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                let trimmed = renameJSONLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                model.renameJSONLAlias(path: target.path, name: trimmed.isEmpty ? nil : trimmed)
                showingRenameJSONLAlert = false
                renameJSONLTarget = nil
                renameJSONLInput = ""
            }
            Button("Clear name", role: .destructive) {
                model.renameJSONLAlias(path: target.path, name: nil)
                showingRenameJSONLAlert = false
                renameJSONLTarget = nil
                renameJSONLInput = ""
            }
            Button("Cancel", role: .cancel) {
                showingRenameJSONLAlert = false
                renameJSONLTarget = nil
                renameJSONLInput = ""
            }
        } message: { target in
            Text("Currently: \(recentTitle(target))")
        }
        .alert(
            "Color tag",
            isPresented: $showingColorTagAlert,
            presenting: colorTagTarget
        ) { target in
            TextField("Tag name", text: $colorTagInput)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                try? presentationStore.setColorTag(target.id, tag: colorTagInput)
                showingColorTagAlert = false
                colorTagTarget = nil
                colorTagInput = ""
            }
            Button("Clear tag", role: .destructive) {
                try? presentationStore.setColorTag(target.id, tag: nil)
                showingColorTagAlert = false
                colorTagTarget = nil
                colorTagInput = ""
            }
            Button("Cancel", role: .cancel) {
                showingColorTagAlert = false
                colorTagTarget = nil
                colorTagInput = ""
            }
        } message: { target in
            Text("Use a short label like Review, Bug, Docs, or Ship for \(sessionTitle(target)).")
        }
        .sheet(item: $comparisonPair) { pair in
            SessionComparisonSheet(pair: pair, model: model)
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            // Skip cosmetic freshness ticks while the window is inactive —
            // no visible relative-time/green-dot to refresh. (Same-window
            // hidden-tab gating needs an active-tab flag from MacRootView;
            // see cross-file note.)
            guard controlActiveState != .inactive else { return }
            guard model.repos.contains(where: { !$0.recentSessions.isEmpty }) else { return }
            externalActivityNow = now
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            Text("Projects")
                .font(TahoeFont.body(11, weight: .bold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(t.fg3)
                .lineLimit(1)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            filterMenu
            addRepoMenu
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .sheet(isPresented: $showingCloneRepoSheet) {
            CloneRepoSheet(onboarding: model.repoOnboarding) { _ in }
        }
        .sheet(isPresented: $showingQuickStartRepoSheet) {
            QuickStartRepoSheet(onboarding: model.repoOnboarding) { _ in }
        }
    }

    /// Sidebar header's "+ Add project" Menu. Replaces the previous
    /// "New session" entry point on this button. New Session now lives on
    /// `Cmd+N` (unchanged) and the per-repo `+` button. Three rows mirror
    /// Conductor's Add-Repo popover.
    @ViewBuilder
    private var addRepoMenu: some View {
        Menu {
            Button {
                Task {
                    do { _ = try await model.repoOnboarding.openLocalFolder() }
                    catch let err as RepoOnboardingError {
                        if case .alreadyRegistered = err {
                            // RepoOnboarding still fires onWorkspaceRegistered so
                            // the sidebar highlights the existing repo — confirm to
                            // the user with a toast instead of silently no-op'ing.
                            await MainActor.run {
                                NotificationCenter.default.post(
                                    name: .clawdmeterShowTransientToast,
                                    object: nil,
                                    userInfo: ["toast": TransientToast(title: "Already in your projects")]
                                )
                            }
                            return
                        }
                        await MainActor.run { presentRepoOnboardingError(err) }
                    } catch {
                        await MainActor.run { presentRepoOnboardingError(error) }
                    }
                }
            } label: {
                Label("Open project", systemImage: "folder")
            }
            Button {
                showingCloneRepoSheet = true
            } label: {
                Label("Open GitHub project", systemImage: "globe")
            }
            Button {
                showingQuickStartRepoSheet = true
            } label: {
                Label("Quick start", systemImage: "plus.rectangle.on.folder")
            }
        } label: {
            // DESIGN.md: sidebar inline icon buttons are 24px with the 10px
            // small-radius token.
            TahoeIcon("folderPlus", size: 15, weight: .semibold)
                .foregroundStyle(t.accent)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(t.accentAlpha(t.dark ? 0.18 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(t.accentAlpha(0.32), lineWidth: 0.5)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add project")
    }

    private func presentRepoOnboardingError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't add project"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion {
            alert.informativeText += "\n\n\(suggestion)"
        }
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Linear-style filter / group / sort menu. Active non-default
    /// selections paint the chip terra-cotta so the user knows the
    /// sidebar is filtered without opening the menu.
    @ViewBuilder
    private var filterMenu: some View {
        let isCustomised =
            grouping != .status
            || sorting != .recency
            || statusFilter != .all
        Menu {
            Section("Status") {
                ForEach(SessionStatusFilter.allCases, id: \.self) { option in
                    Button(action: { statusRaw = option.rawValue }) {
                        Label(option.displayName, systemImage: statusFilter == option ? "checkmark" : "")
                    }
                }
            }
            Section("Group by") {
                ForEach(SessionGrouping.allCases, id: \.self) { option in
                    Button(action: { groupingRaw = option.rawValue }) {
                        Label(option.displayName, systemImage: grouping == option ? "checkmark" : "")
                    }
                }
            }
            Section("Sort by") {
                ForEach(SessionSorting.allCases, id: \.self) { option in
                    Button(action: { sortingRaw = option.rawValue }) {
                        Label(option.displayName, systemImage: sorting == option ? "checkmark" : "")
                    }
                }
            }
            Section("Projects") {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh repo list", systemImage: "arrow.clockwise")
                }
            }
            if isCustomised {
                Divider()
                Button("Reset filters") {
                    statusRaw = SessionStatusFilter.all.rawValue
                    groupingRaw = SessionGrouping.status.rawValue
                    sortingRaw = SessionSorting.recency.rawValue
                }
            }
        } label: {
            TahoeIcon("filter", size: 12)
                .foregroundStyle(isCustomised ? t.accent : t.fg3)
                .frame(width: 24, height: 24)
                .background(isCustomised ? t.accentAlpha(0.15) : t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group, sort, and filter sessions")
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            TahoeIcon("search", size: 12)
                .foregroundStyle(t.fg3)
            TextField("Search…", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(TahoeFont.body(12.5))
                .focused($searchFocused)
            if !model.searchQuery.isEmpty {
                Button(action: { model.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(t.fg3)
                }
                .buttonStyle(PressableButtonStyle())
            }
            Text("⌘K")
                .font(TahoeFont.body(10.5, weight: .semibold))
                .foregroundStyle(t.fg4)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(t.hairline, lineWidth: 0.5)
                )
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(t.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .onReceive(NotificationCenter.default.publisher(for: .focusSidebarSearch)) { _ in
            searchFocused = true
        }
    }

    private var statusBuckets: some View {
        HStack(spacing: 4) {
            sidebarBucket(
                title: "Active",
                count: statusCount(.active),
                active: statusFilter == .active,
                color: .green
            ) { toggleStatusFilter(.active) }
            sidebarBucket(
                title: "Review",
                count: statusCount(.inReview),
                active: statusFilter == .inReview,
                color: .orange
            ) { toggleStatusFilter(.inReview) }
            sidebarBucket(
                title: "Done",
                count: statusCount(.done),
                active: statusFilter == .done,
                color: terraCotta
            ) { toggleStatusFilter(.done) }
            sidebarBucket(
                title: "Archive",
                count: statusCount(.archived),
                active: statusFilter == .archived,
                color: .secondary
            ) { toggleStatusFilter(.archived) }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func toggleStatusFilter(_ filter: SessionStatusFilter) {
        statusRaw = statusFilter == filter ? SessionStatusFilter.all.rawValue : filter.rawValue
        if grouping != .status {
            groupingRaw = SessionGrouping.status.rawValue
        }
    }

    private func sidebarBucket(
        title: String,
        count: Int,
        active: Bool,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(active ? .white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .foregroundStyle(active ? .white : color)
            .background(
                active ? color.opacity(0.82) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func statusCount(_ filter: SessionStatusFilter) -> Int {
        let sessions = model.filter(sessions: model.registry.sessions)
        switch filter {
        case .all:
            return sessions.count
        case .active:
            return sessions.filter { SessionSidebarGrouper.bucket(for: $0, reviewSessionIds: reviewSessionIds) == .active }.count
        case .inReview:
            return sessions.filter { SessionSidebarGrouper.bucket(for: $0, reviewSessionIds: reviewSessionIds) == .inReview }.count
        case .done:
            return sessions.filter { SessionSidebarGrouper.bucket(for: $0, reviewSessionIds: reviewSessionIds) == .done }.count
        case .archived:
            return sessions.filter { SessionSidebarGrouper.bucket(for: $0, reviewSessionIds: reviewSessionIds) == .archived }.count
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.filteredRepos.isEmpty && model.registry.sessions.isEmpty {
            emptyState
        } else {
            // A11: read the projection once at the top of the body so a
            // single cache hit covers content + filteredVisibleSessions
            // + reviewSessionIds. Local binding keeps the closure-level
            // re-reads as Swift property accesses (O(1)) rather than
            // re-running the cache lookup.
            let projection = currentProjection
            ScrollView {
                LazyVStack(spacing: 0) {
                    if projection.hasPriorityContent {
                        prioritySidebarContent(projection)
                    } else {
                        filteredEmptyState
                    }
                    // Sits under the Managed repos (or the empty state). Off by
                    // default; tapping opts in to full filesystem discovery for
                    // this and future launches. Until then nothing reads
                    // ~/.claude / ~/.codex or scans user folders.
                    if !discoverParallelSessions {
                        discoverSessionsButton
                    }
                }
                .padding(.vertical, 6)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: SidebarContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: SidebarViewportHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(SidebarContentHeightKey.self) { sidebarContentHeight = $0 }
            .onPreferenceChange(SidebarViewportHeightKey.self) { sidebarViewportHeight = $0 }
            .mask(sidebarMask)
        }
    }

    @ViewBuilder
    private var sidebarMask: some View {
        if sidebarContentHeight > sidebarViewportHeight + 8 {
            sidebarFadeMask
        } else {
            Rectangle().fill(.black)
        }
    }

    private var sidebarFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
        }
    }

    /// Search + showArchived already filter the repos via the model.
    /// The status filter is applied in the grouper for non-repo paths;
    /// for repo grouping we still want to honour it by post-filtering.
    private var filteredReposForGrouping: [AgentRepo] {
        model.filteredRepos
    }

    /// A11: cache-backed sidebar projection. Reads upstream state once
    /// per body pass, builds the cache key, consults the cache. On hit:
    /// returns the prior projection without re-bucketing. On miss:
    /// rebuilds via `SidebarProjectionBuilder.build(...)`. The body
    /// downstream (`content`, `filteredVisibleSessions`, `reviewSessionIds`)
    /// all read from this one projection so the cache hit applies to
    /// every consumer.
    ///
    /// **Search step runs outside the cache.** `model.filter(sessions:)`
    /// peeks at transcript bodies via the LRU-bound `chatStores` map,
    /// which lives in `SessionsModel` and isn't a value type. Running it
    /// outside the builder keeps the builder a pure function over its
    /// inputs (testable from XCTest). The post-search session list gets
    /// its own fingerprint in the cache key, so a chat-store tick that
    /// shifts which sessions pass the filter properly invalidates the
    /// cache even though the upstream query string is identical.
    private var currentProjection: SidebarProjection {
        let sessions = model.registry.sessions
        let searchFiltered = model.filter(sessions: sessions)
        let repos = model.filteredRepos
        let now = externalActivityNow
        let ownedJSONLPaths = model.knownOwnedJSONLPaths
        let prSnapshot = workbenchState.snapshot.prCache
        let workbenchPRStateBySession: [UUID: String?] = prSnapshot.reduce(into: [:]) { acc, kv in
            acc[kv.key] = kv.value.state
        }
        // v0.29.28: pull the manually-registered workspace keys (Add Repo
        // flow) so the projection can pull those repos out of "Active
        // outside Clawdmeter" / "History" and into Managed.
        let workspaceRepoKeys: Set<String> = Set(
            model.workspaceStore.all().map { RepoIdentity.normalize($0.repoRoot) }
        )
        let key = SidebarProjectionKey(
            registryFingerprint: SidebarProjectionBuilder.registryFingerprint(sessions),
            reposFingerprint: SidebarProjectionBuilder.reposFingerprint(repos),
            workbenchPRCacheFingerprint: SidebarProjectionBuilder.workbenchPRCacheFingerprint(prSnapshot),
            searchFilteredFingerprint: SidebarProjectionBuilder.searchFilteredFingerprint(searchFiltered),
            query: model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            archiveFilter: model.showArchived,
            statusFilter: statusFilter,
            grouping: grouping,
            sorting: sorting,
            pinnedSet: presentationStore.snapshot.pinnedSessionIds,
            ownedJSONLPathsFingerprint: SidebarProjectionBuilder.ownedJSONLPathsFingerprint(ownedJSONLPaths),
            externalActivityClockBucket: SidebarProjectionBuilder.externalActivityClockBucket(now: now, repos: repos),
            workspaceRepoKeysFingerprint: SidebarProjectionBuilder.workspaceRepoKeysFingerprint(workspaceRepoKeys)
        )
        return projectionCache.value(for: key) {
            SidebarProjectionBuilder.build(
                searchFilteredSessions: searchFiltered,
                repos: repos,
                searchQuery: model.searchQuery,
                showArchived: model.showArchived,
                statusFilter: statusFilter,
                grouping: grouping,
                sorting: sorting,
                pinnedSessionIds: presentationStore.snapshot.pinnedSessionIds,
                workbenchPRStateBySession: workbenchPRStateBySession,
                ownedJSONLPaths: ownedJSONLPaths,
                workspaceRepoKeys: workspaceRepoKeys,
                now: now
            )
        }
    }

    private var filteredVisibleSessions: [AgentSession] {
        currentProjection.visibleSessions
    }

    private var reviewSessionIds: Set<UUID> {
        currentProjection.reviewSessionIds
    }

    @ViewBuilder
    private func prioritySidebarContent(_ projection: SidebarProjection) -> some View {
        if !projection.workspaceSections.isEmpty {
            ForEach(projection.workspaceSections) { section in
                workspaceSection(section)
            }
        }
        if !projection.activeExternalSections.isEmpty {
            priorityLabel("Active outside Clawdmeter")
            ForEach(projection.activeExternalSections) { section in
                externalRepoSection(section)
            }
        }
        if !projection.historySections.isEmpty {
            historyDivider
            historyToggle(repoCount: projection.historySections.count)
            if historyExpanded {
                ForEach(projection.historySections) { section in
                    historyRepoSection(section)
                }
            }
        }
    }

    /// v0.29.33: opt-in CTA shown under "Managed" when discovery is off.
    /// Tapping flips the shared `clawdmeter.code.discoverParallelSessions`
    /// key (RepoIndex reads it via ProviderEnablement) and refreshes, so the
    /// "Active outside Clawdmeter" / "History" sections populate from
    /// ~/.claude + ~/.codex exactly like the prior behavior. The folder /
    /// cross-app prompts then fire with clear user intent, not on launch.
    private var discoverSessionsButton: some View {
        Button(action: {
            discoverParallelSessions = true   // @AppStorage writes the shared key
            Task { await model.refresh() }
        }) {
            HStack(spacing: 8) {
                TahoeIcon("search", size: 11)
                    .foregroundStyle(t.accent)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Discover parallel sessions")
                        .font(TahoeFont.body(11.5, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text("Find Claude & Codex sessions outside your added repos")
                        .font(TahoeFont.body(9.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .buttonStyle(PressableButtonStyle())
        .help("Scan ~/.claude and ~/.codex for recent sessions. Folder/data access is requested only when you tap this.")
    }

    /// Collapsed-by-default "History" row. Looks like a sidebar item so
    /// it sits cleanly at the bottom of the list; tapping toggles the
    /// `historyExpanded` AppStorage which conditionally renders the
    /// historyRepoSection list above this row.
    private func historyToggle(repoCount: Int) -> some View {
        Button(action: {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                historyExpanded.toggle()
            }
        }) {
            HStack(spacing: 8) {
                TahoeIcon(historyExpanded ? "chevD" : "chevR", size: 10)
                    .foregroundStyle(t.fg3)
                    .frame(width: 10)
                Text("History")
                    .font(.system(size: 10, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !historyExpanded && repoCount > 0 {
                    Text("\(repoCount)")
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .foregroundStyle(t.fg3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(t.hair2, in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 3)
        }
        .buttonStyle(PressableButtonStyle())
        .help(historyExpanded ? "Hide older external sessions" : "Show older external sessions")
    }

    private func priorityLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private var historyDivider: some View {
        Rectangle()
            .fill(t.hairline)
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("No matching sessions")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Try a different search or status filter.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private func workspaceSection(_ section: SidebarWorkspaceSection) -> some View {
        let sectionID = "workspace:\(section.id)"
        let isExpanded = isPrioritySectionExpanded(sectionID)
        // v0.29.29: import-a-repo should be a clean slate. Earlier v0.29.28
        // rendered the repo's historical JSONLs underneath the workspace
        // header so users wouldn't lose access to past sessions; turns
        // out the user expects "import" to mean "start fresh here." Only
        // Clawdmeter-spawned `AgentSession` rows render under Managed
        // now. Historical JSONLs remain reachable from the History
        // section at the bottom of the sidebar when the user expands
        // it — but only when the repo is NOT workspace-managed
        // (managed repos skip the external/history split entirely so
        // their recents stay out of sight).
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(
                section.repo,
                isExpanded: isExpanded,
                sessionCount: section.sessions.count,
                subtitle: workspaceSubtitle(for: section.workspacePath),
                gearMenu: AnyView(workspaceGearMenu(section)),
                onAdd: {
                    // Persistently un-collapse so the new session stays visible
                    // after provisioning, then spawn a fresh worktree.
                    collapsedPrioritySectionIDs.remove(sectionID)
                    model.quickSpawnInRepo(section.repo.key)
                },
                onToggle: { togglePrioritySection(sectionID) }
            )
            .contextMenu { workspaceMenuItems(section) }
            if isExpanded {
                // Two levels only (Conductor parity): Repo → Worktree (branch).
                // A worktree is one leaf row; the model sessions running on it
                // (Claude → Codex handoff) live as TABS in the workspace, sorted
                // by age — NOT a third sidebar tier. Newest worktree first.
                ForEach(worktreeGroups(section.sessions), id: \.path) { wt in
                    worktreeRow(wt)
                }
            }
        }
    }

    /// One branch's worktree + the model sessions running on it.
    private struct WorktreeGroup: Identifiable {
        let path: String
        let branch: String
        let sessions: [AgentSession]
        var id: String { path }
    }

    /// Group a repo's sessions by their worktree (branch), newest-active first.
    private func worktreeGroups(_ sessions: [AgentSession]) -> [WorktreeGroup] {
        let grouped = Dictionary(grouping: sessions) { (s: AgentSession) -> String in
            WorkspaceKey.of(s)?.workspacePath ?? s.worktreePath ?? s.repoKey ?? s.id.uuidString
        }
        return grouped.map { path, ss in
            let last = (path as NSString).lastPathComponent
            return WorktreeGroup(
                path: path,
                branch: last.isEmpty ? path : last,
                sessions: ss.sorted { $0.createdAt < $1.createdAt }
            )
        }
        .sorted {
            ($0.sessions.map(\.lastEventAt).max() ?? .distantPast) > ($1.sessions.map(\.lastEventAt).max() ?? .distantPast)
        }
    }

    /// A single worktree (branch) leaf row. Clicking it opens the workspace at
    /// the most-recently-active model session; the worktree's other models show
    /// as tabs there (sorted by age). No third sidebar tier.
    @ViewBuilder
    private func worktreeRow(_ wt: WorktreeGroup) -> some View {
        let isOpen = wt.sessions.contains { $0.id == model.openSessionId }
        let provisioning = wt.sessions.contains { model.isProvisioning($0.id) }
        let isActive = wt.sessions.contains { $0.status == .running }
        Button {
            // openSession() keeps any in-progress draft alive (don't clear it).
            if let primary = wt.sessions.max(by: { $0.lastEventAt < $1.lastEventAt }) {
                model.openSession(primary)
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(wt.branch)
                        .font(TahoeFont.body(12.5, weight: .medium))
                        .foregroundStyle(t.fg)
                        .lineLimit(1).truncationMode(.middle)
                    Text(worktreeSubtitle(wt))
                        .font(TahoeFont.body(9.5))
                        .foregroundStyle(t.fg4)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if isActive {
                    StatusPulseDot(color: .green, isLive: true)
                        .help("AI session running in this worktree")
                } else if provisioning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                        .help("Setting up this worktree")
                }
                if wt.sessions.count > 1 {
                    Text("\(wt.sessions.count)")
                        .font(TahoeFont.body(9.5, weight: .semibold))
                        .foregroundStyle(t.fg3)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(t.hair2, in: Capsule())
                        .help("\(wt.sessions.count) models on this branch — open to switch via tabs")
                }
            }
            .padding(.leading, 48)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOpen ? t.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier("code.worktree.row")
        .padding(.horizontal, 10)
    }

    /// The models running on a worktree, oldest→newest (the handoff chain) with
    /// consecutive duplicates collapsed, e.g. "Claude · Codex".
    private func worktreeSubtitle(_ wt: WorktreeGroup) -> String {
        let names = wt.sessions
            .sorted { $0.createdAt < $1.createdAt }
            .map { AgentKindUI.displayName(for: $0.agent) }
        var chain: [String] = []
        for n in names where chain.last != n { chain.append(n) }
        return chain.isEmpty ? "Worktree" : chain.joined(separator: " · ")
    }

    // MARK: - Workspace management (gear / context menu)

    /// The persisted workspace record backing a sidebar repo, matched by
    /// canonical root (`repo.key` is `RepoIdentity.normalize(repoRoot)`).
    /// Nil for external / unmanaged repos.
    private func managedWorkspace(for repo: AgentRepo) -> CodeWorkspaceRecord? {
        model.workspaceStore.all().first { RepoIdentity.normalize($0.repoRoot) == repo.key }
    }

    /// Open the app's Settings window (Env Variables + every other setting
    /// live there). Standard AppKit action so we don't need cross-scene
    /// navigation plumbing from the sidebar.
    private func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @ViewBuilder
    private func workspaceMenuItems(_ section: SidebarWorkspaceSection) -> some View {
        Button { model.quickSpawnInRepo(section.repo.key) } label: {
            Label("New session here", systemImage: "plus")
        }
        if !section.sessions.isEmpty {
            Button {
                let ids = section.sessions.map(\.id)
                Task { for id in ids { try? await model.registry.archive(id: id) } }
            } label: {
                Label("Archive all sessions (\(section.sessions.count))", systemImage: "archivebox")
            }
        }
        // Archive the WHOLE repo in one go: archive every session across all its
        // worktrees AND drop it from the Managed list, so the row disappears
        // entirely (sessions stay recoverable under the Archived filter).
        Button(role: .destructive) {
            let ids = section.sessions.map(\.id)
            let workspaceId = managedWorkspace(for: section.repo)?.id
            Task {
                for id in ids { try? await model.registry.archive(id: id) }
                if let workspaceId { _ = model.workspaceStore.delete(id: workspaceId) }
            }
        } label: {
            Label("Archive entire repo", systemImage: "archivebox.fill")
        }
        Divider()
        Button { openSettingsWindow() } label: {
            Label("Settings & Env Variables…", systemImage: "gearshape")
        }
        if let ws = managedWorkspace(for: section.repo) {
            Divider()
            Button(role: .destructive) {
                _ = model.workspaceStore.delete(id: ws.id)
            } label: {
                Label("Remove “\(section.repo.displayName)” from list", systemImage: "trash")
            }
        }
    }

    /// Trailing gear button in a managed workspace header. Opens the same
    /// actions as the row's right-click menu (Archive, Settings/Env, Remove).
    private func workspaceGearMenu(_ section: SidebarWorkspaceSection) -> some View {
        Menu {
            workspaceMenuItems(section)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(t.fg3)
                .frame(width: 22, height: 22)
                .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Workspace settings — archive, env variables, remove")
    }

    private func externalRepoSection(_ section: SidebarExternalRepoSection) -> some View {
        let sectionID = "external:\(section.repo.key)"
        let isExpanded = isPrioritySectionExpanded(sectionID)
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(
                section.repo,
                isExpanded: isExpanded,
                sessionCount: section.recents.count,
                subtitle: "Active in the last 5 min",
                onToggle: { togglePrioritySection(sectionID) }
            )
            if isExpanded {
                ForEach(section.recents) { recent in
                    externalRecentButton(recent, repo: section.repo)
                }
            }
        }
    }

    private func historyRepoSection(_ section: SidebarHistoryRepoSection) -> some View {
        let sectionID = "history:\(section.repo.key)"
        let isExpanded = isPrioritySectionExpanded(sectionID)
        let count = section.dateGroups.reduce(0) { $0 + $1.recents.count }
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(
                section.repo,
                isExpanded: isExpanded,
                sessionCount: count,
                subtitle: "Older external sessions",
                onToggle: { togglePrioritySection(sectionID) }
            )
            if isExpanded {
                ForEach(section.dateGroups) { dateGroup in
                    Text(dateGroup.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 28)
                        .padding(.top, 5)
                    ForEach(dateGroup.recents) { recent in
                        externalRecentButton(recent, repo: section.repo)
                    }
                }
            }
        }
    }

    private func externalRecentButton(_ recent: RecentSession, repo: AgentRepo) -> some View {
        Button(action: {
            model.openOutsideSession(
                recent: recent,
                repoKey: repo.key,
                repoDisplayName: repo.displayName
            )
        }) {
            recentSessionRow(recent, isOpen: model.openOutsideJSONLPath == recent.path, repo: repo)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func isPrioritySectionExpanded(_ id: String) -> Bool {
        !collapsedPrioritySectionIDs.contains(id)
    }

    private func togglePrioritySection(_ id: String) {
        if collapsedPrioritySectionIDs.contains(id) {
            collapsedPrioritySectionIDs.remove(id)
        } else {
            collapsedPrioritySectionIDs.insert(id)
        }
    }

    /// Managed rows now represent a whole repo (all its worktrees nested), so
    /// the subtitle is the repo's path (home-abbreviated) — informative and it
    /// disambiguates same-named repos in different locations.
    private func workspaceSubtitle(for repoPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if repoPath == home { return "~" }
        if repoPath.hasPrefix(home + "/") { return "~" + repoPath.dropFirst(home.count) }
        return repoPath
    }

    /// Pin-aware sort used by the legacy repo-grouped path's per-repo
    /// `repoSection(...)` lookups. The non-repo path receives this sort
    /// already applied via `currentProjection.visibleSessions`, but the
    /// repo path looks up sessions per-repo from the registry and needs
    /// to re-apply the same ordering locally.
    private func presentationSorted(_ sessions: [AgentSession]) -> [AgentSession] {
        let pins = presentationStore.snapshot.pinnedSessionIds
        return sessions.sorted { lhs, rhs in
            let lhsPin = pins.firstIndex(of: lhs.id)
            let rhsPin = pins.firstIndex(of: rhs.id)
            switch (lhsPin, rhsPin) {
            case let (l?, r?):
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.lastEventAt > rhs.lastEventAt
            }
        }
    }

    /// Generic group renderer for non-Repo groupings. Header is a plain
    /// label (no expand toggle — flatter taxonomy than repos). Session
    /// rows reuse `sessionRow`; recent rows reuse `recentSessionRow`.
    @ViewBuilder
    private func groupSection(_ group: SessionSidebarGroup) -> some View {
        if group.id.hasPrefix("status:") {
            DisclosureGroup(isExpanded: statusGroupExpandedBinding(group.id)) {
                groupRows(group)
            } label: {
                statusGroupHeader(group)
            }
            .disclosureGroupStyle(QuietDisclosure())
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                plainGroupHeader(group)
                groupRows(group)
            }
        }
    }

    private func statusGroupExpandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedStatusGroupIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedStatusGroupIDs.remove(id)
                } else {
                    collapsedStatusGroupIDs.insert(id)
                }
            }
        )
    }

    private func plainGroupHeader(_ group: SessionSidebarGroup) -> some View {
        HStack(spacing: 6) {
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            let count = group.sessions.count + group.recents.count
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func statusGroupHeader(_ group: SessionSidebarGroup) -> some View {
        let count = group.sessions.count + group.recents.count
        return HStack(spacing: 6) {
            StatusPulseDot(
                color: statusGroupTint(group),
                isLive: group.id == "status:active" && count > 0
            )
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(count == 0 ? .tertiary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(count == 0 ? 0.06 : 0.12), in: Capsule())
        }
        .contentShape(Rectangle())
    }

    private func statusGroupTint(_ group: SessionSidebarGroup) -> Color {
        switch group.id {
        case "status:active": return .green
        case "status:inReview": return .orange
        case "status:done": return terraCotta
        case "status:archived": return .secondary
        default: return .secondary
        }
    }

    @ViewBuilder
    private func groupRows(_ group: SessionSidebarGroup) -> some View {
        ForEach(group.sessions) { s in
            sessionRow(s, isOpen: model.openSessionId == s.id, depth: 0)
        }
        ForEach(group.recents) { recent in
            Button(action: {
                // Resolve the repo display name from the recent's path.
                let repo = model.repos.first(where: { $0.recentSessions.contains(recent) })
                model.openOutsideSession(
                    recent: recent,
                    repoKey: repo?.key ?? recent.path,
                    repoDisplayName: repo?.displayName ?? "Recent"
                )
            }) {
                // Non-Repo grouping (Date / Status / Agent / None):
                // no repo section header above this row, so surface
                // the repo as an inline chip in the subtitle.
                recentSessionRow(
                    recent,
                    isOpen: model.openOutsideJSONLPath == recent.path,
                    repo: model.repos.first(where: { $0.recentSessions.contains(recent) })
                        ?? AgentRepo(key: recent.path, displayName: "Recent", hasActiveSessions: false),
                    showRepoChip: true
                )
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    private func repoSection(_ repo: AgentRepo, keyAliases: [String: String] = [:]) -> some View {
        let allSessions = model.registry.sessions.filter { session in
            guard let key = session.repoKey else { return false }
            guard (keyAliases[key] ?? key) == repo.key else { return false }
            if !model.showArchived, session.archivedAt != nil { return false }
            return true
        }
        let visibleSessions = presentationSorted(model.filter(sessions: allSessions).filter(sidebarStatusPasses))
        let rootSessions = visibleSessions.filter { $0.parentSessionId == nil }
        let isExpanded = model.expandedRepoKeys.contains(repo.key)
        let recentSessions = repo.recentSessions
        return VStack(alignment: .leading, spacing: 0) {
            repoHeader(repo, isExpanded: isExpanded, sessionCount: visibleSessions.count + recentSessions.count)
            if isExpanded {
                ForEach(rootSessions) { root in
                    sessionTree(root: root, depth: 0)
                }
                if !recentSessions.isEmpty {
                    Text("Recent (last 30 days)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 24)
                        .padding(.top, 4)
                    ForEach(recentSessions) { recent in
                        Button(action: {
                            model.openOutsideSession(
                                recent: recent,
                                repoKey: repo.key,
                                repoDisplayName: repo.displayName
                            )
                        }) {
                            recentSessionRow(recent, isOpen: model.openOutsideJSONLPath == recent.path, repo: repo)
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                if visibleSessions.isEmpty && recentSessions.isEmpty {
                    Button(action: {
                        model.quickSpawnInRepo(repo.key)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.secondary)
                            Text("Start a session here")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
    }

    private func sidebarStatusPasses(_ session: AgentSession) -> Bool {
        switch statusFilter {
        case .all:
            return true
        case .active:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds) == .active
        case .inReview:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds) == .inReview
        case .done:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds) == .done
        case .archived:
            return SessionSidebarGrouper.bucket(for: session, reviewSessionIds: reviewSessionIds) == .archived
        }
    }

    /// One row per JSONL surfaced from `repo.recentSessions` — these were
    /// not spawned by Clawdmeter (Conductor / Cursor / Terminal). Click
    /// opens the JSONL transcript read-only. v0.4.6: matches the iOS row
    /// treatment — provider badge on the leading edge, color-tinted
    /// provider name in the subtitle, optional repo chip (for the
    /// non-Repo groupings where the row has no repo section header
    /// above it), green ring around the badge when the JSONL was
    /// touched in the last 5 minutes.
    private func recentSessionRow(_ recent: RecentSession, isOpen: Bool, repo: AgentRepo, showRepoChip: Bool = false) -> some View {
        let isHovered = hoveredRecentPath == recent.path
        return HStack(alignment: .top, spacing: 8) {
            providerBadge(for: recent)
            VStack(alignment: .leading, spacing: 2) {
                Text(recentTitle(recent))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                recentSubtitleRow(recent: recent, repo: repo, showRepoChip: showRepoChip)
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .background(
            isOpen
                ? terraCotta.opacity(0.15)
                : (isHovered ? t.hair2.opacity(colorScheme == .dark ? 1.0 : 1.35) : Color.clear),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(isOpen ? terraCotta.opacity(0.35) : (isHovered ? t.hairline : .clear), lineWidth: 0.5)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredRecentPath = recent.path
            } else if hoveredRecentPath == recent.path {
                hoveredRecentPath = nil
            }
        }
        .help(recent.path)
        .contextMenu {
            Button("Open read-only", systemImage: "doc.text") {
                model.openOutsideSession(recent: recent, repoKey: repo.key, repoDisplayName: repo.displayName)
            }
            Button("Rename…", systemImage: "pencil") {
                renameJSONLTarget = recent
                renameJSONLInput = recent.customName ?? ""
                showingRenameJSONLAlert = true
            }
        }
    }

    /// 20pt circular provider badge with a tinted background, the
    /// shared `ProviderBadgeImage` glyph, and a green ring overlay when
    /// the JSONL is currently active.
    @ViewBuilder
    private func providerBadge(for recent: RecentSession) -> some View {
        let isLive = isRecentLive(recent)
        let rgb = AgentKindUI.accentRGB(for: recent.provider)
        let accent = Color(red: Double(rgb.r)/255, green: Double(rgb.g)/255, blue: Double(rgb.b)/255)
        ZStack {
            Circle()
                .fill(recent.provider == .claude
                      ? accent.opacity(0.18)
                      : Color.secondary.opacity(0.20))
                .frame(width: 20, height: 20)
            ProviderBadgeImage(
                assetName: AgentKindUI.assetName(for: recent.provider),
                isTemplate: AgentKindUI.isTemplate(for: recent.provider),
                size: 12
            )
            .foregroundStyle(recent.provider == .claude ? accent : .primary)
            if isLive {
                Circle()
                    .stroke(Color.green, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
            }
        }
    }

    /// Subtitle: color-tinted provider name · optional repo chip ·
    /// relative time · green `Now` capsule when live. Drops the
    /// `read-only` suffix that used to live here.
    @ViewBuilder
    private func recentSubtitleRow(recent: RecentSession, repo: AgentRepo, showRepoChip: Bool) -> some View {
        let providerName = AgentKindUI.displayName(for: recent.provider)
        let rgb = AgentKindUI.accentRGB(for: recent.provider)
        let providerColor: Color = recent.provider == .claude
            ? terraCotta
            : Color(red: Double(rgb.r)/255, green: Double(rgb.g)/255, blue: Double(rgb.b)/255)
        let rel = Self.relativeTimestampFormatter.localizedString(
            for: recent.lastModified, relativeTo: Date()
        )
        HStack(spacing: 4) {
            Text(providerName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(providerColor)
            if showRepoChip {
                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                HStack(spacing: 2) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text(repo.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
            Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(rel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if isRecentLive(recent) {
                Text("Now")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.16), in: Capsule())
            }
        }
        .lineLimit(1)
    }

    private func isRecentLive(_ recent: RecentSession) -> Bool {
        Date().timeIntervalSince(recent.lastModified) < 5 * 60
    }

    private func recentTitle(_ recent: RecentSession) -> String {
        // v0.5.10 — user-supplied alias wins. Always.
        if let custom = recent.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        // Prefer the first user prompt — that's what the session was for.
        // Fall back to the generic label when we couldn't extract one
        // (empty JSONL, unparseable, all system meta).
        if let prompt = recent.firstPrompt, !prompt.isEmpty {
            return prompt
        }
        return "\(AgentKindUI.displayName(for: recent.provider)) session"
    }

    private static let relativeTimestampFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// G17: render a session row + its children indented underneath.
    /// Iterative (not recursive) so SwiftUI's opaque return type doesn't
    /// hit the self-defining-`some View` ban.
    private func sessionTree(root: AgentSession, depth: Int) -> some View {
        // Flatten the subtree depth-first into (session, depth) pairs.
        var flat: [(AgentSession, Int)] = []
        var stack: [(AgentSession, Int)] = [(root, depth)]
        var seen: Set<UUID> = []
        while let (s, d) = stack.popLast() {
            guard !seen.contains(s.id) else { continue }
            seen.insert(s.id)
            flat.append((s, d))
            // Push children in reverse so the leftmost child ends up first.
            for child in model.children(of: s.id).reversed() {
                stack.append((child, d + 1))
            }
        }
        return ForEach(Array(flat.enumerated()), id: \.element.0.id) { _, pair in
            let (s, d) = pair
            sessionRow(s, isOpen: model.openSessionId == s.id, depth: d)
        }
    }

    private func repoHeader(
        _ repo: AgentRepo,
        isExpanded: Bool,
        sessionCount: Int,
        subtitle: String? = nil,
        gearMenu: AnyView? = nil,
        onAdd: (() -> Void)? = nil,
        onToggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    TahoeIcon(isExpanded ? "chevD" : "chevR", size: 10)
                        .foregroundStyle(t.fg3)
                        .frame(width: 10)
                    projectGlyph(repo)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repo.displayName)
                            .font(TahoeFont.body(13, weight: .semibold))
                            .foregroundStyle(t.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(TahoeFont.body(10))
                                .foregroundStyle(t.fg3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())

            Spacer()

            if sessionCount > 0 {
                Text("\(sessionCount)")
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.fg3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(t.hair2, in: Capsule())
            }
            if repo.liveSessionCount > 0 {
                HStack(spacing: 2) {
                    Circle().fill(.green).frame(width: 4, height: 4)
                    Text("\(repo.liveSessionCount)")
                        .font(TahoeFont.body(9, weight: .bold))
                        .foregroundStyle(.green)
                }
                .help("\(repo.liveSessionCount) live JSONL — Conductor / Cursor / Terminal-launched agents writing now.")
            }
            if let gearMenu {
                gearMenu
            }
            Button {
                if let onAdd { onAdd() } else { model.quickSpawnInRepo(repo.key) }
            } label: {
                TahoeIcon("plus", size: 11, weight: .bold)
                    .foregroundStyle(t.fg3)
                    .frame(width: 22, height: 22)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .help("New workspace — Codex · gpt-5.5 · max effort · plan mode (option-click to customize)")
            // Option/Alt-click escape hatch: power users who want to
            // pick a different agent/model/effort/path get the full
            // sheet by holding Option while clicking the "+".
            .simultaneousGesture(TapGesture().modifiers(.option).onEnded {
                model.prepareNewSession(in: repo.key)
            })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, subtitle == nil ? 6 : 5)
    }

    private func repoHeader(_ repo: AgentRepo, isExpanded: Bool, sessionCount: Int) -> some View {
        repoHeader(
            repo,
            isExpanded: isExpanded,
            sessionCount: sessionCount,
            onToggle: {
                if isExpanded { model.expandedRepoKeys.remove(repo.key) }
                else { model.expandedRepoKeys.insert(repo.key) }
            }
        )
    }

    private func projectGlyph(_ repo: AgentRepo) -> some View {
        let hueSeed = repo.key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let hue = Double(hueSeed % 360) / 360.0
        let tint = Color(hue: hue, saturation: 0.52, brightness: colorScheme == .dark ? 0.86 : 0.78)
        let initial = repo.displayName.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)?.uppercased() ?? "*"
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(colorScheme == .dark ? 0.28 : 0.20))
            .overlay(
                Text(initial)
                    .font(TahoeFont.body(10, weight: .bold))
                    .foregroundStyle(tint)
            )
            .frame(width: 22, height: 22)
    }

    private func sessionRow(_ session: AgentSession, isOpen: Bool, depth: Int = 0) -> some View {
        let isHovered = hoveredSessionId == session.id
        let isPinned = presentationStore.snapshot.pinnedSessionIds.contains(session.id)
        let isUnread = presentationStore.snapshot.unreadSessionIds.contains(session.id)
        let isMuted = presentationStore.snapshot.mutedSessionIds.contains(session.id)
        let tag = presentationStore.snapshot.colorTags[session.id]
        let reasons = attentionReasons(for: session)
        let repoBadge = repoIdentityBadge(for: session)
        return Button(action: {
            model.openSession(session)
            try? presentationStore.markUnread(session.id, unread: false)
        }) {
            HStack(alignment: .top, spacing: 8) {
                if depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(depth - 1) * 12)
                }
                RepoIdentityBadgeView(badge: repoBadge, size: 22)
                    .overlay(alignment: .bottomTrailing) {
                        TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 11)
                            .padding(2)
                            .background(ContinuumTokens.surface2, in: Circle())
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(statusColor(session.status))
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: 3)
                            .shadow(color: session.status == .running ? statusColor(session.status).opacity(0.75) : .clear, radius: 4)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionTitle(session))
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor(session.status))
                            .frame(width: 5, height: 5)
                        Text(sessionSubtitle(session))
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                        if let tag, !tag.isEmpty {
                            Text(tag)
                                .font(TahoeFont.body(9.5, weight: .semibold))
                                .foregroundStyle(colorTagTint(tag))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(colorTagTint(tag).opacity(0.14), in: Capsule())
                        }
                    }
                    // Daemon-computed "progress vs approved plan" bar.
                    // Appears only when the session has an approved plan
                    // AND the daemon has produced its first compute (see
                    // `PlanProgressTracker`). The fraction comes straight
                    // from the wire field, so iOS and Mac sidebars agree.
                    //
                    // Uses `TahoePillBar` (not native ProgressView) so the
                    // bar inherits provider-tinted gradient + halo shadow
                    // and matches the rest of the Tahoe bar fleet.
                    // Font and 32pt min-width on the count match the row's
                    // subtitle typography so the bar doesn't break density.
                    if let progress = session.planProgress {
                        // Defensive clamp: the daemon enforces completed ≤ total,
                        // but a future schema bump or a race could violate it. We
                        // clamp here rather than render "7/6" to the sidebar.
                        let safeCompleted = max(0, min(progress.completed, progress.total))
                        let isComplete = safeCompleted >= progress.total && progress.total > 0
                        let provider = session.agent.tahoeProvider
                        // Use provider.halo (the same color the bar gradient
                        // anchors on) so the milestone state stays inside the
                        // bar's two-color vocabulary and reads correctly in
                        // dark mode (provider.deep collapses to near-black for
                        // Codex/Cursor, which is invisible against dark popovers).
                        let completeTint = provider.dot
                        HStack(spacing: 6) {
                            TahoePillBar(
                                percent: Double(safeCompleted) /
                                          max(1, Double(progress.total)) * 100,
                                provider: provider,
                                height: 6
                            )
                            .frame(maxWidth: .infinity)
                            if isComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(completeTint)
                                    .padding(.leading, 2)
                                    .transition(.scale.combined(with: .opacity))
                                    .accessibilityHidden(true)
                            }
                            Text("\(safeCompleted)/\(progress.total)")
                                .font(TahoeFont.body(10.5, weight: isComplete ? .bold : .semibold))
                                .monospacedDigit()
                                .foregroundStyle(isComplete ? completeTint : t.fg2)
                                .frame(minWidth: 44, alignment: .trailing)
                                .contentTransition(reduceMotion ? .identity : .numericText())
                        }
                        .padding(.top, 4)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: isComplete)
                        .help(isComplete
                              ? "Plan complete — \(safeCompleted) of \(progress.total) steps"
                              : "Plan progress — \(safeCompleted) of \(progress.total) steps complete")
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Plan progress")
                        .accessibilityValue("\(safeCompleted) of \(progress.total) steps complete")
                        .accessibilityHint(isComplete ? "Plan complete" : "")
                    }
                }
                Spacer()
                if isHovered {
                    SessionHoverActions(
                        onArchive: {
                            // F2-wire: registry mutation is now async
                            // throws. SwiftUI button closures are sync,
                            // so wrap in Task. Best-effort — failures
                            // surface as a missed archive (the row
                            // stays in the sidebar; user can retry).
                            Task { @MainActor in
                                try? await model.registry.archive(id: session.id)
                            }
                            postArchiveUndoToast(for: session)
                        }
                    )
                }
                if isUnread {
                    Circle()
                        .fill(t.accent)
                        .frame(width: 7, height: 7)
                        .help("Unread")
                        .accessibilityLabel("Unread")
                }
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(t.accent)
                        .help("Pinned")
                        .accessibilityLabel("Pinned")
                }
                if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("Muted")
                        .accessibilityLabel("Muted")
                }
                // Plan-status doc badges removed from the row per design — the
                // orange "plan ready" doc was the `.planReady` attention badge;
                // other attention reasons (PR, checks failed, input needed) stay.
                ForEach(reasons.filter { $0 != .planReady }.prefix(2), id: \.self) { reason in
                    AttentionBadge(reason: reason)
                }
                if session.archivedAt != nil {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("Archived")
                        .accessibilityLabel("Archived")
                }
                // (Red "plan approval pending" doc removed from the row per
                // design; the plan + its Approve action live in the session.)
                if model.chatStore(for: session)?.pendingPermissionPrompt != nil {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("User input required")
                        .accessibilityLabel("User input required")
                }
                let queued = workbenchState.queuedSendCount(for: session.id)
                if queued > 0 {
                    Text("\(queued)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(terraCotta, in: Capsule())
                        .help("\(queued) queued follow-up\(queued == 1 ? "" : "s")")
                }
            }
            .padding(.leading, 24 + CGFloat(depth) * 6)
            .padding(.trailing, 24)
            .padding(.vertical, 7)
            .background(isOpen
                ? t.accentAlpha(colorScheme == .dark ? 0.18 : 0.12)
                : (isHovered ? t.hair2.opacity(colorScheme == .dark ? 1.0 : 1.35) : Color.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isOpen ? t.accentAlpha(0.35) : (isHovered ? t.hairline : .clear), lineWidth: 0.5)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier("code.session.row")
        .onHover { inside in
            if inside {
                hoveredSessionId = session.id
            } else if hoveredSessionId == session.id {
                hoveredSessionId = nil
            }
        }
        .opacity(session.archivedAt != nil ? 0.6 : 1.0)
        .animation(.easeOut(duration: 0.18), value: session.status)
        .help(hoverHelp(for: session, reasons: reasons))
        .contextMenu {
            sessionContextMenu(session)
        }
        .onAppear {
            resolveRepoIdentityIfNeeded(for: session)
        }
    }

    private func repoIdentityBadge(for session: AgentSession) -> RepoIdentityBadge {
        let key = repoIdentityKey(for: session)
        if let cached = presentationStore.snapshot.repoIdentityBadges[key] {
            return cached
        }
        return RepoIdentityResolver.badge(repoKey: key, displayName: session.repoDisplayName)
    }

    private func repoIdentityKey(for session: AgentSession) -> String {
        session.repoKey ?? session.runtimeCwd ?? session.worktreePath ?? session.repoDisplayName
    }

    private func resolveRepoIdentityIfNeeded(for session: AgentSession) {
        let key = repoIdentityKey(for: session)
        guard presentationStore.snapshot.repoIdentityBadges[key]?.remoteSlug == nil else { return }
        guard !requestedRepoIdentityKeys.contains(key) else { return }
        requestedRepoIdentityKeys.insert(key)

        let displayName = session.repoDisplayName
        let candidateRoots = remoteOriginCandidateRoots(for: session)
        let store = presentationStore
        Task.detached(priority: .utility) {
            guard let remoteURL = Self.gitRemoteOriginURL(candidateRoots: candidateRoots) else { return }
            let badge = RepoIdentityResolver.badge(
                repoKey: key,
                displayName: displayName,
                remoteURL: remoteURL
            )
            await MainActor.run {
                try? store.cacheRepoIdentity(badge)
            }
        }
    }

    private func remoteOriginCandidateRoots(for session: AgentSession) -> [String] {
        var roots: [String] = []
        var seen = Set<String>()
        for raw in [session.effectiveCwd, session.worktreePath, session.runtimeCwd, session.repoKey] {
            guard let root = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else { continue }
            let expanded = NSString(string: root).expandingTildeInPath
            guard !seen.contains(expanded) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            seen.insert(expanded)
            roots.append(expanded)
        }
        return roots
    }

    private nonisolated static func gitRemoteOriginURL(candidateRoots: [String]) -> String? {
        for repoRoot in candidateRoots {
            if let remote = gitRemoteOriginURL(repoRoot: repoRoot) {
                return remote
            }
        }
        return nil
    }

    private nonisolated static func gitRemoteOriginURL(repoRoot: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", NSString(string: repoRoot).expandingTildeInPath, "config", "--get", "remote.origin.url"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        } catch {
            return nil
        }
    }

    @ViewBuilder
    private func sessionContextMenu(_ session: AgentSession) -> some View {
        let isPinned = presentationStore.snapshot.pinnedSessionIds.contains(session.id)
        let isUnread = presentationStore.snapshot.unreadSessionIds.contains(session.id)
        let isMuted = presentationStore.snapshot.mutedSessionIds.contains(session.id)
        if session.status == .degraded {
            Button("Revive session", systemImage: "arrow.clockwise.circle") {
                Task { @MainActor in await model.revive(sessionId: session.id) }
            }
            Divider()
        }
        Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin.fill") {
            try? presentationStore.togglePin(session.id)
        }
        if isPinned {
            Button("Move Pin Up", systemImage: "arrow.up") {
                try? presentationStore.movePinnedSession(session.id, offset: -1)
            }
            Button("Move Pin Down", systemImage: "arrow.down") {
                try? presentationStore.movePinnedSession(session.id, offset: 1)
            }
        }
        Button(isUnread ? "Mark Read" : "Mark Unread", systemImage: isUnread ? "circle" : "circle.fill") {
            try? presentationStore.markUnread(session.id, unread: !isUnread)
        }
        Button(isMuted ? "Unmute Session" : "Mute Session", systemImage: isMuted ? "bell" : "bell.slash") {
            try? presentationStore.setMuted(session.id, muted: !isMuted)
        }
        Menu("Snooze", systemImage: "moon.zzz") {
            Button("1 hour") { try? presentationStore.snooze(session.id, until: Date().addingTimeInterval(60 * 60)) }
            Button("Today") { try? presentationStore.snooze(session.id, until: Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)) }
            Button("Clear Snooze") { try? presentationStore.snooze(session.id, until: nil) }
        }
        Button("Color Tag…", systemImage: "tag") {
            colorTagTarget = session
            colorTagInput = presentationStore.snapshot.colorTags[session.id] ?? ""
            showingColorTagAlert = true
        }
        Divider()
        Button("Pop out", systemImage: "rectangle.portrait.on.rectangle.portrait") {
            NotificationCenter.default.post(
                name: .popOutSession,
                object: nil,
                userInfo: ["sessionId": session.id]
            )
        }
        Button("Compare with Open Session", systemImage: "rectangle.split.2x1") {
            if let open = model.openSession, open.id != session.id {
                comparisonPair = SessionComparisonPair(left: open, right: session)
            }
        }
        .disabled(model.openSession == nil || model.openSession?.id == session.id)
        Button("Copy session ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.id.uuidString, forType: .string)
        }
        Button("Reveal JSONL in Finder", systemImage: "doc.text.magnifyingglass") {
            if let url = model.chatStore(for: session)?.currentFileURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .disabled(model.chatStore(for: session)?.currentFileURL == nil)
        if let raw = session.prMirrorState?.prURL, let url = URL(string: raw) {
            Button("Open Pull Request", systemImage: "arrow.up.right.square") {
                NSWorkspace.shared.open(url)
            }
        }
        Divider()
        Button("Rename…", systemImage: "pencil") {
            renameTarget = session
            renameInput = session.customName ?? presentationStore.snapshot.titleOverrides[session.id] ?? ""
            showingRenameAlert = true
        }
        if session.archivedAt == nil {
            Button("Archive", systemImage: "archivebox") {
                Task { @MainActor in
                    try? await model.registry.archive(id: session.id)
                }
                postArchiveUndoToast(for: session)
            }
        } else {
            Button("Unarchive", systemImage: "archivebox.fill") {
                Task { @MainActor in
                    try? await model.registry.unarchive(id: session.id)
                }
            }
        }
        Button("New sub-chat (⌘;)", systemImage: "bubble.left.and.bubble.right") {
            Task { _ = await model.spawnSubchat(parentId: session.id) }
        }
        Divider()
        Button("End session", role: .destructive) {
            Task { await model.endSession(id: session.id) }
        }
    }

    private func attentionReasons(for session: AgentSession) -> [AttentionReason] {
        AttentionReasonResolver.reasons(
            for: session,
            unread: presentationStore.snapshot.unreadSessionIds.contains(session.id),
            outboxPending: workbenchState.queuedSendCount(for: session.id) > 0,
            providerBlocked: model.chatStore(for: session)?.pendingPermissionPrompt != nil,
            snoozedUntil: presentationStore.snapshot.snoozedUntil[session.id]
        )
    }

    private func hoverHelp(for session: AgentSession, reasons: [AttentionReason]) -> String {
        var rows = [
            sessionTitle(session),
            "\(session.repoDisplayName) · \(session.agent.rawValue.capitalized) · \(session.status.rawValue)",
            "Updated \(session.lastEventAt.formatted(date: .abbreviated, time: .shortened))"
        ]
        if !reasons.isEmpty {
            rows.append("Attention: \(reasons.map(\.label).joined(separator: ", "))")
        }
        if let tag = presentationStore.snapshot.colorTags[session.id], !tag.isEmpty {
            rows.append("Tag: \(tag)")
        }
        return rows.joined(separator: "\n")
    }

    private func colorTagTint(_ tag: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, terraCotta]
        let seed = tag.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) }
        return palette[abs(seed) % palette.count]
    }

    private func sessionTitle(_ session: AgentSession) -> String {
        if let custom = session.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let title = presentationStore.snapshot.titleOverrides[session.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let goal = Self.cleanSidebarTitle(session.goal) { return goal }
        if let branch = branchLikeTitle(for: session) { return branch }
        if let summary = latestAssistantSummary(for: session) { return summary }
        return "\(session.agent.rawValue.capitalized) · \(session.status.rawValue)"
    }

    private func commitSessionRename(_ session: AgentSession, name: String?) {
        let sessionID = session.id
        Task { @MainActor in
            _ = await model.renameSession(id: sessionID, name: name)
            // Older builds wrote Rename into the client-local presentation store.
            // Clear that shadow value so the registry-backed customName drives all
            // surfaces after this edit.
            if presentationStore.snapshot.titleOverrides[sessionID] != nil {
                try? presentationStore.setTitleOverride(sessionID, title: nil)
            }
            resetSessionRenameState()
        }
    }

    private func resetSessionRenameState() {
        showingRenameAlert = false
        renameTarget = nil
        renameInput = ""
    }

    private func latestAssistantSummary(for session: AgentSession) -> String? {
        guard let store = model.chatStore(for: session) else { return nil }
        for message in store.snapshot.messages.reversed() where message.kind == .assistantText {
            if let title = Self.cleanSidebarTitle(message.body) {
                return title
            }
        }
        return nil
    }

    private func branchLikeTitle(for session: AgentSession) -> String? {
        for raw in [session.worktreePath, session.runtimeCwd] {
            guard let raw, let title = Self.branchLikeTitle(fromPath: raw, repoDisplayName: session.repoDisplayName) else {
                continue
            }
            return title
        }
        return nil
    }

    private static func branchLikeTitle(fromPath path: String, repoDisplayName: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !last.isEmpty, last != "/", last != repoDisplayName else { return nil }
        let lower = last.lowercased()
        if path.contains("/.claude/worktrees/") || path.contains("/.git/worktrees/") {
            return last
        }
        if lower.contains("-") || lower.contains("_") || lower.contains("/") {
            return last
        }
        return nil
    }

    private static func cleanSidebarTitle(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if let citationRange = text.range(of: "<oai-mem-citation>") {
            text.removeSubrange(citationRange.lowerBound..<text.endIndex)
        }
        text = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'")))
        guard !text.isEmpty else { return nil }
        if text.count > 96 {
            let idx = text.index(text.startIndex, offsetBy: 96)
            text = String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }

    private func sessionSubtitle(_ session: AgentSession) -> String {
        var bits: [String] = []
        bits.append(session.agent.rawValue.capitalized)
        bits.append(session.mode.rawValue.capitalized)
        bits.append(session.status.rawValue)
        return bits.joined(separator: " · ")
    }

    private func statusColor(_ status: AgentSessionStatus) -> Color {
        switch status {
        case .planning: return .gray
        case .running: return .green
        case .paused: return .yellow
        case .done: return terraCotta
        // DESIGN.md Session Status: degraded → #ff5f57 (danger), not a muted gray.
        case .degraded: return Color(.sRGB, red: 1.0, green: 95.0 / 255.0, blue: 87.0 / 255.0, opacity: 1.0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No repos yet")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Run Claude / Codex in a repo and it'll appear here.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        Button(action: { model.prepareNewSession(in: nil) }) {
            HStack(spacing: 6) {
                TahoeIcon("plus", size: 12, weight: .bold)
                Text("New session")
                    .font(TahoeFont.body(12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom),
                in: Capsule(style: .continuous)
            )
            .overlay(Capsule(style: .continuous).stroke(t.accentDeepC, lineWidth: 0.5))
            .shadow(color: t.accentDeep.color(opacity: 0.25), radius: 8, x: 0, y: 5)
            .foregroundStyle(.white)
        }
        .buttonStyle(PressableButtonStyle())
        .keyboardShortcut("n", modifiers: [.command])
        .padding(10)
    }

    private var sidebarBg: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.94, green: 0.94, blue: 0.94)
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}
