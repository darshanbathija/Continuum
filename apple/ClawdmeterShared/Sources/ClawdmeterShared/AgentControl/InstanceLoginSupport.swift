import Foundation

/// Extracts the long-lived subscription OAuth token that
/// `claude setup-token` prints at the end of its browser OAuth flow.
///
/// PTY output arrives in arbitrary chunks — the token can split across
/// reads and is interleaved with ANSI escape sequences (spinners,
/// colors). The scanner keeps a bounded ANSI-stripped tail buffer and
/// regex-matches on every ingest, so a token is recognized no matter
/// how the chunk boundaries fall.
///
/// The matched token never leaves this type except via the `ingest`
/// return value — callers store it straight into the per-instance
/// Keychain partition and must not log it.
public struct ClaudeSetupTokenScanner: Sendable {

    /// `setup-token` emits `sk-ant-oat01-<base64url-ish>`. Anchor on the
    /// stable prefix; the tail charset matches Anthropic's OAuth token
    /// alphabet. 40+ chars filters out the bare prefix echoed in docs
    /// or help text.
    public static let tokenPattern = "sk-ant-oat01-[A-Za-z0-9_-]{40,}"

    /// Keep enough tail to span any realistic PTY chunking of a token
    /// (tokens are a few hundred bytes; 4KB is generous) without
    /// retaining the whole transcript in memory.
    private let maxTailBytes: Int
    private var tail: String = ""

    public init(maxTailBytes: Int = 4096) {
        self.maxTailBytes = maxTailBytes
    }

    /// Feed a raw PTY chunk. Returns the token the first time one is
    /// fully visible in the (ANSI-stripped) rolling tail, else nil.
    public mutating func ingest(_ chunk: Data) -> String? {
        guard let text = String(data: chunk, encoding: .utf8)
            ?? String(data: chunk, encoding: .isoLatin1) else { return nil }
        tail += Self.strippingANSI(text)
        if tail.count > maxTailBytes {
            tail = String(tail.suffix(maxTailBytes))
        }
        guard let range = tail.range(of: Self.tokenPattern, options: .regularExpression) else {
            return nil
        }
        let token = String(tail[range])
        // Drop the buffer so the secret doesn't linger in memory and a
        // re-print of the same token doesn't double-fire.
        tail = ""
        return token
    }

    /// Remove ANSI escape/control sequences (CSI, OSC, simple ESC-x)
    /// plus carriage returns so cursor-redraw output can't split a
    /// token mid-match.
    static func strippingANSI(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
            with: "",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "\u{1B}.",
            with: "",
            options: .regularExpression
        )
        // \r becomes a line BREAK, not a deletion: a spinner overwrite
        // that printed a truncated token then redrew the full one must
        // not concatenate the fragment into the real token (the token
        // alphabet includes '-', so a merged string regex-matches as
        // one corrupted token).
        out = out.replacingOccurrences(of: "\r", with: "\n")
        return out
    }
}

/// Validates that a Codex instance's `codex login` actually produced a
/// usable credential file. `auth.json` can exist mid-write (the CLI
/// creates then fills it), so presence alone is not completion — the
/// bytes must parse as an auth bundle carrying either ChatGPT tokens or
/// an API key.
public enum CodexAuthProbe {

    /// `<configRoot>/auth.json`, mirroring `$CODEX_HOME/auth.json`.
    public static func authFileURL(configRoot: URL) -> URL {
        configRoot.appendingPathComponent("auth.json")
    }

    public static func validAuthExists(configRoot: URL) -> Bool {
        let url = authFileURL(configRoot: configRoot)
        guard let data = try? Data(contentsOf: url) else { return false }
        let decoder = JSONDecoder()
        guard let bundle = try? decoder.decode(CodexTokenProvider.AuthBundle.self, from: data) else {
            return false
        }
        if let tokens = bundle.tokens, !tokens.accessToken.isEmpty { return true }
        if let key = bundle.openaiApiKey, !key.isEmpty { return true }
        return false
    }
}
