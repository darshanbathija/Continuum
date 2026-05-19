// Pure-Swift line parser for `~/.gemini/antigravity/antigravity_state.pbtxt`.
//
// The state file is Google's protobuf text format — a forgiving, line-based
// "key: value" shape that we can read without dragging in the swift-protobuf
// runtime. Sample (real, from a live install):
//
//     post_onboarding:  {
//       completed_steps:  POST_ONBOARDING_STEP_TYPE_MANAGER_WELCOME
//       completed_steps:  POST_ONBOARDING_STEP_TYPE_USAGE_MODE
//     }
//     seen_nuxs:  {
//       uids:  23
//     }
//     agent_onboarding_completed:  AGENT_ONBOARDING_STATE_COMPLETED
//     last_selected_agent_model:  MODEL_PLACEHOLDER_M133
//     migrate_convos_into_projects:  MIGRATION_STATUS_COMPLETED
//     installation_uuid:  "fd6a5ba1-7a30-425a-aba1-4f0cdc5b1361"
//
// We only care about a handful of top-level scalars:
//   - `last_selected_agent_model` (opaque enum like `MODEL_PLACEHOLDER_M133`)
//   - `installation_uuid` (string)
//   - `migrate_convos_into_projects` (enum: `MIGRATION_STATUS_{PENDING,COMPLETED}`)
//
// The opaque model token resolves to a display name (`gemini-3.5-flash`)
// via a lookup map. When the map doesn't know the token, callers can fall
// back to `LanguageServerClient.currentModel()` (Commit 8) which queries
// the running Electron app, or render the raw token.

import Foundation

/// Parsed contents of `antigravity_state.pbtxt`. Everything is optional —
/// the file is allowed to omit fields, and forward-compat means we don't
/// crash on unknown ones.
public struct AntigravityState: Equatable, Sendable {
    /// Raw token from `last_selected_agent_model:` (e.g. `MODEL_PLACEHOLDER_M133`).
    /// Use `displayModelName` for the human-facing string.
    public let lastSelectedAgentModelToken: String?
    /// Stable installation UUID (string, unquoted in the parsed struct).
    public let installationUUID: String?
    /// Migration status enum. `.unknown` when the file omits the field or
    /// uses an enum value we don't recognize.
    public let migrationStatus: MigrationStatus

    /// Resolved display name (`gemini-3.5-flash`, `gemini-3-pro`, …) or
    /// the raw token if the lookup map doesn't know it. Nil only when the
    /// `last_selected_agent_model` field is absent entirely.
    public var displayModelName: String? {
        guard let token = lastSelectedAgentModelToken else { return nil }
        return AntigravityStateReader.modelDisplayName(forToken: token) ?? token
    }

    /// Migration status of the historical Gemini CLI v0.42 conversations
    /// into Antigravity 2's `conversations/` projects layout.
    public enum MigrationStatus: String, Equatable, Sendable {
        case pending = "MIGRATION_STATUS_PENDING"
        case completed = "MIGRATION_STATUS_COMPLETED"
        case unknown
    }

    public init(
        lastSelectedAgentModelToken: String?,
        installationUUID: String?,
        migrationStatus: MigrationStatus
    ) {
        self.lastSelectedAgentModelToken = lastSelectedAgentModelToken
        self.installationUUID = installationUUID
        self.migrationStatus = migrationStatus
    }
}

/// Reads + parses `antigravity_state.pbtxt`. Pure functions; no caching —
/// the file is tiny (under 1KB) and only read on dashboard refresh.
public enum AntigravityStateReader {
    /// Parses the state file at the given URL. Returns a populated
    /// `AntigravityState` even when fields are missing (all-optional).
    /// Throws only when the file can't be read at all (permissions /
    /// missing). Malformed lines are silently skipped.
    public static func read(at url: URL) throws -> AntigravityState {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            // The file is supposed to be UTF-8 text-proto. If it isn't,
            // return an all-nil state rather than throwing — the dashboard
            // can degrade to "Antigravity (unknown state)" instead of
            // crashing.
            return AntigravityState(
                lastSelectedAgentModelToken: nil,
                installationUUID: nil,
                migrationStatus: .unknown
            )
        }
        return parse(text: text)
    }

    /// Parses a raw text-proto string into an `AntigravityState`. Exposed
    /// so tests can hand in literal fixtures without writing temp files.
    public static func parse(text: String) -> AntigravityState {
        var model: String?
        var uuid: String?
        var migration: AntigravityState.MigrationStatus = .unknown

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Only consume top-level scalars. Nested `{ ... }` blocks (like
            // `post_onboarding {}` or `seen_nuxs {}`) are stepped over by
            // the loop without us recursing — their inner lines pass
            // through the same matcher and are filtered out because the
            // keys we care about don't appear nested.
            if let (key, value) = extractKeyValue(from: line) {
                switch key {
                case "last_selected_agent_model":
                    model = stripQuotes(value)
                case "installation_uuid":
                    uuid = stripQuotes(value)
                case "migrate_convos_into_projects":
                    migration = AntigravityState.MigrationStatus(rawValue: stripQuotes(value)) ?? .unknown
                default:
                    continue
                }
            }
        }

        return AntigravityState(
            lastSelectedAgentModelToken: model,
            installationUUID: uuid,
            migrationStatus: migration
        )
    }

    /// Resolves an opaque model token (e.g. `MODEL_PLACEHOLDER_M133`) into
    /// a human-readable name (e.g. `gemini-3.5-flash`). Returns nil if
    /// we don't know the mapping — the caller should fall back to either
    /// the raw token or `LanguageServerClient.currentModel()`.
    ///
    /// Mapping derived from Antigravity 2.0.0's bundled `agy-node` source
    /// (Electron resources, `enum_to_display.js`). Update this map when
    /// Antigravity ships new model placeholders.
    public static func modelDisplayName(forToken token: String) -> String? {
        knownModelTokens[token]
    }

    /// Static lookup map. Internal so tests can assert the canonical key.
    static let knownModelTokens: [String: String] = [
        "MODEL_PLACEHOLDER_M133": "gemini-3.5-flash",
        "MODEL_PLACEHOLDER_M132": "gemini-3-pro",
        "MODEL_PLACEHOLDER_M131": "gemini-3-flash",
        "MODEL_PLACEHOLDER_M130": "gemini-3-pro-low",
        "MODEL_PLACEHOLDER_M129": "gemini-2.5-flash",
    ]

    // MARK: - Parsing primitives

    /// Splits `key: value` and `key { ... }` lines. Returns nil for lines
    /// that are pure braces, comments, or otherwise not a scalar key=value.
    static func extractKeyValue(from line: String) -> (String, String)? {
        // text-proto allows `key: value`, `key:value`, and `key { ... }`.
        // The brace form is a block; we skip it (return nil) because we
        // only consume scalars.
        if line.hasSuffix("{") || line == "}" { return nil }
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        if key.isEmpty || value.isEmpty { return nil }
        // Discard trailing comments (`# ...`). Tokens don't contain `#`.
        if let hashIdx = value.firstIndex(of: "#") {
            let trimmed = String(value[..<hashIdx]).trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : (key, trimmed)
        }
        return (key, value)
    }

    /// Strips a single pair of wrapping double-quotes if present. Leaves
    /// the inner string untouched — Antigravity's text-proto doesn't
    /// escape inner quotes for the keys we read.
    static func stripQuotes(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        return String(raw.dropFirst().dropLast())
    }
}
