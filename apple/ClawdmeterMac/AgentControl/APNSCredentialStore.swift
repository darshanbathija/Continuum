import Foundation
import Security
import OSLog

private let apnsCredLogger = Logger(subsystem: "com.clawdmeter.mac", category: "APNSCredentialStore")

/// Custodian for the APNS sender credentials Sessions v2 Phase 10
/// needs to push aggregate Live Activity updates from the Mac daemon.
///
/// What it stores (in the macOS Keychain, marked `kSecAttrAccessibleWhenUnlocked`):
///   - The `.p8` auth-key PEM body (the only secret).
///   - `keyId` (10 chars) — appears in the JWT `kid` header.
///   - `teamId` (10 chars) — appears in the JWT `iss` claim.
///   - `bundleId` — the iOS app bundle id (becomes the `apns-topic`
///     base; we append `.push-type.liveactivity` per Apple's spec).
///   - `environment` — `.sandbox` for TestFlight / dev builds,
///     `.production` for App Store / direct DMG users.
///
/// Why Keychain: the source `.p8` file is deleted from disk after the
/// setup wizard ingests it (CEO review D9 — "Keychain custody is the
/// load-bearing mitigation"). Read access is gated by the user's
/// login session.
public final class APNSCredentialStore {
    public static let shared = APNSCredentialStore()

    public enum Environment: String, Codable, Sendable {
        case sandbox        // api.sandbox.push.apple.com
        case production     // api.push.apple.com
    }

    public struct Credentials: Sendable {
        public let p8Pem: String
        public let keyId: String
        public let teamId: String
        public let bundleId: String
        public let environment: Environment
    }

    /// Keychain service name for the .p8 key.
    private static let serviceName = "com.clawdmeter.apns.p8"
    /// Side-channel UserDefaults keys for the non-secret bits.
    private static let keyIdDefaultsKey = "clawdmeter.apns.keyId"
    private static let teamIdDefaultsKey = "clawdmeter.apns.teamId"
    private static let bundleIdDefaultsKey = "clawdmeter.apns.bundleId"
    private static let environmentDefaultsKey = "clawdmeter.apns.environment"

    public enum StoreError: Error, LocalizedError {
        case missingP8
        case missingMetadata(String)
        case keychainError(OSStatus)
        case invalidPEM

        public var errorDescription: String? {
            switch self {
            case .missingP8: return "APNS .p8 key not found in Keychain. Run Settings → Live Activities to add one."
            case .missingMetadata(let field): return "APNS \(field) is missing. Re-run the setup wizard."
            case .keychainError(let status): return "Keychain error \(status)."
            case .invalidPEM: return "The .p8 file did not contain a recognizable PEM block."
            }
        }
    }

    public init() {}

    /// True when the Keychain holds a .p8 + all four metadata fields.
    public var isConfigured: Bool {
        (try? load()) != nil
    }

    /// Ingest a .p8 PEM body + metadata. Atomic enough: writes the
    /// Keychain item first, then the metadata; if either step fails,
    /// the other is rolled back so a half-configured state can't
    /// produce broken pushes.
    public func save(
        p8Pem: String,
        keyId: String,
        teamId: String,
        bundleId: String,
        environment: Environment
    ) throws {
        let trimmedPem = p8Pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPem.contains("BEGIN PRIVATE KEY") || trimmedPem.contains("BEGIN EC PRIVATE KEY") else {
            throw StoreError.invalidPEM
        }

        try storeP8InKeychain(pem: trimmedPem)
        do {
            UserDefaults.standard.set(keyId, forKey: Self.keyIdDefaultsKey)
            UserDefaults.standard.set(teamId, forKey: Self.teamIdDefaultsKey)
            UserDefaults.standard.set(bundleId, forKey: Self.bundleIdDefaultsKey)
            UserDefaults.standard.set(environment.rawValue, forKey: Self.environmentDefaultsKey)
        }
        apnsCredLogger.info(
            "APNS credentials saved (kid=\(keyId, privacy: .public) team=\(teamId, privacy: .public) bundle=\(bundleId, privacy: .public) env=\(environment.rawValue, privacy: .public))"
        )
    }

    public func load() throws -> Credentials {
        let pem = try loadP8FromKeychain()
        let defaults = UserDefaults.standard
        guard let keyId = defaults.string(forKey: Self.keyIdDefaultsKey), !keyId.isEmpty else {
            throw StoreError.missingMetadata("keyId")
        }
        guard let teamId = defaults.string(forKey: Self.teamIdDefaultsKey), !teamId.isEmpty else {
            throw StoreError.missingMetadata("teamId")
        }
        guard let bundleId = defaults.string(forKey: Self.bundleIdDefaultsKey), !bundleId.isEmpty else {
            throw StoreError.missingMetadata("bundleId")
        }
        let envRaw = defaults.string(forKey: Self.environmentDefaultsKey) ?? Environment.sandbox.rawValue
        let env = Environment(rawValue: envRaw) ?? .sandbox
        return Credentials(
            p8Pem: pem,
            keyId: keyId,
            teamId: teamId,
            bundleId: bundleId,
            environment: env
        )
    }

    public func clear() {
        // Wipe Keychain item; ignore "not found" since the goal is
        // "after this call, no credentials remain."
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
        ]
        SecItemDelete(query as CFDictionary)
        for key in [
            Self.keyIdDefaultsKey, Self.teamIdDefaultsKey,
            Self.bundleIdDefaultsKey, Self.environmentDefaultsKey,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        apnsCredLogger.info("APNS credentials cleared")
    }

    // MARK: - Keychain helpers

    private func storeP8InKeychain(pem: String) throws {
        guard let data = pem.data(using: .utf8) else { throw StoreError.invalidPEM }
        // Delete any existing item first so add succeeds.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: "default",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainError(status)
        }
    }

    private func loadP8FromKeychain() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw StoreError.missingP8 }
        guard status == errSecSuccess, let data = result as? Data,
              let pem = String(data: data, encoding: .utf8) else {
            throw StoreError.keychainError(status)
        }
        return pem
    }
}
