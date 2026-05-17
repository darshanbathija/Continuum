import Foundation

/// Send-to-tmux strategy heuristic.
///
/// **Why this exists.** Both the Mac `Network.framework` daemon
/// (`AgentControlServer.handleSendPrompt`) and the Linux Hummingbird daemon
/// (`HummingbirdTransport`) need to forward a user's chat turn into the
/// session's tmux pane. The naive approaches both have bugs:
///
/// - `sendKeys` (typing the bytes into the pane) is right for short
///   commands but truncates pastes >256 bytes and mishandles embedded
///   newlines (tmux interprets each newline as enter, sending each line as
///   a separate command).
/// - `pasteBytes` (writing to tmux's paste-buffer + `paste-buffer -t pane`)
///   handles long input and embedded newlines correctly, **but does not
///   submit unless the buffer ends with a newline**. (See 2026-05-17 pitfall
///   `tmux-paste-buffer-needs-newline`.)
///
/// The shared heuristic: use `sendKeys` for the small/simple case (short,
/// no embedded newline, not a follow-up after a prior turn), and
/// `pasteBytes` with a guaranteed trailing newline otherwise. Both daemons
/// call this single function so the wire is byte-identical across platforms.
public enum SubmitToTmux {

    /// Strategy chosen for the input.
    public enum Strategy: Equatable, Sendable {
        /// Short single-line input — type it character-by-character via
        /// tmux `send-keys`. tmux handles Enter implicitly.
        case sendKeys(bytes: Data)
        /// Long or multi-line input — load tmux paste-buffer with bytes
        /// (newline-terminated) + `paste-buffer -t <pane>` + `send-keys
        /// Enter`. The trailing newline is critical — without it tmux
        /// holds the paste in the input line and never submits.
        case pasteBytes(bytes: Data)
    }

    /// Mac heuristic from `AgentControlServer:844`:
    /// `if req.asFollowUp || bytes.count > 256 || req.text.contains("\n")`
    /// → `pasteBytes`, else `sendKeys`.
    ///
    /// The 256-byte threshold matches tmux's send-keys argv limit on macOS
    /// (longer can hit posix arg-list-too-long). 256 is conservative; tmux
    /// itself allows ~2KB but Foundation's argv plumbing on macOS doesn't.
    ///
    /// - Parameters:
    ///   - text: The user's chat input. Will be appended with `\n` for
    ///     the paste path; left as-is for the send-keys path (tmux send-keys
    ///     auto-submits on its own Enter).
    ///   - isFollowUp: True if a prior turn in this session is still in
    ///     flight. Forces the paste path because send-keys against a busy
    ///     prompt can drop characters.
    /// - Returns: The strategy + the exact byte sequence to use.
    public static func strategy(forText text: String, isFollowUp: Bool) -> Strategy {
        let raw = Data(text.utf8)
        let needsPaste = isFollowUp
            || raw.count > 256
            || text.contains("\n")
        if needsPaste {
            // Append \n if not already present — pitfall fix.
            var bytes = raw
            if text.last != "\n" {
                bytes.append(0x0A)  // '\n'
            }
            return .pasteBytes(bytes: bytes)
        } else {
            return .sendKeys(bytes: raw)
        }
    }
}
