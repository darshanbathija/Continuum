import Foundation

/// One frame decoded from tmux `-CC` control-mode output.
///
/// Each frame starts with `%` on a line and ends at the next newline. Frames
/// are emitted by the tmux server on its stdout when invoked as `tmux -CC`.
/// See: tmux(1) "CONTROL MODE" + iTerm2's `iTermTmuxGateway.m`.
public enum ControlModeFrame: Equatable, Sendable {

    /// `%begin <timestamp> <number> <flags>` — start of a command response.
    /// Subsequent lines (raw text, not octal-escaped) belong to this command
    /// until a matching `%end` or `%error` arrives.
    case begin(timestamp: Int64, number: Int, flags: Int)

    /// `%end <timestamp> <number> <flags>` — successful command response end.
    case end(timestamp: Int64, number: Int, flags: Int)

    /// `%error <timestamp> <number> <flags>` — command response that returned
    /// an error. The accumulated body is the error text.
    case error(timestamp: Int64, number: Int, flags: Int)

    /// `%output %<paneid> <octal-escaped-bytes>` — output bytes from a pane.
    ///
    /// `bytes` is the decoded byte sequence (octal escapes already resolved).
    /// Forward these to the WebSocket client without re-encoding; SwiftTerm /
    /// xterm.js consumes raw ANSI/UTF-8 bytes.
    case output(paneId: String, bytes: Data)

    /// `%window-add @<id>` — a new window was added.
    case windowAdd(windowId: String)

    /// `%window-close @<id>` — a window was closed.
    case windowClose(windowId: String)

    /// `%window-rename @<id> <new-name>`
    case windowRename(windowId: String, newName: String)

    /// `%layout-change @<window> <layout-string>` — emitted on resize and
    /// pane split/close. The `layout` is tmux's internal layout spec.
    case layoutChange(windowId: String, layout: String)

    /// `%session-changed $<id> <name>`
    case sessionChanged(sessionId: String, name: String)

    /// `%session-renamed <new-name>`
    case sessionRenamed(name: String)

    /// `%sessions-changed` — emitted when the set of sessions changes
    /// (add/remove/rename). No arguments. Distinct from `session-changed`
    /// which fires for the attached session of a specific client.
    case sessionsChanged

    /// `%paste-buffer-changed <name>` — buffer added/replaced.
    case pasteBufferChanged(name: String)

    /// `%paste-buffer-deleted <name>` — buffer removed.
    case pasteBufferDeleted(name: String)

    /// `%pane-mode-changed %<paneid>` — pane entered/exited a mode (copy,
    /// view, etc).
    case paneModeChanged(paneId: String)

    /// `%subscription-changed <name> $<sid> @<wid> %<pid> <count> <data>` —
    /// emitted when a tmux subscription (refresh-client -B) updates.
    case subscriptionChanged(raw: String)

    /// `%session-window-changed $<sid> @<wid>` — the active window of a
    /// session changed.
    case sessionWindowChanged(sessionId: String, windowId: String)

    /// `%client-session-changed <client> $<sid> <name>`
    case clientSessionChanged(client: String, sessionId: String, name: String)

    /// `%window-renamed @<wid> <new-name>` — alias for `window-rename` in
    /// some tmux versions.
    case windowRenamed(windowId: String, newName: String)

    /// `%client-detached <client-name>`
    case clientDetached(client: String)

    /// `%pause %<paneid>` — tmux 3.4+ flow-control signal: pane output paused.
    case pause(paneId: String)

    /// `%continue %<paneid>` — pane output resumed.
    case continueOutput(paneId: String)

    /// `%exit [reason]` — control mode is exiting.
    case exit(reason: String?)

    /// Anything we don't recognize. Surface for logging; do NOT crash on
    /// unknown frames (tmux versions add new ones over time).
    case unknown(raw: String)
}
