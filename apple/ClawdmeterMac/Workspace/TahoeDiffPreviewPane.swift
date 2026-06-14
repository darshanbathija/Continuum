import SwiftUI
import AppKit
import ClawdmeterShared

struct TahoeDiffPreviewPane: View {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sessionId: UUID
    let repoCwd: String
    @ObservedObject var presentationStore: SessionPresentationStore
    @State private var lines: [DiffLine] = []
    // A12 — derived indices built once per `load()` so the hover summary
    // (diffSummary), mark-all-viewed (contentHash), file-list (changedPaths),
    // and intra-line highlighting (nearestOppositeLine) read O(1)/bounded
    // lookups instead of re-scanning the whole `lines` array per file/row.
    @State private var index = DiffIndex()
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var refreshQueued = false
    @State private var autoRefreshTask: Task<Void, Never>?
    @State private var focusedPath: String?
    @State private var hoveredPath: String?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                diffToolbar(proxy: proxy)
                TahoeHairline()
                ScrollView([.vertical, .horizontal]) {
                    // A12 — virtualized rows. LazyVStack only materializes
                    // rows in view, so 50k-line diffs no longer force
                    // SwiftUI to lay out every line up front. Critical
                    // for the <500ms acceptance budget.
                    LazyVStack(alignment: .leading, spacing: 0) {
                    if isLoading {
                        // P8: a diff-shaped shimmer reads as "filling in" rather
                        // than the bare spinner+"Loading diff..." that looked stalled.
                        SkeletonLines(count: 7, label: "Loading diff…")
                            .padding(16)
                    } else if lines.isEmpty {
                        TahoeEmptyReviewState(icon: "diff", title: "No local diff", body: "The worktree has no visible git diff.")
                            .frame(minWidth: 330)
                            .padding(16)
                    } else {
                        ForEach(visibleLines) { line in
                            diffLineRow(line)
                        }
                    }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(t.dark ? Color.black.opacity(0.18) : Color.black.opacity(0.03))
        }
        .onAppear {
            startAutoRefresh()
        }
        .onDisappear {
            autoRefreshTask?.cancel()
            autoRefreshTask = nil
            refreshQueued = false
        }
        .task(id: repoCwd) { await load(showLoading: true) }
    }

    struct ActionDescriptor: Equatable {
        let title: String
        let accessibilityIdentifier: String
        let isEnabled: Bool
        let systemImage: String

        init(
            title: String,
            accessibilityIdentifier: String,
            isEnabled: Bool = true,
            systemImage: String = ""
        ) {
            self.title = title
            self.accessibilityIdentifier = accessibilityIdentifier
            self.isEnabled = isEnabled
            self.systemImage = systemImage
        }
    }

    struct ToolbarDescriptor: Equatable {
        static let accessibilityIdentifier = "code.diff.toolbar"
        static let fileCountAccessibilityIdentifier = "code.diff.files-count"
        static let unviewedCountAccessibilityIdentifier = "code.diff.unviewed-count"
        static let layoutAccessibilityIdentifier = "code.diff.layout"
        static let nextAccessibilityIdentifier = "code.diff.next-unviewed"
        static let markAllAccessibilityIdentifier = "code.diff.mark-all-viewed"

        let fileCountText: String
        let unviewedCountText: String
        let nextEnabled: Bool
        let markAllEnabled: Bool
    }

    struct FileActionDescriptors: Equatable {
        static let rowAccessibilityIdentifier = "code.diff.file.row"

        let reviewed: ActionDescriptor
        let flagChanges: ActionDescriptor
        let markViewed: ActionDescriptor
        let open: ActionDescriptor
    }

    struct HunkActionDescriptors: Equatable {
        static let rowAccessibilityIdentifier = "code.diff.hunk.row"

        let toggle: ActionDescriptor
        let explain: ActionDescriptor
    }

    static func toolbarDescriptor(fileCount: Int, unviewedCount: Int) -> ToolbarDescriptor {
        ToolbarDescriptor(
            fileCountText: "\(fileCount) files",
            unviewedCountText: "\(unviewedCount) unviewed",
            nextEnabled: unviewedCount > 0,
            markAllEnabled: fileCount > 0
        )
    }

