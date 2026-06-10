import Foundation
import ClawdmeterShared

public struct CustomProviderProbeResult: Sendable, Equatable {
    public let success: Bool
    public let models: [CustomProviderModel]
    public let httpStatus: Int?
    public let errorDetail: String?

    public init(
        success: Bool,
        models: [CustomProviderModel] = [],
        httpStatus: Int? = nil,
        errorDetail: String? = nil
    ) {
        self.success = success
        self.models = models
        self.httpStatus = httpStatus
        self.errorDetail = errorDetail
    }
}

public actor CustomProviderAPIProbe {
    public static let shared = CustomProviderAPIProbe()

    private let sessionConfiguration: URLSessionConfiguration

    public init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.sessionConfiguration = sessionConfiguration
    }

    public func testConnection(
        kind: CustomProviderKind,
        baseURL: String,
        apiKey: String
    ) async -> CustomProviderProbeResult {
        await fetchModels(kind: kind, baseURL: baseURL, apiKey: apiKey)
    }

    public func fetchModels(
        kind: CustomProviderKind,
        baseURL: String,
        apiKey: String
    ) async -> CustomProviderProbeResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return CustomProviderProbeResult(success: false, errorDetail: "API key is empty")
        }
        guard let url = modelsURL(baseURL: baseURL) else {
            return CustomProviderProbeResult(success: false, errorDetail: "Invalid base URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        applyAuthHeaders(kind: kind, apiKey: trimmedKey, to: &request)

        do {
            let session = URLSession(configuration: sessionConfiguration)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return CustomProviderProbeResult(success: false, errorDetail: "Invalid HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = Self.errorDetail(from: data, fallback: "HTTP \(http.statusCode)")
                return CustomProviderProbeResult(
                    success: false,
                    httpStatus: http.statusCode,
                    errorDetail: detail
                )
            }
            let models = try Self.parseModels(data)
            guard !models.isEmpty else {
                return CustomProviderProbeResult(
                    success: false,
                    httpStatus: http.statusCode,
                    errorDetail: "No models returned"
                )
            }
            return CustomProviderProbeResult(
                success: true,
                models: models,
                httpStatus: http.statusCode
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                return CustomProviderProbeResult(success: false, errorDetail: "Request timed out")
            }
            return CustomProviderProbeResult(success: false, errorDetail: error.localizedDescription)
        }
    }

    private func modelsURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + "/v1/models")
    }

    private func applyAuthHeaders(
        kind: CustomProviderKind,
        apiKey: String,
        to request: inout URLRequest
    ) {
        switch kind {
        case .openAICompatible:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropicCompatible:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }

    static func parseModels(_ data: Data) throws -> [CustomProviderModel] {
        let json = try JSONSerialization.jsonObject(with: data)
        if let dict = json as? [String: Any], let dataArray = dict["data"] as? [[String: Any]] {
            return parseModelObjects(dataArray)
        }
        if let array = json as? [[String: Any]] {
            return parseModelObjects(array)
        }
        if let dict = json as? [String: Any], let models = dict["models"] as? [[String: Any]] {
            return parseModelObjects(models)
        }
        throw URLError(.cannotParseResponse)
    }

    private static func parseModelObjects(_ objects: [[String: Any]]) -> [CustomProviderModel] {
        var seen = Set<String>()
        var models: [CustomProviderModel] = []
        for object in objects {
            guard let rawId = object["id"] as? String else { continue }
            let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            let displayName = (object["display_name"] as? String)
                ?? (object["name"] as? String)
            models.append(CustomProviderModel(id: id, displayName: displayName?.nilIfEmpty))
        }
        return models
    }

    private static func errorDetail(from data: Data, fallback: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return fallback
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
