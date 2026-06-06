import Foundation

/// Line-oriented parser for tmux `-CC` control-mode output.
///
/// Usage:
///   var parser = ControlModeParser()
///   for byte in incomingStdoutChunk { parser.feed(byte) }
///   while let frame = parser.nextFrame() { handle(frame) }
///
/// Wire shape (each line terminated by `\n`):
/// ```
/// %begin 1747327891 17 1
/// (response body lines — raw text, NOT octal-escaped)
/// %end 1747327891 17 1
/// %output %3 hello\\012world
/// %window-add @4
/// %layout-change @3 5e1f,80x24,0,0,3
/// %exit
/// ```
///
/// `%output` bodies use octal escapes for non-printable bytes per the tmux
/// source (`output1` in `notify.c`): backslash itself is `\\\\`, control
/// chars and high-bit bytes are `\\xxx` (3-digit octal). UTF-8 multi-byte
/// sequences may straddle `%output` frame boundaries — keep raw bytes per
/// pane and let the consumer (SwiftTerm) handle UTF-8.
public struct ControlModeParser {

    /// Pending lines buffered as bytes (terminated by `\n` to emit a frame).
    private var lineBuffer: [UInt8] = []

    /// Decoded frames awaiting consumption.
    private var pendingFrames: [ControlModeFrame] = []

    public init() {}

    /// Feed one byte from the tmux server's stdout stream.
    public mutating func feed(_ byte: UInt8) {
        if byte == 0x0A {  // newline terminates a line
            // Strip trailing CR if present (PTY canonical-mode output emits
            // CRLF; raw pipes emit just LF). Without this, integer parsing
            // on the last field of `%end <ts> <num> <flags>\r` fails because
            // `Int("0\r")` returns nil.
            if lineBuffer.last == 0x0D {
                lineBuffer.removeLast()
            }
            let line = String(decoding: lineBuffer, as: UTF8.self)
            lineBuffer.removeAll(keepingCapacity: true)
            if let frame = ControlModeParser.parseLine(line) {
                pendingFrames.append(frame)
            } else if !line.isEmpty {
                // v0.8 QA: lines without a `%` prefix are command-response
                // body content (the lines between %begin and %end). Previously
                // dropped, which silently broke every newWindow / listWindows /
                // splitWindow that depended on the response body. Now emit as
                // .body frames; TmuxControlClient's handle() accumulates them
                // into currentCommandBody between begin/end. Empty lines are
                // still dropped (tmux pads some responses with blanks).
                pendingFrames.append(.body(line: line))
            }
        } else {
            lineBuffer.append(byte)
        }
    }

