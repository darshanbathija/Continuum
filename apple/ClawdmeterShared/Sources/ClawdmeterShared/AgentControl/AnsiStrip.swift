import Foundation

/// Strip ANSI/VT escape sequences from raw PTY output (Track A).
///
/// `ClaudePtyHost.recentOutput()` reads a raw PTY byte stream that carries SGR
/// color codes, cursor moves, and OSC title sets interleaved with the visible
/// text. We do NOT need a full terminal emulator — the only consumers are
/// (1) spawn-readiness ("does the tail contain Claude's ready marker?") and
/// (2) auth/update detection ("does it contain a login/usage/error string?").
/// Both are substring matches, so a lightweight escape stripper is enough; a
/// VT grid emulator would be over-built with no consumer (per the eng review).
///
/// Pure + in the shared package so it is unit-testable under `swift test`.
public enum AnsiStrip {

    private static let esc: UInt8 = 0x1b   // ESC
    private static let bel: UInt8 = 0x07   // BEL (OSC terminator)
    private static let backslash: UInt8 = 0x5c // '\' (ST terminator: ESC \)

    /// Remove escape sequences and non-printable control bytes (keeping `\n`
    /// and `\t`) from a UTF-8 string. Handles:
    /// - CSI: `ESC [` … final byte in 0x40–0x7E
    /// - OSC: `ESC ]` … terminated by BEL or ST (`ESC \`)
    /// - other 2-byte `ESC <byte>` sequences (e.g. `ESC =`)
    public static func plain(_ string: String) -> String {
        let bytes = Array(string.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b == esc {
                guard i + 1 < n else { break }   // dangling ESC at end
                let next = bytes[i + 1]
                if next == 0x5b {                // ESC [  → CSI
                    i += 2
                    while i < n, !(bytes[i] >= 0x40 && bytes[i] <= 0x7e) { i += 1 }
                    if i < n { i += 1 }          // consume the final byte
                } else if next == 0x5d {         // ESC ]  → OSC
                    i += 2
                    while i < n {
                        if bytes[i] == bel { i += 1; break }
                        if bytes[i] == esc, i + 1 < n, bytes[i + 1] == backslash { i += 2; break }
                        i += 1
                    }
                } else {                          // other 2-byte ESC sequence
                    i += 2
                }
                continue
            }
            // Keep printable bytes + newline/tab; drop other C0 controls.
            if b >= 0x20 || b == 0x0a || b == 0x09 {
                out.append(b)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
