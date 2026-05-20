// Lifecycle manager for the Clawdmeter Codex SDK-mode Node sidecar.
//
// SCOPE for v0.7.0 (this commit): skeleton manager + Settings toggle
// integration. The toggle persists to UserDefaults and the manager
// surfaces the "SDK mode not yet provisioned — toggle reverts" error
// in Settings → Diagnostics. Full `npm install @openai/codex-sdk`
// provisioning lands in v0.7.1.
//
// What it does today (mirrors AntigravitySidecarManager exactly):
//   - Reads `clawdmeter.codex.sdkMode` UserDefaults bool
//   - On toggle ON: spawns `node tools/clawdmeter-codex-sdk/main.mjs`
//     with a synthetic header, captures the stdout → if it returns
//     the `sdk_not_provisioned` skeleton error, surfaces in Diagnostics
//     + reverts the toggle to OFF.
//   - On toggle OFF: cleans up.
//
// What it will do in v0.7.1:
//   - Run `npm install @openai/codex-sdk` into
//     ~/Library/Application Support/Clawdmeter/codex-sdk/
//   - Spawn `node main.mjs` long-running with stdio JSON-lines
//   - Wire stdio events to SDKCodexObservationProvider
//   - Handle crash recovery via SIGCHLD + 3-strike fallback to Disk
//     mode (same shape as Antigravity manager)
//
// **Auth contract** (recap): the Codex SDK reads ~/.codex/auth.json on
// startup. When `auth_mode: "chatgpt"` is set + tokens present, no
// API key needed. We don't touch auth from here — the SDK + CLI own it.

import Foundation
import OSLog

/// Codex SDK sidecar manager. Skeleton in v0.7.0; full impl in v0.7.1.
@MainActor
public final class CodexSDKManager {

    public static let shared = CodexSDKManager()

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "CodexSDKManager")
    private let userDefaults = UserDefaults.standard
    private let sdkModeKey = "clawdmeter.codex.sdkMode"

    /// Last error from a provisioning attempt. Rendered in Settings →
    /// Diagnostics. Nil when no attempt has been made or last attempt
    /// succeeded.
    public private(set) var lastProvisioningError: String?

    /// Read-only view of the SDK mode toggle. Drives the analytics
    /// subtitle ("· SDK mode" vs "· disk mode") on the Codex column.
    public var sdkModeActive: Bool {
        userDefaults.bool(forKey: sdkModeKey)
    }

    /// Attempts to enable Codex SDK mode. v0.7.0 skeleton: invokes
    /// main.mjs, captures the `sdk_not_provisioned` error, reverts the
    /// toggle, stores the error for Diagnostics. v0.7.1: full npm
    /// install + long-running observer.
    public func enableSDKMode() async -> Result<Void, SidecarError> {
        do {
            let response = try await probeSidecar()
            switch response {
            case .skeleton(let msg):
                lastProvisioningError = msg
                userDefaults.set(false, forKey: sdkModeKey)
                logger.info("Codex SDK skeleton hit; toggle reverted: \(msg, privacy: .public)")
                return .failure(.notProvisioned(detail: msg))
            case .ready:
                lastProvisioningError = nil
                userDefaults.set(true, forKey: sdkModeKey)
                return .success(())
            }
        } catch {
            let detail = error.localizedDescription
            lastProvisioningError = "Codex SDK sidecar probe failed: \(detail)"
            userDefaults.set(false, forKey: sdkModeKey)
            return .failure(.probeFailed(detail: detail))
        }
    }

    /// Disables Codex SDK mode. Cleans up any running sidecar process.
    public func disableSDKMode() {
        userDefaults.set(false, forKey: sdkModeKey)
        lastProvisioningError = nil
        logger.info("Codex SDK mode disabled by user toggle.")
    }

    /// Probes the sidecar with a no-op header and parses the response.
    /// Used by the v0.7.0 toggle to validate Node + the script are
    /// reachable before real provisioning lands.
    private func probeSidecar() async throws -> SidecarProbeResult {
        guard let mainJS = locateSidecarMain() else {
            throw SidecarError.notProvisioned(detail: "sidecar main.mjs not found")
        }
        guard let nodeBin = locateNode() else {
            throw SidecarError.notProvisioned(detail: "node binary not found on PATH (install Node 18+)")
        }

        let process = Process()
        process.executableURL = nodeBin
        process.arguments = [mainJS.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()

        let header = #"{"agent":"probe"}"# + "\n"
        try stdin.fileHandleForWriting.write(contentsOf: Data(header.utf8))
        try stdin.fileHandleForWriting.close()

        // Wait up to 5s. Skeleton replies in <100ms; v0.7.1 first-run
        // may bump to handle `npm install`.
        let deadline = Date().addingTimeInterval(5)
        var output = ""
        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !process.isRunning { break }
                continue
            }
            output += String(decoding: chunk, as: UTF8.self)
            if output.contains("\n") { break }
        }
        process.terminate()

        // Parse the first JSON line.
        guard let firstLine = output.split(separator: "\n").first,
              let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SidecarError.notProvisioned(detail: "no JSON output from sidecar")
        }

        if let type = obj["type"] as? String, type == "ready",
           let version = obj["version"] as? String, version == "0.7.0-skeleton" {
            // Skeleton acknowledged. Read second line for the explicit
            // `sdk_not_provisioned` payload.
            let lines = output.split(separator: "\n")
            for line in lines.dropFirst() {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let code = obj["code"] as? String, code == "sdk_not_provisioned" {
                    return .skeleton(message: obj["msg"] as? String ?? "Codex SDK not yet provisioned")
                }
            }
            return .skeleton(message: "Codex SDK skeleton — full impl in v0.7.1")
        }

        // v0.7.1: fully-provisioned ready will lack the skeleton version marker.
        if let type = obj["type"] as? String, type == "ready" {
            return .ready
        }
        return .skeleton(message: "Unexpected sidecar response — assume skeleton")
    }

    /// Walks up from cwd looking for `tools/clawdmeter-codex-sdk/main.mjs`.
    /// Production Mac bundle will ship the file under `Contents/Resources/`
    /// — v0.7.1 wires that path.
    private func locateSidecarMain() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var dir = cwd
        for _ in 0..<6 {
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

    /// Locates the `node` binary. Mirrors `ShellRunner.locateBinary` —
    /// tries the canonical Homebrew + system paths in order.
    private func locateNode() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/node",     // Apple Silicon Homebrew
            "/usr/local/bin/node",         // Intel Homebrew / MacPorts
            "/usr/bin/node",                // System (rare)
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fallback: env `which node`
        if let path = whichNode() {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func whichNode() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "node"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.availableData
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    public enum SidecarProbeResult {
        case ready
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
