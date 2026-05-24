#if os(macOS)
import Foundation
import Compression
#if canImport(OSLog)
import OSLog
#endif

/// v0.26.6 Tier-1 LS-local quota probe for AntigravitySource.
///
/// Talks to the Antigravity 2 desktop app's local `language_server` (a gRPC
/// service on a localhost port discovered via `lsof` by `AntigravityLSPClient
/// .discover()`). Returns real usage data when Antigravity 2 is running and
/// the user is signed in. Caller (`AntigravitySource.poll`) treats `nil` as
/// "LS not reachable / not signed in" and falls through to Tier 2
/// (`cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`).
///
/// **Why this exists at all**: Tier 2 requires a `~/.gemini/oauth_creds.json`
/// that only exists if the user has run `gemini auth login` from a terminal.
/// Antigravity 2 desktop signs in via the GUI without ever writing that file,
/// so for a user whose only Gemini surface is Antigravity 2, Tier 2 always
/// fails → tile reads `0% / "resets in —"`. Tier 1 bridges that gap by
/// asking the running LSP what it knows about the user's quota.
///
/// **Schema** (reverse-engineered from a live Antigravity 2.0.6 LSP, with
/// no published `.proto` — see `apple/ClawdmeterShared/Tests/Clawdmeter
/// SharedTests/AgentControl/AntigravityLSQuotaProbeIntegrationTests.swift`
/// for the probe that captured the wire format):
///
/// ```
/// GetUserStatus response (proto, server-gzipped on the wire):
///   1 = User wrapper {
///     3 = string  name
///     7 = string  email
///     13 = AccountQuota {
///       1 = PlanCap {
///         2 = string   plan name (e.g. "Pro", "Plus")
///         7 = int      context window (tokens)
///         8 = int      daily message cap        ← cap
///         12,13,14 = ints (other limits)
///         …
///       }
///       8 = int  daily messages used            ← used
///       9 = int  daily messages remaining       ← remaining
///       …
///     }
///     33 = ModelEntry [] {
///       1 = string  display name
///       2 { 1 = int  internal model id }
///       15 = ModelUsage {
///         1 = fixed32 (float)  remainingFraction (1.0 = full)
///         2 { 1 = int  resetsAt unix epoch seconds }
///       }
///       16 = string  speed badge ("Fast", "Pro", …)
///       17 = string  plan badge ("Limited time", …)
///     }
///   }
/// ```
///
/// We surface `13.8 / (13.8 + 13.9)` as the session percent and the first
/// model's `15.2.1` as the reset epoch. Plan name (`13.1.2`) is stashed into
/// the returned UsageData's `organizationID` slot so the UI has a hook for
/// the badge text (downstream tiles can pull "Antigravity • Pro" from there).
///
/// **TOS posture**: the LSP is an internal Google interface; we accept the
/// same risk class as `CodexSource` against `chatgpt.com/backend-api/...`.
public enum AntigravityLSQuotaProbe {

    private static let logger = Logger(subsystem: "com.clawdmeter.shared", category: "AntigravityLSQuotaProbe")

