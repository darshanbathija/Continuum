// Lifecycle manager for the Clawdmeter Codex SDK-mode Node sidecar.
//
// v0.7.1 ships REAL `npm install @openai/codex-sdk` provisioning into
// ~/Library/Application Support/Clawdmeter/codex-sdk/. On first toggle
// ON the manager:
//
//   1. Ensures the AppSupport dir exists.
//   2. Writes a synthetic package.json declaring the SDK dependency.
//   3. Copies main.mjs from the repo (or bundle Resources in production)
//      into AppSupport so `import "@openai/codex-sdk"` resolves.
//   4. Runs `npm install @openai/codex-sdk` (~25s on a cold cache).
//   5. Probes the now-provisioned sidecar with a `probe` agent header
//      to validate the SDK loads cleanly.
//   6. On success: persists `clawdmeter.codex.sdkProvisioned = true`,
//      stores the SDK version, sets the toggle to ON.
//   7. On any step failure: reverts toggle to OFF, stores the error
//      message in `lastProvisioningError` for Settings → Diagnostics.
//
// Subsequent toggle ON cycles fast-path past the install step — the
// AppSupport dir + node_modules persist across launches, so the
// re-enable cost is ~500ms (just the probe).
//
// **Auth contract** (recap): the Codex SDK reads ~/.codex/auth.json on
// startup. When `auth_mode: "chatgpt"` is set + tokens present, no
// API key needed. The manager doesn't touch auth — the SDK + CLI own it.

import Foundation
import OSLog

/// Codex SDK sidecar manager. Real impl in v0.7.1.
@MainActor
public final class CodexSDKManager {

