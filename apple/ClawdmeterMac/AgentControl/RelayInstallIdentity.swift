import Foundation
import Security
import OSLog

private let relayInstallLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RelayInstallIdentity")

/// Stable per-Mac install identifier used to auto-provision relay grant tokens.
///
/// Generated once on first use, stored in the login Keychain (device-local,
/// not iCloud-synced). The relay returns a deterministic grant token bound to
/// this install id so pairing QRs can be minted without manual operator setup.
public final class RelayInstallIdentity {
    public static let shared = RelayInstallIdentity()

    private static let serviceName = "com.clawdmeter.relay.install-id"
    private static let account = "default"

    private let lock = NSLock()
    private var cachedInstallId: String?

    public init() {}

    public var installId: String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedInstallId { return cachedInstallId }
        if let stored = readFromKeychain() {
            cachedInstallId = stored
            return stored
        }
        let fresh = UUID().uuidString.lowercased()
        writeToKeychain(fresh)
        cachedInstallId = fresh
        relayInstallLogger.info("Generated relay install identity")
        return fresh
    }

    private func readFromKeychain() -> String? {
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

    private func writeToKeychain(_ value: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        guard let data = value.data(using: .utf8) else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
