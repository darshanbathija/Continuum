// E7: cross-platform pairing-record persistence.
//
// iOS uses this to remember "I scanned a QR from Mac X at time T and
// derived this symmetric key" so the future E4 RelayClient can pick up
// the key without re-prompting the user. The Mac side uses an in-memory
// equivalent for now — its half of the keypair is ephemeral and dies
// with the app per §5b (forward secrecy by construction).
//
// Persistence strategy:
//   - Wire bundle (sid, tokens, peer pubkey, ttl, relayUrl) → JSON in
//     a single file in the app's `Application Support` directory.
//   - Derived symmetric key K → Keychain (kSecAttrSynchronizable=false,
//     kSecAttrAccessibleAfterFirstUnlock) so an iCloud Keychain sync
//     can't smuggle K to another device.
//
// The split is deliberate: a forensic image of the filesystem leaks the
// QR contents (which were already on the user's screen and which become
// useless after TTL), but the symmetric key sits behind the iOS Secure
// Enclave + Keychain ACL.
//
// IMPORTANT: this file is in `ClawdmeterShared` so iOS and Mac code can
// both link against it, but `RelayPairingStore` is only INSTANTIATED by
// iOS in E7. The Mac path holds its half in-process via the Mac-only
// `RelayPairingService`.

import Foundation
#if canImport(Security)
import Security
#endif

/// Persistent store for the most recent successful pairing. Single
/// pairing only in v1 (Open Question 1 + Group F).
public final class RelayPairingStore: @unchecked Sendable {

    /// Defaults to a per-app file under `Application Support`. Tests
    /// inject a tmpdir.
    public static let shared = RelayPairingStore()

    private let lock = NSLock()
    private let fileURL: URL
    private let keychainService: String
    private let keychainAccount = "relay-pairing-symmetric-key"

    public init(
        fileURL: URL? = nil,
        keychainService: String = "com.clawdmeter.relay.pairing"
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            // Mirror the rest of the app: per-bundle subdir under Application Support.
            let dir = support.appendingPathComponent("Clawdmeter", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("relay-pairing.json", isDirectory: false)
        }
        self.keychainService = keychainService
    }

    // MARK: - Read

    /// Returns the persisted record (without the symmetric key — that
    /// stays in Keychain). The phase is inferred from presence: if a
    /// record exists, the phase is `.readyButNotConnected`.
    public func loadRecord() -> RelayPairingRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RelayPairingRecord.self, from: data)
    }

    /// Returns the persisted symmetric key (32 bytes) or nil if none.
    public func loadSymmetricKey() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return readKeychain()
    }

    // MARK: - Write

    /// Persist a fresh record + symmetric key after a successful
    /// scan + HKDF derivation. Atomic on the JSON write; Keychain ops
    /// are atomic by construction.
    public func save(record: RelayPairingRecord, symmetricKey: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(record)
        try data.write(to: fileURL, options: [.atomic])
        writeKeychain(symmetricKey)
    }

    /// Drop the pairing record + symmetric key. Used by the "Forget
    /// pairing" affordance in iOS Settings.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
        deleteKeychain()
    }

    // MARK: - Keychain helpers

    #if canImport(Security)
    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            // Per §5b: the symmetric key is per-device + per-pairing.
            // Do NOT sync to iCloud — a stolen iCloud backup mustn't
            // resurrect a session.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func readKeychain() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    private func writeKeychain(_ data: Data) {
        deleteKeychain()
        var query = keychainQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(query as CFDictionary, nil)
    }

    private func deleteKeychain() {
        _ = SecItemDelete(keychainQuery() as CFDictionary)
    }
    #else
    private func readKeychain() -> Data? {
        nil
    }

    private func writeKeychain(_: Data) {}

    private func deleteKeychain() {}
    #endif
}