    public static let shared = CodexSDKManager()

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "CodexSDKManager")
    private let userDefaults = UserDefaults.standard
    private let sdkModeKey = "clawdmeter.codex.sdkMode"
    private let provisionedKey = "clawdmeter.codex.sdkProvisioned"
    private let provisionedVersionKey = "clawdmeter.codex.sdkProvisionedVersion"

    /// Last error from a provisioning attempt. Rendered in Settings →
    /// Diagnostics. Nil when no attempt has been made or last attempt
    /// succeeded.
    public private(set) var lastProvisioningError: String?

    /// True iff the SDK has been successfully installed into AppSupport
    /// at least once and the install dir + node_modules still exist.
    /// Drives the "Toggle ON is fast" path.
    public var isProvisioned: Bool {
        userDefaults.bool(forKey: provisionedKey) && sdkInstallExists()
    }

    /// Read-only view of the SDK mode toggle.
    public var sdkModeActive: Bool {
        userDefaults.bool(forKey: sdkModeKey)
    }

    /// Recorded SDK version from the most recent successful provision.
    public var provisionedSDKVersion: String? {
        userDefaults.string(forKey: provisionedVersionKey)
    }

    // MARK: - Public API

    /// Attempts to enable SDK mode. v0.7.1 path:
    ///   - If already provisioned: probe + flip toggle ON in <1s.
    ///   - If not provisioned: run npm install (~25s cold cache), then
    ///     probe + flip toggle ON.
    ///   - On any failure: revert toggle + record error.
    ///
    /// `progress` is invoked on the main actor with human-readable
    /// status messages. The Settings sheet renders these in the
    /// provisioning progress UI.
    public func enableSDKMode(
        progress: @MainActor (String) -> Void = { _ in }
    ) async -> Result<Void, SidecarError> {
        do {
            // Step 1: ensure provisioning.
            if !isProvisioned {
                progress("Locating node binary…")
                guard locateNode() != nil else {
                    let detail = "node binary not found on PATH (install Node 18+ from nodejs.org)"
                    lastProvisioningError = detail
                    userDefaults.set(false, forKey: sdkModeKey)
                    return .failure(.notProvisioned(detail: detail))
                }

                progress("Preparing sidecar directory…")
                try ensureSidecarDirectory()

                progress("Installing @openai/codex-sdk (~25s on first run)…")
                try await runNpmInstall()

                progress("Verifying install…")
                userDefaults.set(true, forKey: provisionedKey)
            }

            // Step 2: probe the (now-provisioned) sidecar.
            progress("Probing sidecar…")
            let response = try await probeSidecar()
            switch response {
            case .sdk(let version):
                userDefaults.set(version, forKey: provisionedVersionKey)
                userDefaults.set(true, forKey: sdkModeKey)
                lastProvisioningError = nil
                logger.info("Codex SDK mode enabled; version \(version, privacy: .public)")
                progress("SDK mode active.")
                return .success(())
            case .skeleton(let msg):
                // Provisioned dir exists but SDK doesn't import — install
                // corrupt or version mismatch. Mark unprovisioned so the
                // next enable re-runs npm install.
                lastProvisioningError = msg
                userDefaults.set(false, forKey: provisionedKey)
                userDefaults.set(false, forKey: sdkModeKey)
                return .failure(.notProvisioned(detail: msg))
            }
        } catch {
            let detail = (error as? SidecarError)?.errorDescription ?? error.localizedDescription
            lastProvisioningError = detail
            userDefaults.set(false, forKey: sdkModeKey)
            logger.error("Codex SDK enable failed: \(detail, privacy: .public)")
            return .failure((error as? SidecarError) ?? .probeFailed(detail: detail))
        }
    }

    /// Disables SDK mode. Keeps the AppSupport install on disk for fast
    /// re-enable. To wipe completely, call `wipeProvisionedState()`.
    public func disableSDKMode() {
        userDefaults.set(false, forKey: sdkModeKey)
        lastProvisioningError = nil
        logger.info("Codex SDK mode disabled by user toggle.")
    }

    /// Deletes the AppSupport sidecar dir. Use when the user wants a
    /// clean reinstall (e.g., after a Node major version upgrade).
    public func wipeProvisionedState() throws {
        let dir = appSupportDir()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        userDefaults.set(false, forKey: provisionedKey)
        userDefaults.removeObject(forKey: provisionedVersionKey)
        userDefaults.set(false, forKey: sdkModeKey)
        lastProvisioningError = nil
    }

    // MARK: - One-shot resume (X1 compose-draft handoff)

    /// One-shot Codex SDK resume. Spawns the sidecar with
    /// `agent: "resume"`, sends `{threadId, prompt, workingDirectory}`,
    /// reads the `resume_result` event, returns the parsed Turn data.
    /// Used by the X1 cross-Apple handoff: iPhone posts a compose-draft
    /// with `codexThreadId` set; the Mac daemon dispatches here to
    /// continue that thread with the new prompt without keeping a
    /// long-running stream.
    ///
    /// Throws if the SDK isn't provisioned. Caller surfaces the
    /// "Toggle SDK mode in Settings → Codex SDK" CTA.
    public func runResume(
        threadId: String,
        prompt: String,
        workingDirectory: String,
        timeout: TimeInterval = 90
    ) async throws -> ResumeResult {
        guard isProvisioned else { throw SidecarError.notProvisioned(detail: "Codex SDK not installed") }
        guard let nodeBinary = locateNode() else {
            throw SidecarError.notProvisioned(detail: "node binary not found on PATH")
        }
        let mainJS = appSupportDir().appendingPathComponent("main.mjs", isDirectory: false)
        guard FileManager.default.fileExists(atPath: mainJS.path) else {
            throw SidecarError.notProvisioned(detail: "AppSupport main.mjs missing — re-provision required")
        }

        let process = Process()
        process.executableURL = nodeBinary
        process.arguments = [mainJS.path]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let payload: [String: Any] = [
            "agent": "resume",
            "threadId": threadId,
            "prompt": prompt,
            "workingDirectory": workingDirectory,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        var withNewline = payloadData
        withNewline.append(0x0a)
        try stdin.fileHandleForWriting.write(contentsOf: withNewline)
        try? stdin.fileHandleForWriting.close()

        // Read stdout until we see the `resume_result` event or hit timeout.
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        var result: ResumeResult?
        var failure: String?
        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            output.append(chunk)
            // Try to parse complete JSON-lines as they come in.
            while let lf = output.firstIndex(of: 0x0a) {
                let lineBytes = output.subdata(in: output.startIndex..<lf)
                output.removeSubrange(output.startIndex...lf)
                guard !lineBytes.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any]
                else { continue }
                if let type = json["type"] as? String, type == "resume_result" {
                    // Items are JSON-encoded as a single string so the
                    // ResumeResult value remains Sendable (raw `[[String:
                    // Any]]` isn't). Callers that need to inspect items
                    // deeply re-parse `itemsJSON` themselves; the X1
                    // path mostly cares about `finalResponse`.
                    let itemsJSON: String = {
                        guard let arr = json["items"] as? [Any],
                              let data = try? JSONSerialization.data(withJSONObject: arr),
                              let s = String(data: data, encoding: .utf8) else {
                            return "[]"
                        }
                        return s
                    }()
                    result = ResumeResult(
                        threadId: json["threadId"] as? String ?? threadId,
                        finalResponse: json["finalResponse"] as? String ?? "",
                        itemsJSON: itemsJSON,
                        usage: parseUsage(from: json["usage"] as? [String: Any])
                    )
                    break
                }
                if let type = json["type"] as? String, type == "error" {
                    failure = (json["msg"] as? String) ?? "Codex SDK resume failed"
                    break
                }
            }
            if result != nil || failure != nil { break }
        }
        process.terminate()
        if let result { return result }
        if let failure { throw SidecarError.probeFailed(detail: failure) }
        throw SidecarError.probeFailed(detail: "Codex SDK resume timed out after \(Int(timeout))s")
    }

    private func parseUsage(from dict: [String: Any]?) -> ResumeUsage? {
        guard let dict else { return nil }
        return ResumeUsage(
            inputTokens: dict["input_tokens"] as? Int ?? 0,
            cachedInputTokens: dict["cached_input_tokens"] as? Int ?? 0,
            outputTokens: dict["output_tokens"] as? Int ?? 0,
            reasoningOutputTokens: dict["reasoning_output_tokens"] as? Int ?? 0
        )
    }

    /// Structured result of `runResume()`. Mirrors the SDK's Turn type.
    /// `itemsJSON` is the raw JSON array as a string — keep ResumeResult
    /// `Sendable` (any `[[String: Any]]` isn't). Callers that need
    /// structured items re-decode `itemsJSON` themselves.
    public struct ResumeResult: Sendable {
        public let threadId: String
        public let finalResponse: String
        public let itemsJSON: String
        public let usage: ResumeUsage?
    }

    public struct ResumeUsage: Equatable, Sendable {
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let reasoningOutputTokens: Int
    }

    // MARK: - Provisioning steps

    /// `~/Library/Application Support/Clawdmeter/codex-sdk/`. Created
    /// on demand by `ensureSidecarDirectory()`.
    public func appSupportDir() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Clawdmeter", isDirectory: true)
            .appendingPathComponent("codex-sdk", isDirectory: true)
    }

    /// True iff the AppSupport dir has `node_modules/@openai/codex-sdk/`.
    /// Used by `isProvisioned` to validate the persisted flag against
    /// disk state.
    public func sdkInstallExists() -> Bool {
        let modulePath = appSupportDir()
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@openai", isDirectory: true)
            .appendingPathComponent("codex-sdk", isDirectory: true)
            .appendingPathComponent("package.json", isDirectory: false)
        return FileManager.default.fileExists(atPath: modulePath.path)
    }

    /// Creates the AppSupport dir if missing, writes a synthetic
    /// package.json + copies main.mjs from the source-of-truth path.
    private func ensureSidecarDirectory() throws {
        let dir = appSupportDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Synthetic package.json declaring the SDK dep so `npm install`
        // can resolve it (rather than passing the package name on the
        // command line — keeps the dep version pinned by us).
        let packageJSON = """
        {
          "name": "clawdmeter-codex-sdk-runtime",
          "version": "0.7.1",
          "type": "module",
          "private": true,
          "dependencies": {
            "@openai/codex-sdk": "^0.131.0"
          }
        }
        """
        let pkgURL = dir.appendingPathComponent("package.json", isDirectory: false)
        try packageJSON.write(to: pkgURL, atomically: true, encoding: .utf8)

        // Copy main.mjs from the source-of-truth path. In a development
        // build (running from the repo), we walk up to find
        // `tools/clawdmeter-codex-sdk/main.mjs`. In a production .app
        // bundle, we read from `Contents/Resources/codex-sdk-main.mjs`
        // (TODO: wire the bundle Resource in C3 — bundled Node).
        let sourceMain = locateMainMJSSource()
        guard let source = sourceMain else {
            throw SidecarError.notProvisioned(detail: "main.mjs source not found on disk")
        }
        let destMain = dir.appendingPathComponent("main.mjs", isDirectory: false)
        // Replace any older copy. Cheap on APFS.
        if FileManager.default.fileExists(atPath: destMain.path) {
            try FileManager.default.removeItem(at: destMain)
        }
        try FileManager.default.copyItem(at: source, to: destMain)
    }

    /// Runs `npm install` in the AppSupport dir. Cold-cache cost is
    /// ~25s; warm-cache ~3s. Throws SidecarError on non-zero exit.
    /// Caller must have set up package.json via ensureSidecarDirectory().
    private func runNpmInstall() async throws {
        let dir = appSupportDir()
        guard let npm = locateNpm() else {
            throw SidecarError.notProvisioned(detail: "npm binary not found alongside node")
        }

        let process = Process()
        process.executableURL = npm
        process.arguments = ["install", "--no-audit", "--no-fund", "--no-progress"]
        process.currentDirectoryURL = dir
        let stderr = Pipe()
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Block on completion via Task.detached so we don't pin the
        // main actor while npm runs.
        let exitCode = await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
            return process.terminationStatus
        }.value

        if exitCode != 0 {
            let errData = stderr.fileHandleForReading.availableData
            let errText = String(decoding: errData, as: UTF8.self)
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .suffix(5) // last 5 lines (usually the actual error)
                .joined(separator: "\n")
            throw SidecarError.notProvisioned(detail: "npm install failed (exit \(exitCode)): \(errText)")
        }
    }

    // MARK: - Probe

    /// Probes the AppSupport sidecar (post-provisioning) with a
    /// `probe` agent header. Expected response:
    ///   - SDK mode: `{type:"ready",version:"0.7.1-sdk"}` then
    ///               `{type:"probe_ok",sdkVersion:"0.7.1-sdk"}`
    ///   - Skeleton: `{type:"ready",version:"0.7.1-skeleton"}` then
    ///               `{type:"error",code:"sdk_not_provisioned",...}`
    private func probeSidecar() async throws -> SidecarProbeResult {
        let mainJS = appSupportDir().appendingPathComponent("main.mjs", isDirectory: false)
        guard FileManager.default.fileExists(atPath: mainJS.path) else {
            throw SidecarError.notProvisioned(detail: "AppSupport main.mjs missing — re-provision required")
        }
        guard let nodeBin = locateNode() else {
            throw SidecarError.notProvisioned(detail: "node binary not found on PATH")
        }

        let process = Process()
        process.executableURL = nodeBin
        process.arguments = [mainJS.path]
        // Inherit env so the SDK can read ~/.codex/auth.json.
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()

        let header = #"{"agent":"probe"}"# + "\n"
        try stdin.fileHandleForWriting.write(contentsOf: Data(header.utf8))
        try stdin.fileHandleForWriting.close()

        // Wait up to 30s. SDK first-load (when the codex binary gets
        // chained through @openai/codex) can take longer than the
        // skeleton-only path.
        let deadline = Date().addingTimeInterval(30)
        var output = ""
        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !process.isRunning { break }
                continue
            }
            output += String(decoding: chunk, as: UTF8.self)
            // Probe terminates after one round-trip, so a single LF +
            // probe_ok / error line is enough.
            if output.contains("probe_ok") || output.contains("sdk_not_provisioned") { break }
        }
        process.terminate()

        // Parse the response.
        let lines = output.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        for line in lines {
            if let type = line["type"] as? String, type == "probe_ok" {
                let version = (line["sdkVersion"] as? String) ?? "unknown"
                return .sdk(version: version)
            }
            if let code = line["code"] as? String, code == "sdk_not_provisioned" {
                let msg = (line["msg"] as? String) ?? "SDK not reachable from AppSupport"
                return .skeleton(message: msg)
            }
        }
        // Fall-through: no recognizable response within the 30s window.
        throw SidecarError.probeFailed(detail: "no recognizable sidecar response within 30s")
    }

    // MARK: - Binary discovery

    /// Locates the main.mjs source-of-truth on disk. Production .app
    /// bundles ship it as `Contents/Resources/main.mjs` (via the
    /// project.yml `buildPhase: resources` declaration); dev builds
    /// run from the repo where it lives at
    /// tools/clawdmeter-codex-sdk/main.mjs.
    func locateMainMJSSource() -> URL? {
        // First try the app bundle's Resources/. xcodegen copies
        // tools/clawdmeter-codex-sdk/main.mjs as Resources/main.mjs.
        if let bundlePath = Bundle.main.url(forResource: "main", withExtension: "mjs") {
            return bundlePath
        }
        // Dev: walk up from the cwd to find the repo-relative source.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var dir = cwd
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("tools", isDirectory: true)
                .appendingPathComponent("clawdmeter-codex-sdk", isDirectory: true)
                .appendingPathComponent("main.mjs", isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Locates the `node` binary. v0.7.1 preference order:
    ///   1. App bundle Resources/Vendor/node/bin/node (C3 — bundled Node)
    ///   2. Homebrew arm64 (/opt/homebrew/bin)
    ///   3. Homebrew intel / MacPorts (/usr/local/bin)
    ///   4. System (/usr/bin)
    ///   5. `which node` (env-PATH fallback)
    public func locateNode() -> URL? {
        // Bundled Node has highest priority when shipping — guarantees
        // the version matches what the SDK was tested against.
        if let bundled = Bundle.main.url(
            forResource: "node",
            withExtension: nil,
            subdirectory: "Vendor/node/bin"
        ) {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let path = whichBinary("node") {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Locates the `npm` binary. Defaults to the same dir as node when
    /// possible (avoids version skew with the discovered node).
    private func locateNpm() -> URL? {
        // Sibling of the located node binary (preferred — version-pinned).
        if let node = locateNode() {
            let sibling = node.deletingLastPathComponent().appendingPathComponent("npm", isDirectory: false)
            if FileManager.default.fileExists(atPath: sibling.path) {
                return sibling
            }
        }
        let candidates = [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            "/usr/bin/npm",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let path = whichBinary("npm") {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func whichBinary(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.availableData
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - Types

    public enum SidecarProbeResult {
        case sdk(version: String)
        case skeleton(message: String)
    }

    public enum SidecarError: Error, LocalizedError {
        case notProvisioned(detail: String)
        case probeFailed(detail: String)

        public var errorDescription: String? {
            switch self {
            case .notProvisioned(let detail): return "Codex SDK not provisioned: \(detail)"
            case .probeFailed(let detail): return "Codex SDK sidecar probe failed: \(detail)"
            }
        }
    }
}
