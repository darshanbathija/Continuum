// Reads the macOS Keychain entries Antigravity 2 + the Gemini CLI store
// for at-rest encryption of their local conversation data.
//
// Discovery (2026-05-23): a live install at the workspace path produced
// two readable items via `security find-generic-password`:
//
//   service="Antigravity Safe Storage"  account="Antigravity"
//     → 16-byte base64 string. Chromium/Electron `safeStorage` pattern.
//       Used by the Electron IDE shell to encrypt cookies + Local
//       Storage. Not the key that wraps conversation files.
//
//   service="Gemini Safe Storage"       account="Gemini Keys"
//     → protobuf-wrapped bundle (hex). Carries two 32-byte AES keys
//       — an active key + one rotation slot — keyed by ID 1 and 2.
//       This is what wraps the on-disk `.pb` files at
//       `~/.gemini/antigravity/conversations/*.pb`.
//
// Why this file ships before we actually decrypt anything:
//   - The Keychain capability + proto parse are independently testable
//     and useful for diagnostics ("can Clawdmeter see your Antigravity
//     install?"). Wiring them into a decryption path is its own R&D
//     scope (the .pb on-disk wrapping format isn't standard Electron
//     safeStorage — no `v10` magic prefix, no PBKDF2 with "saltysalt").
//   - Per `ConversationProtoParser.swift`'s "SDK mode" note, the
//     planned production path is to introspect the running Antigravity
//     LSP's `agent.conversation.total_usage` rather than decrypt
//     offline. The Keychain key remains useful for that path too —
//     anything that wants to talk to the LSP authenticated needs it.
//   - The new SQLite `.db` desktop format has *plaintext* `step_payload`
//     blobs (see `AntigravityConversationDB.swift` header), so the
//     bigger near-term analytics win is parsing those — no key needed.
//
// First-access prompt policy: passive diagnostics must not open a macOS
// SecurityAgent prompt while the user is switching tabs. We request
// non-interactive Keychain access and return nil when the item needs
// approval, is missing, or is otherwise unavailable.

#if os(macOS)
import Foundation
import LocalAuthentication
import Security

/// Static reader for Antigravity-owned Keychain items. Stateless; safe
/// to call from any actor or thread.
public enum AntigravityKeychainKeys {

    // MARK: - Generic Keychain read

