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
    /// Posted to open the raw tmux Cmd+T overlay on a specific session.
    /// (Wave B: chat-first; terminal demoted to overlay.)
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
}
