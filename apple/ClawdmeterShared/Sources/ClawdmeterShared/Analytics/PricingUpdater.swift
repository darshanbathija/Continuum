import Foundation
#if canImport(os)
import os
#endif

/// Keeps the *installed* app's pricing current without a rebuild.
///
/// The app ships an embedded `pricing.json` snapshot (regenerated at build time
/// by `tools/refresh-pricing.sh`), but a frozen snapshot goes stale the moment a
/// new model ships — e.g. Opus 4.8 launched 2026-05-28 and was priced at $0
/// until the snapshot was refreshed. This updater closes that gap at runtime:
/// on launch and once per day it fetches the upstream LiteLLM table, applies the
/// same provider filter + manual overrides as `refresh-pricing.sh`, writes the
/// result to a cache in Application Support, and hot-reloads `Pricing.shared`.
///
/// Best-effort: any failure (offline, HTTP error, malformed JSON) leaves the
/// existing cache or the embedded snapshot in place — analytics never breaks.
public actor PricingUpdater {
    public static let shared = PricingUpdater()

    #if canImport(os)
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "PricingUpdater")
    #endif

    // Best-effort logging keeps `os` privacy interpolation out of call sites.
    private func logError(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data((message + "\n").utf8))
        #endif
    }
    private func logInfo(_ message: String) {
        #if canImport(os)
        logger.info("\(message, privacy: .public)")
        #else
        _ = message
        #endif
    }

    private static let source = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    /// Same provider filter as tools/refresh-pricing.sh.
    private static let providerPattern = "^(claude-|gpt-|o[0-9]+($|-)|chatgpt-|gemini-|gemma-|grok-|xai/)"
    private var inFlight = false

    private init() {}

    /// Refresh only when the cache is missing or older than `maxAge` (24h default).
    /// Cheap to call on every launch.
    @discardableResult
    public func refreshIfStale(maxAge: TimeInterval = 86_400) async -> Bool {
        if let url = Pricing.cacheURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge {
            return false
        }
        return await refresh()
    }

    /// Fetch → filter → merge overrides → cache → hot-reload `Pricing.shared`.
    /// Returns true on a successful refresh.
    @discardableResult
    public func refresh() async -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        defer { inFlight = false }
        do {
            var request = URLRequest(url: Self.source)
            request.timeoutInterval = 20
            let (data, response) = try await Self.fetchData(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                logError("PricingUpdater: HTTP \(http.statusCode)")
                return false
            }
            guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logError("PricingUpdater: unexpected JSON shape")
                return false
            }

            // Step 1: filter to the providers Clawdmeter tracks.
            let regex = try NSRegularExpression(pattern: Self.providerPattern, options: [.caseInsensitive])
            var models: [String: Any] = [:]
            for (key, value) in raw where key != "sample_spec" {
                let range = NSRange(key.startIndex..<key.endIndex, in: key)
                if regex.firstMatch(in: key, options: [], range: range) != nil {
                    models[key] = value
                }
            }
            // Step 2: manual overrides win (mirrors refresh-pricing.sh).
            for (key, value) in Self.bundledOverrides() { models[key] = value }

            let snapshot: [String: Any] = [
                "_meta": [
                    "source": Self.source.absoluteString,
                    "capturedAt": ISO8601DateFormatter().string(from: Date()),
                    "runtimeRefresh": true,
                ],
                "models": models,
            ]
            let out = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])

            guard let cacheURL = Pricing.cacheURL else { return false }
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try out.write(to: cacheURL, options: .atomic)
            Pricing.shared.reload(from: out)
            logInfo("PricingUpdater cached \(models.count) models from LiteLLM")
            return true
        } catch {
            logError("PricingUpdater refresh failed: \(String(describing: error))")
            return false
        }
    }

    /// Cross-version data fetch. Bridging the completion-handler `dataTask`
    /// through a continuation keeps behavior consistent across Apple toolchains.
    private static func fetchData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }

    /// The `overrides` object from the bundled pricing-overrides.json.
    private static func bundledOverrides() -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "pricing-overrides", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let overrides = obj["overrides"] as? [String: Any] else {
            return [:]
        }
        return overrides
    }
}