    /// Feed a chunk of bytes at once.
    public mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes { feed(b) }
    }

    /// Pop the next decoded frame, if any.
    public mutating func nextFrame() -> ControlModeFrame? {
        guard !pendingFrames.isEmpty else { return nil }
        return pendingFrames.removeFirst()
    }

    /// Pop ALL pending frames at once. Useful in test setups.
    public mutating func drainFrames() -> [ControlModeFrame] {
        let frames = pendingFrames
        pendingFrames.removeAll(keepingCapacity: true)
        return frames
    }

    // MARK: - Line dispatcher

    /// Parse one terminated line. Returns `nil` if the line is non-%-prefixed
    /// (command-response body) or malformed in a recoverable way.
    static func parseLine(_ line: String) -> ControlModeFrame? {
        guard line.hasPrefix("%") else { return nil }

        // Split on the first space. tmux uses whitespace-delimited tokens for
        // its directives; %output is special because the body is the rest of
        // the line including escapes.
        let stripped = String(line.dropFirst())  // drop leading "%"
        guard let firstSpace = stripped.firstIndex(of: " ") else {
            // Bare directive (e.g. `%exit`)
            return frame(forDirective: stripped, rest: "")
        }
        let directive = String(stripped[..<firstSpace])
        let rest = String(stripped[stripped.index(after: firstSpace)...])
        return frame(forDirective: directive, rest: rest)
    }

    private static func frame(forDirective directive: String, rest: String) -> ControlModeFrame {
        switch directive {
        case "begin":
            if let (ts, num, flags) = parseTimestampedHeader(rest) {
                return .begin(timestamp: ts, number: num, flags: flags)
            }
        case "end":
            if let (ts, num, flags) = parseTimestampedHeader(rest) {
                return .end(timestamp: ts, number: num, flags: flags)
            }
        case "error":
            if let (ts, num, flags) = parseTimestampedHeader(rest) {
                return .error(timestamp: ts, number: num, flags: flags)
            }
        case "output":
            // Body: "%<paneid> <octal-escaped bytes>"
            if let (paneId, escaped) = splitPaneAndBody(rest) {
                let bytes = decodeOctalEscapes(escaped)
                return .output(paneId: paneId, bytes: bytes)
            }
        case "window-add":
            return .windowAdd(windowId: rest.trimmingCharacters(in: .whitespaces))
        case "window-close":
            return .windowClose(windowId: rest.trimmingCharacters(in: .whitespaces))
        case "window-rename":
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return .windowRename(windowId: parts[0], newName: parts[1])
            }
        case "layout-change":
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return .layoutChange(windowId: parts[0], layout: parts[1])
            }
        case "session-changed":
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return .sessionChanged(sessionId: parts[0], name: parts[1])
            }
        case "session-renamed":
            return .sessionRenamed(name: rest.trimmingCharacters(in: .whitespaces))
        case "sessions-changed":
            return .sessionsChanged
        case "session-window-changed":
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return .sessionWindowChanged(sessionId: parts[0], windowId: parts[1])
            }
        case "client-session-changed":
            let parts = rest.split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count == 3 {
                return .clientSessionChanged(client: parts[0], sessionId: parts[1], name: parts[2])
            }
        case "window-renamed":
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return .windowRenamed(windowId: parts[0], newName: parts[1])
            }
        case "paste-buffer-changed":
            return .pasteBufferChanged(name: rest.trimmingCharacters(in: .whitespaces))
        case "paste-buffer-deleted":
            return .pasteBufferDeleted(name: rest.trimmingCharacters(in: .whitespaces))
        case "pane-mode-changed":
            return .paneModeChanged(paneId: rest.trimmingCharacters(in: .whitespaces))
        case "subscription-changed":
            return .subscriptionChanged(raw: rest)
        case "client-detached":
            return .clientDetached(client: rest.trimmingCharacters(in: .whitespaces))
        case "pause":
            return .pause(paneId: rest.trimmingCharacters(in: .whitespaces))
        case "continue":
            return .continueOutput(paneId: rest.trimmingCharacters(in: .whitespaces))
        case "exit":
            let reason = rest.trimmingCharacters(in: .whitespaces)
            return .exit(reason: reason.isEmpty ? nil : reason)
        default:
            break
        }
        return .unknown(raw: "%" + directive + (rest.isEmpty ? "" : " " + rest))
    }

    // MARK: - Helpers

    /// Parse `<ts> <num> <flags>` (three integers separated by spaces).
    private static func parseTimestampedHeader(_ rest: String) -> (Int64, Int, Int)? {
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3,
              let ts = Int64(parts[0]),
              let num = Int(parts[1]),
              let flags = Int(parts[2])
        else {
            return nil
        }
        return (ts, num, flags)
    }

    /// Split `%output` body into pane id and escaped bytes.
    ///
    /// Body shape: `%<paneid> <bytes>` (note the pane id starts with `%`).
    /// We strip the leading `%` and find the first space; the remainder is
    /// the octal-escaped body.
    private static func splitPaneAndBody(_ rest: String) -> (paneId: String, escaped: String)? {
        guard rest.hasPrefix("%") else { return nil }
        let afterPct = rest.dropFirst()
        guard let space = afterPct.firstIndex(of: " ") else {
            // tmux sometimes emits `%output %<paneid>` with empty body. Treat
            // as zero-length output.
            return (paneId: String(afterPct), escaped: "")
        }
        let paneId = String(afterPct[..<space])
        let escaped = String(afterPct[afterPct.index(after: space)...])
        return (paneId, escaped)
    }

    /// Decode tmux's octal-escape format back to raw bytes.
    ///
    /// Rules per tmux source (`format.c::format_quote_for_buffer`):
    /// - `\\\\` → 0x5C (backslash)
    /// - `\\<3-digit-octal>` → the byte value
    /// - everything else passes through as ASCII bytes
    ///
    /// Per Codex eng-round reviewer concern: UTF-8 multi-byte sequences may
    /// be split across `%output` frames. We decode bytes here without
    /// interpreting them as characters — the consumer (SwiftTerm or whoever
    /// concatenates `%output` per pane) handles UTF-8.
    static func decodeOctalEscapes(_ escaped: String) -> Data {
        var out = Data()
        var i = escaped.startIndex
        while i < escaped.endIndex {
            let c = escaped[i]
            if c == "\\" {
                let next = escaped.index(after: i)
                guard next < escaped.endIndex else {
                    out.append(0x5C)
                    i = next
                    continue
                }
                let nc = escaped[next]
                if nc == "\\" {
                    out.append(0x5C)
                    i = escaped.index(after: next)
                } else if nc.isASCII, let _ = nc.asciiValue, "01234567".contains(nc) {
                    // 3-digit octal escape
                    let octEnd = escaped.index(next, offsetBy: 3, limitedBy: escaped.endIndex) ?? escaped.endIndex
                    if escaped.distance(from: next, to: octEnd) == 3 {
                        let octalString = String(escaped[next..<octEnd])
                        if let byteValue = UInt8(octalString, radix: 8) {
                            out.append(byteValue)
                            i = octEnd
                            continue
                        }
                    }
                    // Malformed escape — emit the backslash, advance one
                    out.append(0x5C)
                    i = next
                } else {
                    // Unknown escape — emit the backslash, advance one
                    out.append(0x5C)
                    i = next
                }
            } else {
                // Pass through ASCII byte; non-ASCII chars shouldn't appear
                // in the escaped form (tmux escapes them as octal) but be
                // defensive.
                if let ascii = c.asciiValue {
                    out.append(ascii)
                } else {
                    // Multi-byte UTF-8 sneaking through; emit raw UTF-8 bytes.
                    out.append(contentsOf: Array(String(c).utf8))
                }
                i = escaped.index(after: i)
            }
        }
        return out
    }
}