    static func fileActionDescriptors(viewed: Bool) -> FileActionDescriptors {
        FileActionDescriptors(
            reviewed: ActionDescriptor(
                title: "Mark reviewed",
                accessibilityIdentifier: "code.diff.file.mark-reviewed"
            ),
            flagChanges: ActionDescriptor(
                title: "Flag changes",
                accessibilityIdentifier: "code.diff.file.flag-changes"
            ),
            markViewed: ActionDescriptor(
                title: viewed ? "Viewed" : "Mark viewed",
                accessibilityIdentifier: "code.diff.file.mark-viewed",
                isEnabled: !viewed
            ),
            open: ActionDescriptor(
                title: "Open",
                accessibilityIdentifier: "code.diff.file.open"
            )
        )
    }

    static func hunkActionDescriptors(collapsed: Bool) -> HunkActionDescriptors {
        HunkActionDescriptors(
            toggle: ActionDescriptor(
                title: collapsed ? "Expand hunk" : "Collapse hunk",
                accessibilityIdentifier: "code.diff.hunk.toggle-collapse",
                systemImage: collapsed ? "chevron.right" : "chevron.down"
            ),
            explain: ActionDescriptor(
                title: "Explain",
                accessibilityIdentifier: "code.diff.hunk.explain"
            )
        )
    }

    private func diffToolbar(proxy: ScrollViewProxy) -> some View {
        let descriptor = Self.toolbarDescriptor(
            fileCount: changedPaths.count,
            unviewedCount: unviewedPaths.count
        )
        return HStack(spacing: 8) {
            Text(descriptor.fileCountText)
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.fg3)
                .accessibilityIdentifier(ToolbarDescriptor.fileCountAccessibilityIdentifier)
            Text(descriptor.unviewedCountText)
                .font(TahoeFont.body(11))
                .foregroundStyle(descriptor.nextEnabled ? t.accent : t.fg4)
                .accessibilityIdentifier(ToolbarDescriptor.unviewedCountAccessibilityIdentifier)
            Spacer()
            Picker("Diff layout", selection: diffModeBinding) {
                ForEach(DiffDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 132)
            .labelsHidden()
            .accessibilityIdentifier(ToolbarDescriptor.layoutAccessibilityIdentifier)
            Button("Next", action: ContinuumAnalytics.wrapButton(
                    "next",
                    {
 jumpToNextUnviewed(proxy: proxy) 
                    }
                ))
                .font(TahoeFont.body(11, weight: .semibold))
                .buttonStyle(PressableButtonStyle())
                .disabled(!descriptor.nextEnabled)
                .help("Jump to the next unviewed file")
                .accessibilityIdentifier(ToolbarDescriptor.nextAccessibilityIdentifier)
            Button("Mark all viewed", action: ContinuumAnalytics.wrapButton(
                    "mark_all_viewed",
                    {
 markAllViewed() 
                    }
                ))
                .font(TahoeFont.body(11, weight: .semibold))
                .buttonStyle(PressableButtonStyle())
                .disabled(!descriptor.markAllEnabled)
                .help("Persist viewed state for all changed files")
                .accessibilityIdentifier(ToolbarDescriptor.markAllAccessibilityIdentifier)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ToolbarDescriptor.accessibilityIdentifier)
    }

