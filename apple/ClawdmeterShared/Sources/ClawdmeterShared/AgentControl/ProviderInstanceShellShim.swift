import Foundation

/// Generates one-word Terminal wrappers for secondary provider accounts.
///
/// When a user adds a second Claude or Codex subscription in Settings →
/// Providers, Continuum installs `~/.local/bin/<kind>-<name>` (e.g.
/// `claude-work`) so the isolated account is usable from any shell the
/// same way `claude` / `codex` launch the primary.
public enum ProviderInstanceShellShim {

    public static let shimMarkerPrefix = "# continuum-provider-shim "

    /// `claude-personal`, `codex-work`, …
    public static func commandName(for instance: ProviderInstanceId) -> String? {
        guard supportsShellShim(instance) else { return nil }
        return "\(instance.kind.rawValue)-\(instance.name)"
    }

    /// Secondary Claude/Codex instances with a config root get a shim.
    public static func supportsShellShim(_ instance: ProviderInstanceId) -> Bool {
        guard !instance.isPrimary else { return false }
        guard let root = instance.configRoot, !root.isEmpty else { return false }
        return ProviderInstanceEnvironment.configDirVariable(for: instance.kind) != nil
    }

    /// Shell script body for `instance`. nil when the instance can't be
    /// shimmed (primary, missing config root, or non-isolatable kind).
    public static func script(for instance: ProviderInstanceId) -> String? {
        guard supportsShellShim(instance),
              let configRoot = instance.configRoot,
              !configRoot.isEmpty else {
            return nil
        }
        switch instance.kind {
        case .claude:
            return claudeScript(
                wireId: instance.wireId,
                configRoot: configRoot,
                tokenService: claudeTokenServiceName(for: instance)
            )
        case .codex:
            return codexScript(wireId: instance.wireId, configRoot: configRoot)
        default:
            return nil
        }
    }

    /// Keychain service name for a secondary Claude instance's OAuth
    /// token — must match `PastedAnthropicTokenProvider.forInstance`.
    public static func claudeTokenServiceName(for instance: ProviderInstanceId) -> String {
        "\(PastedAnthropicTokenProvider.defaultService).\(instance.wireId)"
    }

    // MARK: - Script templates

    private static func claudeScript(
        wireId: String,
        configRoot: String,
        tokenService: String
    ) -> String {
        let quotedConfig = shellSingleQuoted(configRoot)
        let quotedService = shellSingleQuoted(tokenService)
        return """
        #!/usr/bin/env bash
        \(shimMarkerPrefix)\(wireId)
        set -euo pipefail
        CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
        if [[ -z "$CLAUDE_BIN" ]]; then
          echo "claude CLI not found on PATH — install Claude Code first." >&2
          exit 1
        fi
        TOKEN=$(security find-generic-password -s \(quotedService) -w 2>/dev/null) || {
          echo "No token for \(wireId) — re-authenticate in Continuum → Settings → Providers." >&2
          exit 1
        }
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
        export CLAUDE_CONFIG_DIR=\(quotedConfig)
        export CLAUDE_CODE_OAUTH_TOKEN="$TOKEN"
        exec "$CLAUDE_BIN" "$@"
        """
    }

    private static func codexScript(wireId: String, configRoot: String) -> String {
        let quotedConfig = shellSingleQuoted(configRoot)
        return """
        #!/usr/bin/env bash
        \(shimMarkerPrefix)\(wireId)
        set -euo pipefail
        CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"
        if [[ -z "$CODEX_BIN" ]]; then
          echo "codex CLI not found on PATH — install the Codex CLI first." >&2
          exit 1
        fi
        unset OPENAI_API_KEY CODEX_API_KEY
        export CODEX_HOME=\(quotedConfig)
        exec "$CODEX_BIN" "$@"
        """
    }

    /// POSIX-safe single-quoted literal for embedding paths in shell.
    public static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