    /// Reads a generic-password Keychain item. Returns the value as
    /// `Data` on success, nil when the item is missing, the user
    /// denied access, or any other Security framework error. Errors
    /// are swallowed deliberately — the caller's flow should degrade
    /// gracefully (fall back to estimate-mode, hide a UI affordance,
    /// etc.) rather than propagating Keychain errors up.
    public static func readGenericPassword(service: String, account: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        PassiveKeychainAccess.apply(to: &query)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    // MARK: - Antigravity Electron Safe Storage

    /// 16-byte base64-encoded random key used by the Electron IDE
    /// shell. Useful for sanity-check ("is Antigravity installed?")
    /// even if we never use the key itself. Returns the raw base64
    /// string, not the decoded 16 bytes.
    public static func electronSafeStorageKey() -> String? {
        guard let data = readGenericPassword(
            service: "Antigravity Safe Storage",
            account: "Antigravity"
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Gemini conversation-encryption key bundle

    /// One AES key + its metadata, parsed out of the Gemini Safe
    /// Storage bundle. The 32-byte `material` is the AES key
    /// material. `id` discriminates active vs. rotation: the active
    /// key matches the bundle's `activeKeyID`.
    public struct GeminiKey: Equatable, Sendable {
        public let id: UInt64
        public let version: UInt64
        public let createdAt: UInt64
        public let material: Data
    }

    /// Parsed view of the protobuf bundle stored at
    /// `Gemini Safe Storage` / `Gemini Keys`. The on-the-wire shape
    /// (reverse-engineered from a live install on 2026-05-23) is:
    ///
    ///   message KeyBundle {
    ///     uint64 active_key_id = 1;
    ///     repeated Key keys = 2;
    ///   }
    ///   message Key {
    ///     uint64 id = 1;
    ///     uint64 version = 2;
    ///     uint64 created_at = 3;
    ///     bytes  material = 4;     // 32 bytes
    ///   }
    public struct GeminiKeyBundle: Equatable, Sendable {
        public let activeKeyID: UInt64
        public let keys: [GeminiKey]

        /// The key whose `id` matches `activeKeyID`. Returns nil when
        /// the bundle's active ID points at a key we don't have on
        /// hand — shouldn't happen on a healthy install but the
        /// caller should fail soft.
        public var active: GeminiKey? {
            keys.first(where: { $0.id == activeKeyID })
        }
    }

    /// Reads the raw bundle bytes from Keychain. Hex-encoded UTF-8
    /// string (the format `security` prints with `-w`).
    public static func geminiKeyBundleRawHex() -> String? {
        guard let data = readGenericPassword(
            service: "Gemini Safe Storage",
            account: "Gemini Keys"
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads + parses the Gemini Safe Storage bundle. Returns nil when
    /// the item is missing or unparseable. Never throws.
    public static func geminiKeyBundle() -> GeminiKeyBundle? {
        guard let hex = geminiKeyBundleRawHex() else { return nil }
        return parseGeminiKeyBundle(hex: hex)
    }

    // MARK: - Proto parser (exposed for tests)

    /// Parses a hex-encoded Gemini Safe Storage payload into a
    /// `GeminiKeyBundle`. Exposed so unit tests can feed a captured
    /// fixture without touching real Keychain.
    public static func parseGeminiKeyBundle(hex: String) -> GeminiKeyBundle? {
        guard let data = Data(hex: hex) else { return nil }
        var reader = ProtoReader(data: data)
        var activeKeyID: UInt64 = 0
        var keys: [GeminiKey] = []
        while !reader.isAtEnd {
            guard let tag = reader.readTag() else { return nil }
            switch tag.fieldNumber {
            case 1 where tag.wireType == .varint:
                guard let v = reader.readVarint() else { return nil }
                activeKeyID = v
            case 2 where tag.wireType == .lengthDelimited:
                guard let bytes = reader.readLengthDelimited() else { return nil }
                if let key = parseGeminiKey(data: bytes) {
                    keys.append(key)
                }
            default:
                // Unknown field: skip it.
                if !reader.skip(wireType: tag.wireType) { return nil }
            }
        }
        return GeminiKeyBundle(activeKeyID: activeKeyID, keys: keys)
    }

    private static func parseGeminiKey(data: Data) -> GeminiKey? {
        var reader = ProtoReader(data: data)
        var id: UInt64 = 0
        var version: UInt64 = 0
        var createdAt: UInt64 = 0
        var material = Data()
        while !reader.isAtEnd {
            guard let tag = reader.readTag() else { return nil }
            switch tag.fieldNumber {
            case 1 where tag.wireType == .varint:
                guard let v = reader.readVarint() else { return nil }
                id = v
            case 2 where tag.wireType == .varint:
                guard let v = reader.readVarint() else { return nil }
                version = v
            case 3 where tag.wireType == .varint:
                guard let v = reader.readVarint() else { return nil }
                createdAt = v
            case 4 where tag.wireType == .lengthDelimited:
                guard let bytes = reader.readLengthDelimited() else { return nil }
                material = bytes
            default:
                if !reader.skip(wireType: tag.wireType) { return nil }
            }
        }
        guard !material.isEmpty else { return nil }
        return GeminiKey(id: id, version: version, createdAt: createdAt, material: material)
    }
}

// MARK: - Minimal protobuf reader (self-contained)

/// Self-contained protobuf wire-format reader. We deliberately don't
/// pull in swift-protobuf for this — we're parsing one tiny shape
/// (~30 lines of wire format) and a runtime dep would be overkill.
/// Same approach `ConversationProtoParser.decode` uses for step blobs.
private struct ProtoReader {
    private let data: Data
    private var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = 0
    }

    var isAtEnd: Bool { offset >= data.count }

    enum WireType: Int {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    struct Tag {
        let fieldNumber: Int
        let wireType: WireType
    }

    mutating func readTag() -> Tag? {
        guard let raw = readVarint() else { return nil }
        let fieldNumber = Int(raw >> 3)
        guard let wireType = WireType(rawValue: Int(raw & 0x7)) else { return nil }
        return Tag(fieldNumber: fieldNumber, wireType: wireType)
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[data.startIndex + offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    mutating func readLengthDelimited() -> Data? {
        guard let length = readVarint() else { return nil }
        let len = Int(length)
        guard offset + len <= data.count else { return nil }
        let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + len))
        offset += len
        return slice
    }

    /// Skip past a field of unknown wire type so unknown future
    /// proto extensions don't break parsing.
    mutating func skip(wireType: WireType) -> Bool {
        switch wireType {
        case .varint:
            return readVarint() != nil
        case .fixed64:
            guard offset + 8 <= data.count else { return false }
            offset += 8
            return true
        case .lengthDelimited:
            return readLengthDelimited() != nil
        case .fixed32:
            guard offset + 4 <= data.count else { return false }
            offset += 4
            return true
        }
    }
}

// MARK: - Hex helper

private extension Data {
    /// Initialize from a hex string. Whitespace and `0x` prefixes are
    /// ignored; an odd-length input returns nil. Lowercase or
    /// uppercase digits both accepted.
    init?(hex raw: String) {
        let trimmed = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "0x", with: "")
        guard trimmed.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: trimmed.count / 2)
        var iter = trimmed.makeIterator()
        while let hi = iter.next(), let lo = iter.next() {
            guard let h = hi.hexDigitValue, let l = lo.hexDigitValue else { return nil }
            data.append(UInt8(h * 16 + l))
        }
        self = data
    }
}

#endif
