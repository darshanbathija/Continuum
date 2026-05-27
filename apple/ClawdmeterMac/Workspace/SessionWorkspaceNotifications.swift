import Foundation

/// `Notification.Name`s posted + observed across `SessionWorkspaceView`
/// and its descendants. Lifted out of `SessionWorkspaceView.swift` by
/// **A6 (foundation)** — see .claude/plans/study-this-codebase-crystalline-shore.md.
///
/// These names are the public contract between the workspace, the
/// app-level menu commands, and the iOS-via-daemon bridge — keep the
/// raw string identifiers stable to avoid breaking external posters.
extension Notification.Name {
    static let focusSidebarSearch = Notification.Name("clawdmeter.workspace.focusSidebarSearch")
    static let toggleCodeReviewPane = Notification.Name("clawdmeter.workspace.toggleCodeReviewPane")
    static let openCodeReviewPane = Notification.Name("clawdmeter.workspace.openCodeReviewPane")
    static let popOutSession = Notification.Name("clawdmeter.workspace.popOutSession")
    /// Posted to open a first-class workspace terminal tab on a specific session.
    /// Kept as the stable external name for older posters that still say
    /// "raw terminal".
    static let showRawTerminal = Notification.Name("clawdmeter.workspace.showRawTerminal")
    static let transcriptFind = Notification.Name("clawdmeter.workspace.transcriptFind")
    static let transcriptNextMatch = Notification.Name("clawdmeter.workspace.transcriptNextMatch")
    static let transcriptPreviousMatch = Notification.Name("clawdmeter.workspace.transcriptPreviousMatch")
    static let transcriptLatest = Notification.Name("clawdmeter.workspace.transcriptLatest")
    static let transcriptLastUser = Notification.Name("clawdmeter.workspace.transcriptLastUser")
    static let composerHistory = Notification.Name("clawdmeter.workspace.composerHistory")
    static let composerSend = Notification.Name("clawdmeter.workspace.composerSend")
    static let composerQueue = Notification.Name("clawdmeter.workspace.composerQueue")
    static let composerToggleDictation = Notification.Name("clawdmeter.workspace.composerToggleDictation")
    static let openWorkspaceSwitcher = Notification.Name("clawdmeter.workspace.openWorkspaceSwitcher")
    static let sessionNextAttention = Notification.Name("clawdmeter.workspace.sessionNextAttention")
    /// Posted by iOS via the daemon's compose-draft WS event to seed the
    /// Mac empty-state composer with iPhone-typed prompt text (X1).
    static let composeDraftIncoming = Notification.Name("clawdmeter.workspace.composeDraftIncoming")

    // MARK: - PR #185 — Code tab hover polish + composer chip shortcuts
    //
    // Used by `UsageStatusChip`, `PermissionModeChip`, `SessionStatusBadges`,
    // and `CodeTabHoverShortcutUITests` to wire keyboard chords directly to
    // the open composer without going through the menu bar.

    /// #185 sibling of `clawdmeterOpenWorkspaceChatTab`. Posted by the
    /// Code-tab `+` menu, the chip / hover-control surface, and the
    /// `ClawdmeterShortcutRegistry` `⌘T` chord. `SessionWorkspaceView`
    /// observes both names and routes them to the same
    /// `openDraftWorkspaceTab` / `spawnSameWorkspaceChatTab` model call,
    /// so the two posters cannot drift.
    static let newCodeChatTab = Notification.Name("clawdmeter.workspace.newCodeChatTab")
    /// #185 sibling of `clawdmeterOpenWorkspaceTerminalTab`. `⌘⇧T` chord
    /// + terminal hover affordance. Same dual-observer routing.
    static let newCodeTerminalTab = Notification.Name("clawdmeter.workspace.newCodeTerminalTab")

    static let composerAttach = Notification.Name("clawdmeter.workspace.composerAttach")
    static let composerOpenModelEffort = Notification.Name("clawdmeter.workspace.composerOpenModelEffort")
    static let composerOpenContextUsage = Notification.Name("clawdmeter.workspace.composerOpenContextUsage")
    static let composerCycleEffortNext = Notification.Name("clawdmeter.workspace.composerCycleEffortNext")
    static let composerCycleEffortPrevious = Notification.Name("clawdmeter.workspace.composerCycleEffortPrevious")
    static let composerSetPermissionMode = Notification.Name("clawdmeter.workspace.composerSetPermissionMode")
    static let renameOpenSession = Notification.Name("clawdmeter.workspace.renameOpenSession")
    static let archiveOpenSession = Notification.Name("clawdmeter.workspace.archiveOpenSession")
}
