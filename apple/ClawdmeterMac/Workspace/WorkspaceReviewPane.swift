import SwiftUI
import AppKit
import ClawdmeterShared

struct WorkspaceReviewPane: View {
    let session: AgentSession
    let chatStore: SessionChatStore?
    @ObservedObject var model: SessionsModel
    @ObservedObject var workbenchState: WorkbenchState
    @ObservedObject var presentationStore: SessionPresentationStore
    let browserControllerProvider: () -> BrowserWorkspaceController
    @Binding var selectedTab: WorkbenchPaneTab
    let onClose: () -> Void
    let onApprove: () -> Void
    @State private var diffPaneMode: DiffPaneMode = .preview

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabPill
    @State private var hoveredTab: WorkbenchPaneTab?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            TahoeHairline()
            tabContent
                .transition(.opacity)
        }
        .overlay(alignment: .topLeading) {
            Text(selectedTab.rawValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .accessibilityLabel("Selected \(selectedTab.rawValue)")
                .accessibilityIdentifier("code.review.selected.\(selectedTab.accessibilityKey)")
        }
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.review.pane")
        .accessibilityValue(selectedTab.rawValue)
        // P5/P6: the selected-tab pill slides (matchedGeometry) and the pane
        // body cross-fades on switch (160ms) instead of an instant hard cut.
        .animation(SessionsV2Theme.segmentedSelection(reduceMotion: reduceMotion), value: selectedTab)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(WorkbenchPaneTab.visibleReviewPaneTabs) { tab in
                tabChip(tab)
            }
        }
        .contextMenu {
            Button(action: ContinuumAnalytics.wrapButton(
                    "workspacereviewpane_l53",
                    {
                selectedTab = .artifacts
            
                    }
                )) {
                Label("Artifacts", systemImage: WorkbenchPaneTab.artifacts.systemImage)
            }
            Button(action: ContinuumAnalytics.wrapButton(
                    "workspacereviewpane_l58",
                    {
                selectedTab = .browser
            
                    }
                )) {
                Label("Browser", systemImage: WorkbenchPaneTab.browser.systemImage)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func tabChip(_ tab: WorkbenchPaneTab) -> some View {
        let isSelected = (selectedTab == tab)
        let isHovered = (hoveredTab == tab)
        return Button(action: ContinuumAnalytics.wrapButton(
                "workspacereviewpane_l70",
                {
 selectedTab = tab
                }
            )) {
            HStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(tabLabel(tab))
                    .font(TahoeFont.body(11.5, weight: isSelected ? .bold : .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? t.fg : (isHovered ? t.fg : t.fg3))
            // P5: the active-tab pill is a single matched-geometry view that
            // SLIDES to the tapped segment rather than hard-cutting on/off.
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(t.dark ? Color.white.opacity(0.10) : Color.white)
                        .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(t.hairline, lineWidth: 0.5)
                        )
                        .matchedGeometryEffect(id: "reviewTabPill", in: tabPill)
                } else if isHovered {
                    // Match the Code-tab hover affordance (see SidebarPane rows):
                    // a subtle fill so unselected tabs read as clickable.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(t.hair2.opacity(colorScheme == .dark ? 1.0 : 1.35))
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("code.review.tab.\(tab.accessibilityKey)")
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { inside in
            if inside {
                hoveredTab = tab
            } else if hoveredTab == tab {
                hoveredTab = nil
            }
        }
        // Pointing-hand cursor on hover, matching every other clickable
        // surface in the Code tab.
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .accessibilityIdentifier("code.review.tab.\(tab.accessibilityKey)")
    }

    private func tabLabel(_ tab: WorkbenchPaneTab) -> String {
        tab.rawValue
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .plan:
            TahoeReviewPlanPane(
                pendingPlanText: session.planText,
                approvedPlanText: session.approvedPlanText,
                chatStore: chatStore,
                onApprove: onApprove
            )
        case .diff:
            diffTab
        case .sources:
            TahoeSourcesPreviewPane(chatStore: chatStore)
        case .artifacts:
            TahoeReviewContentShell(title: "Artifacts", icon: "doc", padded: false) {
                if let chatStore {
                    ArtifactsPane(session: session, chatStore: chatStore)
                } else {
                    // P8: shimmer rather than a lone spinner while the chat
                    // store warms up.
                    SkeletonLines(count: 4, label: "Waiting for the agent…")
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        case .browser:
            InAppBrowser(
                session: session,
                model: model,
                workbenchState: workbenchState,
                controller: browserControllerProvider()
            )
        case .pr:
            EmptyView()
        case .terminal:
            // Real PTY-backed terminal pointed at the session's repo.
            // Reuses the same `TerminalTabContainer` (G12 multi-pane)
            // wired to the daemon's WS port + bearer token, so the user
            // gets a live shell instead of an echoed bash-tool summary.
            terminalTab
        }
    }

    private enum DiffPaneMode: String, CaseIterable, Identifiable {
        case preview
        case git

        var id: String { rawValue }

        var title: String {
            switch self {
            case .preview: return "Review"
            case .git: return "Git"
            }
        }
    }

    private var diffTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(DiffPaneMode.allCases) { mode in
                    diffModeButton(mode)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("code.diff.mode")
            TahoeHairline()
            if diffPaneMode == .preview {
                TahoeDiffPreviewPane(
                    sessionId: session.id,
                    repoCwd: session.effectiveCwd,
                    presentationStore: presentationStore
                )
            } else {
                GitDiffPane(
                    repoCwd: session.effectiveCwd,
                    onBeforeDestructiveChange: {
                        await createCheckpoint(summary: "Before destructive diff action")
                    }
                )
            }
        }
    }

    private func diffModeButton(_ mode: DiffPaneMode) -> some View {
        let isSelected = diffPaneMode == mode
        let accessibilityIdentifier = "code.diff.mode.\(mode.rawValue)"
        return Button(action: ContinuumAnalytics.wrapButton(
                "diff_mode_\(mode.rawValue)",
                {
            diffPaneMode = mode
        
                }
            )) {
            Text(mode.title)
                .font(TahoeFont.body(11, weight: isSelected ? .bold : .semibold))
                .lineLimit(1)
                .frame(minWidth: 54, minHeight: 24)
                .padding(.horizontal, 5)
                .foregroundStyle(isSelected ? t.fg : t.fg3)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? (t.dark ? Color.white.opacity(0.10) : Color.white) : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? t.hairline : Color.clear, lineWidth: 0.5)
                }
                .accessibilityIdentifier("\(accessibilityIdentifier).label")
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mode.title)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityValue(isSelected ? "selected" : "not selected")
    }

    /// Live direct PTY terminal in the review pane. Reuses the same
    /// `TerminalTabContainer` that the Cmd+T overlay shows, but inline
    /// so the user can keep the chat and the raw shell side-by-side
    /// without juggling a sheet.
    @ViewBuilder
    private var terminalTab: some View {
        if !model.canOpenWorkspaceTerminalTab(from: session) {
            placeholder(text: "Terminal unavailable for this session.")
        } else if let runtime = AppDelegate.runtime,
           let port = runtime.agentControlServer.boundWsPort {
            TerminalTabContainer(
                session: session,
                model: model,
                wsPort: Int(port),
                token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? "")
            )
        } else {
            placeholder(text: "Daemon offline — restart Clawdmeter.")
        }
    }

    private func placeholder(text: String) -> some View {
        VStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func createCheckpoint(summary: String) async -> Bool {
        let service = CheckpointService()
        do {
            let checkpoint = try await service.createCheckpoint(session: session, summary: summary)
            workbenchState.recordCheckpoint(checkpoint)
            return true
        } catch {
            return false
        }
    }

    private var paneBg: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : Color(red: 0.95, green: 0.95, blue: 0.95)
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}
