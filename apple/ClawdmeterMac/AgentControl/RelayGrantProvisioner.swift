import Foundation
import CryptoKit
import OSLog
import ClawdmeterShared

private let relayGrantProvisionerLogger = Logger(
    subsystem: "com.clawdmeter.mac",
    category: "RelayGrantProvisioner"
)

public enum RelayGrantProvisionError: Error, LocalizedError, Equatable {
    case missingClientProvisioningKey
    case malformedRelayURL
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .missingClientProvisioningKey:
            return "Relay client provisioning is not configured."
        case .malformedRelayURL:
            return "Relay URL is malformed."
        case .badStatus(let status):
            return "Relay returned HTTP \(status) while provisioning grant token."
        }
    }
}

/// Resolves the relay client provisioning key used to auto-fetch grant tokens.
///
/// This is intentionally separate from `RELAY_CREATION_GRANT_TOKEN`: the
/// provisioning key only authorizes rate-limited per-install grant minting,
/// not arbitrary operator session creation.
enum RelayClientProvisioningKey {
    /// Dev/test default. Production/staging Workers must set the matching
    /// `RELAY_CLIENT_PROVISIONING_KEY` secret via `wrangler secret put`.
    private static let bundledBase64 = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="

    static func resolved(processEnv: [String: String] = ProcessInfo.processInfo.environment) -> Data? {
        if let raw = processEnv["CLAWDMETER_RELAY_CLIENT_PROVISIONING_KEY"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let decoded = decodeBase64OrUTF8(raw) {
            return decoded
        }
        return decodeBase64OrUTF8(bundledBase64)
    }

    private static func decodeBase64OrUTF8(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: Self.paddedBase64(trimmed)), data.count >= 32 {
            return data
        }
        let utf8 = Data(trimmed.utf8)
        return utf8.count >= 32 ? utf8 : nil
    }

    private static func paddedBase64(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
    }
}

/// Background client that exchanges a signed install identity for a relay
/// creation-grant token and stores it in `RelayGrantTokenStore`.
public struct RelayGrantProvisioner {
    private struct Body: Encodable {
        let installId: String
        let issuedAtSeconds: UInt64
    }

    private struct Response: Decodable {
        let grantToken: String
    }

    private let urlSession: URLSession
    private let processEnv: [String: String]
    private let installIdentity: RelayInstallIdentity
    private let grantTokenStore: RelayGrantTokenStore

    public init(
        urlSession: URLSession = .shared,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        installIdentity: RelayInstallIdentity = .shared,
        grantTokenStore: RelayGrantTokenStore = .shared
    ) {
        self.urlSession = urlSession
        self.processEnv = processEnv
        self.installIdentity = installIdentity
        self.grantTokenStore = grantTokenStore
    }

    /// Fetch and persist a grant token when none is stored yet.
    ///
    /// Tries the relay Worker's provision endpoint first (rate-limited).
    /// When that endpoint is unavailable — e.g. the Worker hasn't been
    /// redeployed yet, or the network is down — mints the same deterministic
    /// per-install token locally using the bundled client provisioning key.
    @discardableResult
    public func ensureConfigured(
        relayURL: String = RelayEnvironment.resolvedRelayURL(processEnv: ProcessInfo.processInfo.environment)
    ) async -> Bool {
        if grantTokenStore.isConfigured { return true }
        do {
            try await provision(relayURL: relayURL)
            return grantTokenStore.isConfigured
        } catch {
            relayGrantProvisionerLogger.warning(
                "Relay grant HTTP auto-provision unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return mintAndStoreLocalDeviceGrantToken()
        }
    }

    public func provision(relayURL: String) async throws {
        guard let provisioningKey = RelayClientProvisioningKey.resolved(processEnv: processEnv) else {
            throw RelayGrantProvisionError.missingClientProvisioningKey
        }
        guard let url = Self.provisionURL(relayURL: relayURL) else {
            throw RelayGrantProvisionError.malformedRelayURL
        }

        let installId = installIdentity.installId
        let issuedAtSeconds = UInt64(Date().timeIntervalSince1970)
        let authToken = Self.signProvisionRequest(
            installId: installId,
            issuedAtSeconds: issuedAtSeconds,
            provisioningKey: provisioningKey
        )

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Body(
            installId: installId,
            issuedAtSeconds: issuedAtSeconds
        ))

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw RelayGrantProvisionError.badStatus(status)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard grantTokenStore.setToken(decoded.grantToken) else {
            throw RelayGrantProvisionError.badStatus(-1)
        }
        relayGrantProvisionerLogger.info("Relay grant token auto-provisioned")
    }

    static func provisionURL(relayURL: String) -> URL? {
        let trimmed = relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed) else { return nil }
        switch components.scheme {
        case "wss":
            components.scheme = "https"
        case "ws":
            components.scheme = "http"
        default:
            return nil
        }
        components.path = "/v1/relay/provision/grant-token"
        components.query = nil
        return components.url
    }

    static func signProvisionRequest(
        installId: String,
        issuedAtSeconds: UInt64,
        provisioningKey: Data
    ) -> String {
        let message = "grant-provision:\(installId):\(issuedAtSeconds)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: provisioningKey)
        )
        return base64URLEncode(Data(mac))
    }

    /// Deterministic per-install grant token — mirrors `issueDeviceGrantToken`
    /// in `infra/relay/src/provision.ts`.
    static func mintLocalDeviceGrantToken(
        installId: String,
        provisioningKey: Data
    ) -> String {
        let message = "device-grant-v1:\(installId)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: provisioningKey)
        )
        return "\(installId).\(base64URLEncode(Data(mac)))"
    }

    private func mintAndStoreLocalDeviceGrantToken() -> Bool {
        guard let provisioningKey = RelayClientProvisioningKey.resolved(processEnv: processEnv) else {
            relayGrantProvisionerLogger.error("Relay grant auto-provision failed: missing client provisioning key")
            return false
        }
        let token = Self.mintLocalDeviceGrantToken(
            installId: installIdentity.installId,
            provisioningKey: provisioningKey
        )
        guard grantTokenStore.setToken(token) else {
            relayGrantProvisionerLogger.error("Relay grant auto-provision failed: keychain store failed")
            return false
        }
        relayGrantProvisionerLogger.info("Relay grant token minted locally")
        return true
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