    @ViewBuilder
    private func diffLineRow(_ line: DiffLine) -> some View {
        // A12 — use the precomputed header flag + path instead of
        // re-parsing the line text per rendered row.
        if line.isFileHeader, let path = line.path {
            let viewed = isViewed(path)
            let focused = focusedPath == path
            let actions = Self.fileActionDescriptors(viewed: viewed)
            HStack(spacing: 8) {
                Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewed ? .green : t.fg3)
                Text(path)
                    .font(TahoeFont.mono(11.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .textSelection(.enabled)
                if let disposition = presentationStore.snapshot.fileReviewDispositions[sessionId]?[path] {
                    Text(disposition.label)
                        .font(TahoeFont.body(10, weight: .bold))
                        .foregroundStyle(disposition == .approved ? .green : .orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(t.hair2, in: Capsule(style: .continuous))
                }
                Spacer()
                if hoveredPath == path {
                    Text(diffSummary(for: path))
                        .font(TahoeFont.mono(10))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                }
                Button("Mark reviewed", action: ContinuumAnalytics.wrapButton(
                        "mark_reviewed",
                        {
                    try? presentationStore.setFileReviewDisposition(sessionId: sessionId, path: path, disposition: .approved)
                
                        }
                    ))
                .font(TahoeFont.body(10.5, weight: .semibold))
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier(actions.reviewed.accessibilityIdentifier)
                Button("Flag changes", action: ContinuumAnalytics.wrapButton(
                        "flag_changes",
                        {
                    try? presentationStore.setFileReviewDisposition(sessionId: sessionId, path: path, disposition: .changesRequested)
                
                        }
                    ))
                .font(TahoeFont.body(10.5, weight: .semibold))
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier(actions.flagChanges.accessibilityIdentifier)
                Button(actions.markViewed.title, action: ContinuumAnalytics.wrapButton(
                        "title",
                        {
                    markViewed(path)
                
                        }
                    ))
                .font(TahoeFont.body(10.5, weight: .semibold))
                .buttonStyle(PressableButtonStyle())
                .disabled(!actions.markViewed.isEnabled)
                .accessibilityIdentifier(actions.markViewed.accessibilityIdentifier)
                Button("Open", action: ContinuumAnalytics.wrapButton(
                        "open",
                        {
 open(path) 
                        }
                    ))
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityIdentifier(actions.open.accessibilityIdentifier)
            }
            .id(Self.headerID(for: path))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(focused ? t.accentAlpha(0.18) : (viewed ? t.hair2.opacity(0.45) : t.accentAlpha(0.10)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(FileActionDescriptors.rowAccessibilityIdentifier)
            .onHover { inside in
                hoveredPath = inside ? path : (hoveredPath == path ? nil : hoveredPath)
            }
            .contextMenu {
                Button("Mark viewed") { markViewed(path) }.disabled(viewed)
                Button("Mark file reviewed", action: ContinuumAnalytics.wrapButton(
                        "mark_file_reviewed",
                        {
 try? presentationStore.setFileReviewDisposition(sessionId: sessionId, path: path, disposition: .approved) 
                        }
                    ))
                Button("Flag file changes", action: ContinuumAnalytics.wrapButton(
                        "flag_file_changes",
                        {
 try? presentationStore.setFileReviewDisposition(sessionId: sessionId, path: path, disposition: .changesRequested) 
                        }
                    ))
                Button("Clear review disposition", action: ContinuumAnalytics.wrapButton(
                        "clear_review_disposition",
                        {
 try? presentationStore.setFileReviewDisposition(sessionId: sessionId, path: path, disposition: nil) 
                        }
                    ))
                Button("Copy path") { copy(path) }
                Button("Open file", action: ContinuumAnalytics.wrapButton(
                        "open_file",
                        {
 open(path) 
                        }
                    ))
            }
        } else if line.kind == .hunk, let hunkId = line.hunkId {
            let collapsed = isHunkCollapsed(hunkId)
            let actions = Self.hunkActionDescriptors(collapsed: collapsed)
            HStack(spacing: 8) {
                Button(action: ContinuumAnalytics.wrapButton(
                        "tahoediffpreviewpane_l272",
                        {
                    try? presentationStore.setDiffHunkCollapsed(sessionId: sessionId, hunkId: hunkId, collapsed: !collapsed)
                
                        }
                    )) {
                    Image(systemName: actions.toggle.systemImage)
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier(actions.toggle.accessibilityIdentifier)
                Text(line.text)
                    .font(TahoeFont.mono(11.5, weight: .semibold))
                    .foregroundStyle(t.fg3)
                    .textSelection(.enabled)
                Spacer()
                Button("Explain", action: ContinuumAnalytics.wrapButton(
                        "explain",
                        {
                    ComposerInsertionInbox.shared.enqueue(text: "Explain this diff hunk:\n\n```diff\n\(hunkText(hunkId))\n```\n", autoSend: false)
                
                        }
                    ))
                .font(TahoeFont.body(10.5, weight: .semibold))
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier(actions.explain.accessibilityIdentifier)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(t.hair2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(HunkActionDescriptors.rowAccessibilityIdentifier)
            .contextMenu {
                Button(collapsed ? "Expand hunk" : "Collapse hunk", action: ContinuumAnalytics.wrapButton(
                        "collapsed_expand_hunk_collapse_hunk",
                        {
                    try? presentationStore.setDiffHunkCollapsed(sessionId: sessionId, hunkId: hunkId, collapsed: !collapsed)
                
                        }
                    ))
                Button("Copy hunk") { copy(hunkText(hunkId)) }
                Button("Explain hunk", action: ContinuumAnalytics.wrapButton(
                        "explain_hunk",
                        {
                    ComposerInsertionInbox.shared.enqueue(text: "Explain this diff hunk:\n\n```diff\n\(hunkText(hunkId))\n```\n", autoSend: false)
                
                        }
                    ))
            }
        } else if presentationStore.snapshot.diffDisplayMode == .split {
            splitDiffLineRow(line)
        } else {
            HStack(spacing: 0) {
                Text(line.sign)
                    .frame(width: 14, alignment: .leading)
                    .opacity(0.75)
                diffContentView(line)
            }
            .font(TahoeFont.mono(11.5))
            .foregroundStyle(diffForeground(for: line))
            .padding(.horizontal, 16)
            .padding(.vertical, 1)
            .background(diffBackground(for: line))
            .contextMenu {
                Button("Copy line") { copy(line.text) }
                Button("Explain hunk", action: ContinuumAnalytics.wrapButton(
                        "explain_hunk",
                        {
                    ComposerInsertionInbox.shared.enqueue(text: "Explain this diff hunk:\n\n```diff\n\(line.text)\n```\n", autoSend: false)
                
                        }
                    ))
            }
        }
    }

    private func splitDiffLineRow(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            diffSplitCell(line, shows: line.kind == .del || line.kind == .context, isAddition: false)
            diffSplitCell(line, shows: line.kind == .add || line.kind == .context, isAddition: true)
        }
        .contextMenu {
            Button("Copy line") { copy(line.text) }
            Button("Explain line", action: ContinuumAnalytics.wrapButton(
                    "explain_line",
                    {
                ComposerInsertionInbox.shared.enqueue(text: "Explain this diff line:\n\n```diff\n\(line.text)\n```\n", autoSend: false)
            
                    }
                ))
        }
    }

    private func diffSplitCell(_ line: DiffLine, shows: Bool, isAddition: Bool) -> some View {
        Group {
            if shows {
                diffContentView(line)
            } else {
                Text("")
            }
        }
        .font(TahoeFont.mono(11.5))
        .foregroundStyle((line.kind == .add && isAddition) ? additionForeground : (line.kind == .del && !isAddition) ? removalForeground : diffForeground(for: line))
        .frame(width: 420, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background((line.kind == .add && isAddition) ? additionBackground : (line.kind == .del && !isAddition) ? removalBackground : Color.clear)
    }

    @ViewBuilder
    private func diffContentView(_ line: DiffLine) -> some View {
        if let segments = intraLineSegments(for: line) {
            HStack(spacing: 0) {
                Text(segments.prefix)
                Text(segments.changed)
                    .background(intraLineHighlight(for: line), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                Text(segments.suffix)
            }
            .textSelection(.enabled)
        } else {
            Text(line.displayText)
                .textSelection(.enabled)
        }
    }

    private var syntaxTheme: CodeSyntaxTheme {
        presentationStore.snapshot.syntaxTheme
    }

    private var additionForeground: Color {
        switch syntaxTheme {
        case .tahoe: return Color(.sRGB, red: 0.32, green: 0.92, blue: 0.66)
        case .graphite: return t.dark ? Color(.sRGB, red: 0.76, green: 0.88, blue: 0.76) : Color(.sRGB, red: 0.10, green: 0.45, blue: 0.20)
        case .xcode: return t.dark ? Color(.sRGB, red: 0.46, green: 0.95, blue: 0.60) : Color(.sRGB, red: 0.03, green: 0.45, blue: 0.18)
        }
    }

    private var removalForeground: Color {
        switch syntaxTheme {
        case .tahoe: return Color(.sRGB, red: 1.0, green: 0.48, blue: 0.54)
        case .graphite: return t.dark ? Color(.sRGB, red: 0.92, green: 0.72, blue: 0.72) : Color(.sRGB, red: 0.58, green: 0.16, blue: 0.18)
        case .xcode: return t.dark ? Color(.sRGB, red: 1.0, green: 0.50, blue: 0.60) : Color(.sRGB, red: 0.70, green: 0.04, blue: 0.16)
        }
    }

    private var additionBackground: Color {
        switch syntaxTheme {
        case .tahoe: return Color.green.opacity(t.dark ? 0.16 : 0.10)
        case .graphite: return Color.gray.opacity(t.dark ? 0.18 : 0.12)
        case .xcode: return Color(.sRGB, red: 0.18, green: 0.72, blue: 0.36, opacity: t.dark ? 0.18 : 0.12)
        }
    }

    private var removalBackground: Color {
        switch syntaxTheme {
        case .tahoe: return Color.red.opacity(t.dark ? 0.16 : 0.10)
        case .graphite: return Color.gray.opacity(t.dark ? 0.16 : 0.10)
        case .xcode: return Color(.sRGB, red: 0.86, green: 0.12, blue: 0.20, opacity: t.dark ? 0.18 : 0.12)
        }
    }

    private func diffForeground(for line: DiffLine) -> Color {
        switch line.kind {
        case .add: return additionForeground
        case .del: return removalForeground
        case .hunk, .meta: return t.fg3
        case .context:
            switch syntaxTheme {
            case .tahoe: return t.dark ? Color(.sRGB, red: 0.78, green: 0.90, blue: 0.90) : Color(.sRGB, red: 0.14, green: 0.26, blue: 0.28)
            case .graphite: return t.fg2
            case .xcode: return t.dark ? Color(.sRGB, red: 0.74, green: 0.80, blue: 0.94) : Color(.sRGB, red: 0.08, green: 0.18, blue: 0.38)
            }
        }
    }

    private func diffBackground(for line: DiffLine) -> Color {
        switch line.kind {
        case .add: return additionBackground
        case .del: return removalBackground
        case .hunk: return t.hair2
        default:
            switch syntaxTheme {
            case .tahoe: return t.dark ? Color(.sRGB, red: 0.05, green: 0.09, blue: 0.10, opacity: 0.35) : Color(.sRGB, red: 0.90, green: 0.97, blue: 0.98, opacity: 0.45)
            case .graphite: return t.dark ? Color.white.opacity(0.025) : Color.black.opacity(0.025)
            case .xcode: return t.dark ? Color(.sRGB, red: 0.05, green: 0.06, blue: 0.10, opacity: 0.42) : Color(.sRGB, red: 0.95, green: 0.98, blue: 1.0, opacity: 0.50)
            }
        }
    }

    private func intraLineHighlight(for line: DiffLine) -> Color {
        switch line.kind {
        case .add: return additionForeground.opacity(0.28)
        case .del: return removalForeground.opacity(0.28)
        default: return t.accentAlpha(0.18)
        }
    }

    private func intraLineSegments(for line: DiffLine) -> (prefix: String, changed: String, suffix: String)? {
        guard line.kind == .add || line.kind == .del,
              let counterpart = nearestOppositeLine(for: line)
        else { return nil }
        let old = Array(line.displayText)
        let other = Array(counterpart.displayText)
        guard !old.isEmpty, !other.isEmpty else { return nil }

        var prefixCount = 0
        while prefixCount < old.count,
              prefixCount < other.count,
              old[prefixCount] == other[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount + prefixCount < old.count,
              suffixCount + prefixCount < other.count,
              old[old.count - 1 - suffixCount] == other[other.count - 1 - suffixCount] {
            suffixCount += 1
        }

        let changedEnd = max(prefixCount, old.count - suffixCount)
        guard changedEnd > prefixCount else { return nil }
        return (
            String(old[..<prefixCount]),
            String(old[prefixCount..<changedEnd]),
            suffixCount == 0 ? "" : String(old[(old.count - suffixCount)...])
        )
    }

    private func nearestOppositeLine(for line: DiffLine) -> DiffLine? {
        // A12 — bounded lookup over only this hunk's add/del lines (built
        // once per load) instead of filtering the entire `lines` array on
        // every rendered add/del row.
        guard let hunkId = line.hunkId else { return nil }
        let opposite: DiffLine.Kind = line.kind == .add ? .del : .add
        let candidates = opposite == .add ? index.hunkAdds[hunkId] : index.hunkDels[hunkId]
        return candidates?
            .filter { abs($0.index - line.index) <= 6 }
            .min { abs($0.index - line.index) < abs($1.index - line.index) }
    }

    private func diffSummary(for path: String) -> String {
        // A12 — precomputed once per load; hovering a file row no longer
        // re-walks the whole diff to recount hunks/additions/removals.
        index.pathSummaries[path] ?? ""
    }

    @MainActor
    private func load(showLoading: Bool) async {
        if isRefreshing {
            refreshQueued = true
            return
        }
        isRefreshing = true
        if showLoading {
            isLoading = true
        }
        let cwd = repoCwd
        let (loaded, builtIndex) = await Task.detached(priority: .utility) { () -> ([DiffLine], DiffIndex) in
            let lines = Self.loadGitDiff(cwd: cwd)
            // Build the derived indices on the same background hop so the
            // O(files × lines) summary/block/opposite-line work happens
            // once off-main, not per-render on the main actor.
            return (lines, Self.buildIndex(lines))
        }.value
        lines = loaded
        index = builtIndex
        if showLoading {
            isLoading = false
        }
        isRefreshing = false
        if refreshQueued {
            refreshQueued = false
            await load(showLoading: false)
        }
    }

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                await load(showLoading: false)
            }
        }
    }

    nonisolated private static func loadGitDiff(cwd: String) -> [DiffLine] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "diff", "--no-ext-diff", "--unified=3", "--"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            // A12 — annotate is the legacy classify-and-track-hunk-
            // path pass. It's a single linear walk (O(N)) but for a
            // 50k-line diff that's still ~50k String allocations +
            // ~50k DiffLine allocations on the hot path. We cache the
            // result keyed on the raw text so re-opening the pane
            // with an unchanged worktree skips the walk entirely.
            //
            // The shared `ParsedDiffCache` keeps the structured
            // representation around for any future workbench renderer
            // that wants to render directly off `ParsedDiff`; we keep
            // a parallel in-process `[DiffLine]` cache for the legacy
            // renderer here so this PR doesn't have to rewrite the
            // split-view + intra-line + hunk-collapse machinery.
            _ = ParsedDiffCache.shared.parsed(input: text)
            return Self.annotatedDiffLineCache.lookupOrCompute(text: text) {
                let rawLines = text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                return annotate(rawLines)
            }
        } catch {
            return [DiffLine("Unable to load diff: \(error.localizedDescription)", index: 0, forcedKind: .meta)]
        }
    }

    nonisolated private static func annotate(_ rawLines: [String]) -> [DiffLine] {
        var currentPath: String?
        var currentHunk: String?
        return rawLines.enumerated().map { index, text in
            var isHeader = false
            if let path = path(fromDiffHeader: text) {
                currentPath = path
                currentHunk = nil
                isHeader = true
            } else if text.hasPrefix("@@") {
                currentHunk = "\(currentPath ?? "diff"):\(text)"
            }
            return DiffLine(text, index: index, hunkId: currentHunk, path: currentPath, isFileHeader: isHeader)
        }
    }

    private var visibleLines: [DiffLine] {
        var output: [DiffLine] = []
        output.reserveCapacity(lines.count)
        var skippingHunk: String?
        for line in lines {
            // A12 — precomputed header flag instead of re-parsing the line
            // text (hasPrefix + split) for every line on every body render.
            if line.isFileHeader {
                skippingHunk = nil
                output.append(line)
                continue
            }
            if line.kind == .hunk, let hunkId = line.hunkId {
                output.append(line)
                skippingHunk = isHunkCollapsed(hunkId) ? hunkId : nil
                continue
            }
            if let skippingHunk, line.hunkId == skippingHunk {
                continue
            }
            output.append(line)
        }
        return output
    }

    private var diffModeBinding: Binding<DiffDisplayMode> {
        Binding(
            get: { presentationStore.snapshot.diffDisplayMode },
            set: { try? presentationStore.setDiffDisplayMode($0) }
        )
    }

    private var changedPaths: [String] {
        // A12 — read the precomputed ordered path list instead of
        // re-scanning + re-parsing every line on each access.
        index.orderedPaths
    }

    private var unviewedPaths: [String] {
        changedPaths.filter { !isViewed($0) }
    }

    private func isViewed(_ path: String) -> Bool {
        let hash = contentHash(for: path)
        return presentationStore.snapshot.viewedFiles[sessionId]?.contains {
            $0.path == path && $0.contentHash == hash
        } == true
    }

    private func markViewed(_ path: String) {
        try? presentationStore.recordViewedFile(sessionId: sessionId, path: path, contentHash: contentHash(for: path))
    }

    private func markAllViewed() {
        for path in changedPaths {
            markViewed(path)
        }
    }

    private func jumpToNextUnviewed(proxy: ScrollViewProxy) {
        guard let path = unviewedPaths.first else { return }
        focusedPath = path
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.headerID(for: path), anchor: .top)
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.headerID(for: path), anchor: .top)
            }
        }
    }