    /// Top-level probe entry point. Returns `nil` on any failure path:
    /// no LSP discovered, gRPC failure, decompression failure, protobuf
    /// parse failure, missing critical fields. Designed to be safe to
    /// call on every poll (target ~50ms when LSP is up, near-zero when
    /// not — `discover()` short-circuits on no matching processes).
    public static func probe() async -> UsageData? {
        logger.info("AntigravityLSQuotaProbe: probe() called — attempting LSP discovery")
        guard let endpoint = AntigravityLSPClient.discover() else {
            logger.info("AntigravityLSQuotaProbe: discover() returned nil — no running language_server (or lsof inaccessible in sandbox)")
            return nil
        }
        logger.info("AntigravityLSQuotaProbe: discovered endpoint at port \(endpoint.port, privacy: .public)")
        let client = AntigravityLSPClient(endpoint: endpoint)
        let raw: Data
        do {
            raw = try await client.unary(
                fullMethod: "/exa.language_server_pb.LanguageServerService/GetUserStatus",
                requestBody: Data()
            )
        } catch {
            logger.info("AntigravityLSQuotaProbe: LSP unary failed — \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let bytes = decompressIfGzip(raw) else {
            logger.info("AntigravityLSQuotaProbe: gzip decompression failed (\(raw.count, privacy: .public) bytes)")
            return nil
        }
        return parseGetUserStatus(bytes, now: Date())
    }

    // MARK: - Parser

    /// Parses the `GetUserStatus` protobuf body into a `UsageData`. Exposed
    /// `internal` for the fixture-based unit test.
    static func parseGetUserStatus(_ bytes: Data, now: Date) -> UsageData? {
        var reader = LSProtoReader(bytes: bytes)
        // Top-level message: field 1 is the User wrapper.
        guard let userBytes = reader.findLengthDelimited(field: 1) else { return nil }

        var userReader = LSProtoReader(bytes: userBytes)

        // Field 13 = AccountQuota
        guard let quotaBytes = userReader.findLengthDelimited(field: 13) else { return nil }
        userReader.reset()

        // Field 33 = repeated ModelEntry. We only need the first one's reset epoch
        // since every entry on the captured fixture carries the same value.
        let firstModel = userReader.findLengthDelimited(field: 33)

        // Parse quota: field 8 = used, field 9 = remaining, field 1 = PlanCap{2: planName}
        var quotaReader = LSProtoReader(bytes: quotaBytes)
        let used = quotaReader.findVarint(field: 8) ?? 0
        quotaReader.reset()
        let remaining = quotaReader.findVarint(field: 9) ?? 0
        quotaReader.reset()
        let planCapBytes = quotaReader.findLengthDelimited(field: 1)
        let planName: String? = {
            guard let pcb = planCapBytes else { return nil }
            var pcReader = LSProtoReader(bytes: pcb)
            return pcReader.findString(field: 2)
        }()

        // Daily total = used + remaining. Avoid divide-by-zero by bailing
        // when both fields are missing (the LSP returns a non-quota envelope
        // for a not-signed-in user; let the caller fall through to Tier 2).
        let total = used + remaining
        guard total > 0 else {
            logger.info("AntigravityLSQuotaProbe: empty quota (used=\(used, privacy: .public), remaining=\(remaining, privacy: .public)) — likely not signed in")
            return nil
        }
        let sessionPct = Int(((Double(used) / Double(total)) * 100.0).rounded())

        // Reset epoch: drill into the field 33 wrapper, which holds repeated
        // `1 { ... }` entries (a PlanInfo header followed by per-model entries).
        // Find the first inner entry whose schema includes field 15 (the
        // ModelUsage submessage) and pull `field 15.2.1` = resets_at. Every
        // model entry on the captured fixture carries the same epoch, so any
        // model's value is representative.
        //
        // When no model entry is available (rare — usually means the user has
        // zero entitled models), fall back to "now + 24h" so the gauge
        // renders rather than collapsing the whole probe to nil.
        let nowEpoch = Int(now.timeIntervalSince1970)
        let resetEpoch: Int = {
            guard let f33Bytes = firstModel else { return nowEpoch + 24 * 3600 }
            var f33Reader = LSProtoReader(bytes: f33Bytes)
            while let entryBytes = f33Reader.findLengthDelimited(field: 1) {
                var entryReader = LSProtoReader(bytes: entryBytes)
                guard let usageBytes = entryReader.findLengthDelimited(field: 15) else { continue }
                var uReader = LSProtoReader(bytes: usageBytes)
                guard let innerBytes = uReader.findLengthDelimited(field: 2) else { continue }
                var iReader = LSProtoReader(bytes: innerBytes)
                if let epoch = iReader.findVarint(field: 1) {
                    return Int(epoch)
                }
            }
            return nowEpoch + 24 * 3600
        }()
        let resetMins = max(0, (resetEpoch - nowEpoch + 59) / 60)

        // Only one window is exposed (daily reset). Mirror into the weekly
        // bucket so the UI's "Weekly" row reads the same value rather than 0%.
        return UsageData(
            sessionPct: sessionPct,
            sessionResetMins: resetMins,
            sessionEpoch: resetEpoch,
            weeklyPct: sessionPct,
            weeklyResetMins: resetMins,
            weeklyEpoch: resetEpoch,
            status: resetEpoch <= nowEpoch ? .notStarted : .allowed,
            representativeClaim: .fiveHour,
            updatedAt: now,
            organizationID: planName
        )
    }

    // MARK: - Gzip decompression

    /// Decompress a gzip-wrapped payload using libcompression's raw deflate
    /// codec (gzip-aware unwrap that strips the 10-byte header + 8-byte
    /// trailer, then feeds the deflate body to COMPRESSION_ZLIB —
    /// libcompression accepts the bare deflate stream this way).
    ///
    /// Returns `nil` for non-gzip input or any decode error.
    static func decompressIfGzip(_ data: Data) -> Data? {
        // gzip magic 1f 8b 08 (last byte is the compression method = deflate)
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 0x08 else {
            return data
        }
        let flags = data[3]
        var headerEnd = 10
        if (flags & 0x04) != 0 {
            // FEXTRA: skip XLEN + extra bytes
            guard headerEnd + 2 <= data.count else { return nil }
            let xlen = Int(data[headerEnd]) | (Int(data[headerEnd + 1]) << 8)
            headerEnd += 2 + xlen
        }
        if (flags & 0x08) != 0 {
            // FNAME: null-terminated string
            while headerEnd < data.count && data[headerEnd] != 0 { headerEnd += 1 }
            headerEnd += 1
        }
        if (flags & 0x10) != 0 {
            // FCOMMENT: null-terminated string
            while headerEnd < data.count && data[headerEnd] != 0 { headerEnd += 1 }
            headerEnd += 1
        }
        if (flags & 0x02) != 0 {
            // FHCRC: 2 bytes header crc
            headerEnd += 2
        }
        let trailerStart = data.count - 8
        guard headerEnd < trailerStart else { return nil }
        let deflateBytes = data[headerEnd..<trailerStart]

        let dstCapacity = max(deflateBytes.count * 8, 4096)
        var dst = Data(count: dstCapacity)
        var written = -1
        deflateBytes.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) in
            guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                let n = compression_decode_buffer(
                    dstBase, dstCapacity,
                    srcBase, deflateBytes.count,
                    nil,
                    COMPRESSION_ZLIB
                )
                written = n
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }
}

