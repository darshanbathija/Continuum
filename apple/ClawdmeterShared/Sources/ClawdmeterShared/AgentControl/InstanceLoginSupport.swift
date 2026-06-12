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

/// Decode a JWT payload segment without signature verification. Used only
/// to read display metadata (email) from locally stored OAuth tokens.
public enum JWTPayloadReader: Sendable {

    public static func decodePayloadJSON(_ jwt: String) -> Data? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return base64URLDecode(String(parts[1]))
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

#if os(macOS)
/// Resolves the signed-in email for a configured provider instance.
/// Claude hits Anthropic's private `/api/oauth/profile` endpoint; Codex
/// reads the `id_token` JWT from the instance's `auth.json`.
public enum ProviderAccountEmailResolver: Sendable {

    public static func email(for instance: ProviderInstanceId) async -> String? {
        switch instance.kind {
        case .claude:
            return await claudeEmail(for: instance)
        case .codex:
            return codexEmail(for: instance)
        default:
            return nil
        }
    }

    private static func claudeEmail(for instance: ProviderInstanceId) async -> String? {
        let provider = PastedAnthropicTokenProvider.forInstance(instance)
        let token: String?
        if provider.hasToken {
            token = provider.currentAccessToken
        } else if instance.isPrimary {
            token = KeychainTokenProvider(allowsUserInteraction: false).currentAccessToken
        } else {
            token = nil
        }
        guard let token, !token.isEmpty else { return nil }
        return await fetchClaudeProfileEmail(token: token)
    }

    private static func fetchClaudeProfileEmail(token: String) async -> String? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-cli/2.1.143 (external, cli)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let profile = try JSONDecoder().decode(ClaudeOAuthProfile.self, from: data)
            return profile.account.email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        } catch {
            return nil
        }
    }

    private static func codexEmail(for instance: ProviderInstanceId) -> String? {
        let authPath: URL
        if instance.isPrimary {
            authPath = ClawdmeterRealHome.url().appendingPathComponent(".codex/auth.json")
        } else if let root = instance.configRoot, !root.isEmpty {
            authPath = CodexAuthProbe.authFileURL(configRoot: URL(fileURLWithPath: root))
        } else {
            return nil
        }
        guard let data = try? Data(contentsOf: authPath),
              let bundle = try? JSONDecoder().decode(CodexTokenProvider.AuthBundle.self, from: data),
              let idToken = bundle.tokens?.idToken,
              !idToken.isEmpty else {
            return nil
        }
        return ChatGPTIdTokenClaims.email(fromJWT: idToken)
    }

    private struct ClaudeOAuthProfile: Decodable {
        struct Account: Decodable {
            let email: String?
        }
        let account: Account
    }

    private struct ChatGPTIdTokenClaims: Decodable {
        let email: String?
        let profile: ProfileClaims?

        struct ProfileClaims: Decodable {
            let email: String?
        }

        enum CodingKeys: String, CodingKey {
            case email
            case profile = "https://api.openai.com/profile"
        }

        static func email(fromJWT jwt: String) -> String? {
            guard let payload = JWTPayloadReader.decodePayloadJSON(jwt),
                  let claims = try? JSONDecoder().decode(ChatGPTIdTokenClaims.self, from: payload) else {
                return nil
            }
            if let direct = claims.email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return direct
            }
            return claims.profile?.email?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
#endif