    private func contentHash(for path: String) -> String {
        let text = diffBlock(for: path).joined(separator: "\n")
        return ClawdmeterTextUtilities.stableContentHash(text)
    }

    private func isHunkCollapsed(_ hunkId: String) -> Bool {
        presentationStore.snapshot.collapsedDiffHunks[sessionId]?.contains(hunkId) == true
    }

    private func hunkText(_ hunkId: String) -> String {
        lines.filter { $0.hunkId == hunkId }.map(\.text).joined(separator: "\n")
    }

    private func diffBlock(for path: String) -> [String] {
        // A12 — precomputed per-path block; avoids an O(lines) walk +
        // per-line `path(fromDiffHeader:)` reparse on every call (the
        // hover summary + mark-all-viewed hot paths hit this per file).
        index.pathBlocks[path] ?? []
    }

    private func open(_ path: String) {
        try? presentationStore.recordPathAction(path)
        let url = URL(fileURLWithPath: repoCwd).appendingPathComponent(path)
        NSWorkspace.shared.open(url)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    nonisolated private static func path(fromDiffHeader line: String) -> String? {
        guard line.hasPrefix("diff --git ") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 4 else { return nil }
        let raw = String(parts[3])
        if raw.hasPrefix("b/") { return String(raw.dropFirst(2)) }
        return raw
    }

    nonisolated private static func headerID(for path: String) -> String {
        "diff-header-\(path)"
    }

    private struct DiffLine: Identifiable {
        enum Kind { case meta, hunk, add, del, context }
        /// A12 — `index` is unique within a single load, so we can use
        /// it directly as `Identifiable.id`. The previous
        /// `"\(index)-\(text)"` formulation allocated a String per
        /// row on every layout pass — a 50k-line diff burned ~50k
        /// allocations + interpolation work just to compare identity.
        var id: Int { index }
        let text: String
        let index: Int
        let kind: Kind
        let hunkId: String?
        let path: String?
        // A12 — precomputed once in `annotate` so the hot-path body
        // checks ("is this row a `diff --git` file header?") are O(1)
        // field reads instead of re-running `path(fromDiffHeader:)`
        // (hasPrefix + split) per visible row on every layout pass.
        let isFileHeader: Bool

        init(_ text: String, index: Int, hunkId: String? = nil, path: String? = nil, isFileHeader: Bool = false, forcedKind: Kind? = nil) {
            self.text = text
            self.index = index
            self.hunkId = hunkId
            self.path = path
            self.isFileHeader = isFileHeader
            if let forcedKind {
                self.kind = forcedKind
            } else if text.hasPrefix("@@") {
                self.kind = .hunk
            } else if text.hasPrefix("+") && !text.hasPrefix("+++") {
                self.kind = .add
            } else if text.hasPrefix("-") && !text.hasPrefix("---") {
                self.kind = .del
            } else if text.hasPrefix("diff --git") || text.hasPrefix("+++") || text.hasPrefix("---") {
                self.kind = .meta
            } else {
                self.kind = .context
            }
        }

        var sign: String {
            switch kind {
            case .add: return "+"
            case .del: return "-"
            default: return ""
            }
        }

        var displayText: String {
            switch kind {
            case .add, .del:
                return text.isEmpty ? text : String(text.dropFirst())
            default:
                return text
            }
        }

        func foreground(_ t: TahoeTokens) -> Color {
            switch kind {
            case .add: return t.dark ? Color.green.opacity(0.86) : Color.green.opacity(0.72)
            case .del: return t.dark ? Color.red.opacity(0.86) : Color.red.opacity(0.74)
            case .hunk, .meta: return t.fg3
            case .context: return t.fg2
            }
        }

        func background(_ t: TahoeTokens) -> Color {
            switch kind {
            case .add: return Color.green.opacity(t.dark ? 0.16 : 0.10)
            case .del: return Color.red.opacity(t.dark ? 0.16 : 0.10)
            case .hunk: return t.hair2
            default: return .clear
            }
        }
    }

    /// A12 — derived view of `[DiffLine]` precomputed once per `load()`.
    /// Collapses the per-render O(files × lines) scans (hover summary,
    /// mark-all-viewed content hashing, file-list, intra-line opposite
    /// lookup) into single linear-build lookups so re-renders stay cheap.
    private struct DiffIndex {
        /// File paths in diff order (replaces the per-access scan in `changedPaths`).
        var orderedPaths: [String] = []
        /// path → raw line texts for that file's block (replaces `diffBlock`'s walk).
        var pathBlocks: [String: [String]] = [:]
        /// path → "N hunks · +A -D" summary (replaces `diffSummary`'s recount).
        var pathSummaries: [String: String] = [:]
        /// hunkId → its `.add` lines, in `index` order (bounded ±6 lookup in `nearestOppositeLine`).
        var hunkAdds: [String: [DiffLine]] = [:]
        /// hunkId → its `.del` lines, in `index` order.
        var hunkDels: [String: [DiffLine]] = [:]
    }

    nonisolated private static func buildIndex(_ lines: [DiffLine]) -> DiffIndex {
        var index = DiffIndex()
        var currentPath: String?
        for line in lines {
            if line.isFileHeader, let path = line.path {
                currentPath = path
                if index.pathBlocks[path] == nil {
                    index.orderedPaths.append(path)
                    index.pathBlocks[path] = []
                }
            }
            if let currentPath {
                index.pathBlocks[currentPath, default: []].append(line.text)
            }
            if let hunkId = line.hunkId {
                switch line.kind {
                case .add: index.hunkAdds[hunkId, default: []].append(line)
                case .del: index.hunkDels[hunkId, default: []].append(line)
                default: break
                }
            }
        }
        for (path, block) in index.pathBlocks {
            let additions = block.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            let removals = block.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            let hunks = block.filter { $0.hasPrefix("@@") }.count
            index.pathSummaries[path] = "\(hunks) hunk\(hunks == 1 ? "" : "s") · +\(additions) -\(removals)"
        }
        return index
    }

    /// A12 — in-process cache for the legacy `[DiffLine]` shape this
    /// pane consumes. Mirrors the shared `ParsedDiffCache` but with a
    /// smaller capacity (each entry is a per-render data structure).
    ///
    /// Re-mounts of the diff pane (Cmd-tab back into the workbench,
    /// presentationStore changes that re-create the view) skip the
    /// linear annotate walk when the underlying `git diff` text
    /// hasn't changed.
    private final class DiffLineCache: @unchecked Sendable {
        private struct Key: Hashable {
            let textHash: String
        }
        private let lock = NSLock()
        private var storage: [Key: [DiffLine]] = [:]
        private var order: [Key] = []
        private let capacity = 8

        func lookupOrCompute(
            text: String,
            compute: () -> [DiffLine]
        ) -> [DiffLine] {
            let key = Key(textHash: UnifiedDiffParser.sha256Hex(text))
            lock.lock()
            if let cached = storage[key] {
                if let existing = order.firstIndex(of: key) {
                    order.remove(at: existing)
                }
                order.append(key)
                lock.unlock()
                return cached
            }
            lock.unlock()

            // Compute outside the lock — a 50k-line annotate is ~tens
            // of ms and we don't want concurrent diff-pane mounts to
            // serialize behind one another.
            let computed = compute()

            lock.lock()
            // A12 review fix — drop any prior recency entry for this
            // key before appending so concurrent misses (both threads
            // parsed, both reach this branch) don't leave duplicate
            // keys in `order`. Duplicates would let a later eviction
            // remove a still-warm entry from `storage`, forcing a
            // wasteful re-parse on the next lookup.
            if storage[key] != nil, let existing = order.firstIndex(of: key) {
                order.remove(at: existing)
            }
            storage[key] = computed
            order.append(key)
            while storage.count > capacity, let oldest = order.first {
                order.removeFirst()
                storage.removeValue(forKey: oldest)
            }
            lock.unlock()
            return computed
        }
    }

    /// Process-lifetime cache. Diff-pane mounts are short-lived; a
    /// long-lived cache here means a Cmd-tab cycle hits warm data.
    nonisolated private static let annotatedDiffLineCache = DiffLineCache()
}