// MARK: - Minimal protobuf reader

/// Forward-only tag walker for protobuf wire format. Only supports the
/// field types this probe actually reads: varint, length-delimited (bytes /
/// string / submessage), and fixed32 (float). Other wire types are skipped.
///
/// Intentionally **not** a general-purpose proto decoder — we only own the
/// schema for `GetUserStatus`, and adding full proto support would mean
/// vendoring Google's runtime. Keeping this tiny + schema-targeted limits
/// the maintenance surface to the fields this one probe needs.
private struct LSProtoReader {
    /// Normalized to start at index 0 — `Data` slices preserve their parent's
    /// absolute startIndex, which broke a previous version of this reader
    /// when the bytes came from a sub-field extraction. Copying into a
    /// zero-based `Data` makes index math local to this reader.
    let bytes: Data
    var index: Int

    init(bytes: Data) {
        self.bytes = Data(bytes)
        self.index = 0
    }

    mutating func reset() {
        index = 0
    }

    /// Find the next length-delimited field with the requested number,
    /// starting at the current cursor. Advances the cursor past the value.
    mutating func findLengthDelimited(field: Int) -> Data? {
        while index < bytes.endIndex {
            guard let (fieldNumber, wireType) = readTag() else { return nil }
            if wireType == 2 {
                guard let len = readVarint() else { return nil }
                let count = Int(len)
                guard index + count <= bytes.endIndex else { return nil }
                let slice = bytes[index..<(index + count)]
                index += count
                if fieldNumber == field { return Data(slice) }
            } else if !skip(wireType: wireType) {
                return nil
            }
        }
        return nil
    }

    /// Find the next varint field with the requested number.
    mutating func findVarint(field: Int) -> UInt64? {
        while index < bytes.endIndex {
            guard let (fieldNumber, wireType) = readTag() else { return nil }
            if wireType == 0 {
                guard let v = readVarint() else { return nil }
                if fieldNumber == field { return v }
            } else if !skip(wireType: wireType) {
                return nil
            }
        }
        return nil
    }

    /// Find the next string field with the requested number.
    mutating func findString(field: Int) -> String? {
        guard let data = findLengthDelimited(field: field) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Wire-format primitives

    private mutating func readTag() -> (field: Int, wireType: Int)? {
        guard let raw = readVarint() else { return nil }
        let fieldNumber = Int(raw >> 3)
        let wireType = Int(raw & 0x07)
        return (fieldNumber, wireType)
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if (byte & 0x80) == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private mutating func skip(wireType: Int) -> Bool {
        switch wireType {
        case 0:
            return readVarint() != nil
        case 1:
            // 64-bit fixed
            guard index + 8 <= bytes.endIndex else { return false }
            index += 8
            return true
        case 2:
            guard let len = readVarint() else { return false }
            let count = Int(len)
            guard index + count <= bytes.endIndex else { return false }
            index += count
            return true
        case 5:
            // 32-bit fixed
            guard index + 4 <= bytes.endIndex else { return false }
            index += 4
            return true
        default:
            return false
        }
    }
}
#endif // os(macOS)
