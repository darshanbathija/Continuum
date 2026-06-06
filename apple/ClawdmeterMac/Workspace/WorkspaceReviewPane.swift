import SwiftUI
import AppKit
import ClawdmeterShared

struct WorkspaceReviewPane: View {
    let session: AgentSession
    let chatStore: SessionChatStore?
    @ObservedObject var model: SessionsModel
    @ObservedObject var workbenchState: WorkbenchState
    @ObservedObject var presentationStore: SessionPresentationStore
    @ObservedObject var browserController: BrowserWorkspaceController
    @Binding var selectedTab: WorkbenchPaneTab
    let onClose: () -> Void
    let onApprove: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabPill

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            TahoeHairline()
            tabContent
                .transition(.opacity)
        }
        .background(Color.clear)
        // P5/P6: the selected-tab pill slides (matchedGeometry) and the pane
        // body cross-fades on switch (160ms) instead of an instant hard cut.
        .animation(SessionsV2Theme.segmentedSelection(reduceMotion: reduceMotion), value: selectedTab)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Self.primaryTabs) { tab in
                tabChip(tab)
            }
        }
        .contextMenu {
            Button {
                selectedTab = .artifacts
            } label: {
                Label("Artifacts", systemImage: WorkbenchPaneTab.artifacts.systemImage)
            }
            Button {
                selectedTab = .browser
            } label: {
                Label("Browser", systemImage: WorkbenchPaneTab.browser.systemImage)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private static let primaryTabs: [WorkbenchPaneTab] = [.plan, .diff, .sources, .browser, .pr, .terminal]

    private func tabChip(_ tab: WorkbenchPaneTab) -> some View {
        let isSelected = (selectedTab == tab)
        return Button(action: { selectedTab = tab }) {
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
            .foregroundStyle(isSelected ? t.fg : t.fg3)
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
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func tabLabel(_ tab: WorkbenchPaneTab) -> String {
        tab == .terminal ? "Term" : tab.rawValue
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .plan:
            TahoeReviewPlanPane(
                pendingPlanText: session.planText,
                approvedPlanText: session.approvedPlanText,
                chatStore: chatStore
            )
        case .diff:
            TahoeDiffPreviewPane(
                sessionId: session.id,
                repoCwd: session.effectiveCwd,
                presentationStore: presentationStore
            )
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
                controller: browserController
            )
        case .pr:
            TahoePRCompactPane(
                coordinator: model.prCoordinator(for: session),
                chatStore: chatStore,
                onBeforeMerge: {
                    await createCheckpoint(summary: "Before PR merge")
                }
            )
        case .terminal:
            // Real PTY-backed terminal pointed at the session's repo.
            // Reuses the same `TerminalTabContainer` (G12 multi-pane)
            // wired to the daemon's WS port + bearer token, so the user
            // gets a live shell instead of an echoed bash-tool summary.
            terminalTab
        }
    }

    /// Live direct PTY terminal in the review pane. Reuses the same
    /// `TerminalTabContainer` that the Cmd+T overlay shows, but inline
    /// so the user can keep the chat and the raw shell side-by-side
    /// without juggling a sheet.
    @ViewBuilder
    private var terminalTab: some View {
        if let runtime = AppDelegate.runtime,
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
