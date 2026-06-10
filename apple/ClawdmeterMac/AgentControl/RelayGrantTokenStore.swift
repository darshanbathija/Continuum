import Foundation
import Security
import OSLog

private let relayGrantStoreLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RelayGrantTokenStore")

/// Keychain custodian for the relay creation-grant token — the Bearer the Mac
/// presents to the relay Worker's `POST /sessions/:id/creation-grant` endpoint
/// so a fresh pairing QR can mint a server-signed session-creation proof.
///
/// Why Keychain, not the app bundle: `infra/SECRETS.md` is explicit — the
/// grant token must never be embedded in the shipped binary (anyone could
/// extract it and mint pairings against our relay). Instead the user pastes it
/// once into Settings → Pair iPhone; it lives in the login Keychain, gated by
/// the user's session. `RelayPairingCreationGrantClient` reads it here first,
/// falling back to the `CLAWDMETER_RELAY_CREATION_GRANT_TOKEN` env var for dev
/// builds running under `wrangler dev`.
public final class RelayGrantTokenStore {
    public static let shared = RelayGrantTokenStore()

    private static let serviceName = "com.clawdmeter.relay.creation-grant"
    private static let account = "default"

    public init() {}

    /// The stored token, or nil if none has been saved. Returns nil on any
    /// Keychain miss/error so callers degrade to the env-var fallback rather
    /// than throwing during `RelayPairingService.init`.
    public var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var isConfigured: Bool { token != nil }

    /// Save (or replace) the grant token. An empty/whitespace value clears it.
    @discardableResult
    public func setToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return true
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Delete-then-add so a re-paste overwrites cleanly.
        clear()
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            relayGrantStoreLogger.error("Failed to store relay grant token: \(status)")
            return false
        }
        relayGrantStoreLogger.info("Relay grant token saved")
        return true
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
