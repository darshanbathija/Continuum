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
        if needsPaste(forText: text, isFollowUp: isFollowUp) {
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

    /// The single paste-vs-keys predicate. Extracted so the tmux `strategy`
    /// path (above) and the raw-PTY `ptyWrites` path (below) can never drift
    /// on the threshold — the bug class that the `tmux-paste-buffer-needs-newline`
    /// pitfall lives in. 256-byte cap matches tmux's send-keys argv limit on macOS.
    public static func needsPaste(forText text: String, isFollowUp: Bool) -> Bool {
        isFollowUp || Data(text.utf8).count > 256 || text.contains("\n")
    }

    // MARK: - Raw-PTY rendering (ClaudePtyHost / Track A)

    /// Byte writes for submitting a prompt to a raw PTY (no tmux). Unlike the
    /// tmux path — which uses tmux *key names* (`C-u`, `Enter`) and
    /// `paste-buffer` — a raw PTY only takes bytes, so the same decision is
    /// rendered into concrete control bytes:
    ///
    /// ```
    /// chat multi-turn?           -> clear  = C-u (0x15) to wipe the input line
    /// needsPaste (long/multi/    -> payload = ESC[200~ <text> ESC[201~   (bracketed paste:
    ///   follow-up)?                            newlines stay literal, no early submit)
    /// short single-line?         -> payload = <text>                      (typed as-is)
    /// always                     -> submit  = CR (0x0d)                   (the actual Enter)
    /// ```
    ///
    /// The three fields are written in order (clear, payload, submit) by the
    /// host, with a short settle delay before `submit` so Ink's render loop
    /// commits the paste before the Enter (mirrors the tmux path's 300ms gap +
    /// the Ink `\r` quirk #15553). `submit` is ALWAYS non-empty — that is the
    /// raw-PTY equivalent of the "paste-buffer must end in a newline" invariant.
    public struct PtyWrites: Equatable, Sendable {
        /// C-u (0x15) to clear the input line before a chat multi-turn paste;
        /// nil for code sessions / first turn (a leftover-text clear isn't needed).
        public let clear: Data?
        /// The prompt bytes — bracketed-paste-wrapped when `needsPaste`, raw
        /// otherwise. Never carries the submit newline (that's `submit`).
        public let payload: Data
        /// The submit keystroke: CR (0x0d). Always present.
        public let submit: Data

        public init(clear: Data?, payload: Data, submit: Data) {
            self.clear = clear
            self.payload = payload
            self.submit = submit
        }
    }

    /// Bracketed-paste introducer `ESC [ 2 0 0 ~` and terminator `ESC [ 2 0 1 ~`.
    /// Claude's Ink TUI enables DECSET 2004, so wrapping multi-line input keeps
    /// embedded newlines literal instead of submitting on the first one.
    static let bracketedPasteStart = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
    static let bracketedPasteEnd   = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
    static let ctrlU = Data([0x15])   // clear input line
    static let carriageReturn = Data([0x0d])   // submit

    /// Render a prompt into ordered raw-PTY writes. `isChat` gates the C-u
    /// clear (chat is multi-turn into one persistent input box; code/first-turn
    /// is not). Reuses `needsPaste` so the tmux + PTY paths share one threshold.
    public static func ptyWrites(forText text: String, isFollowUp: Bool, isChat: Bool) -> PtyWrites {
        let raw = Data(text.utf8)
        let payload: Data
        if needsPaste(forText: text, isFollowUp: isFollowUp) {
            payload = bracketedPasteStart + raw + bracketedPasteEnd
        } else {
            payload = raw
        }
        return PtyWrites(
            clear: isChat ? ctrlU : nil,
            payload: payload,
            submit: carriageReturn
        )
    }
}
