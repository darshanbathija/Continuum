// Lifecycle manager for the Clawdmeter SDK-mode Python sidecar.
//
// SCOPE for v0.6.0 (this commit): skeleton manager + Settings toggle
// integration. The toggle persists to UserDefaults and the manager
// surfaces the "SDK mode not yet provisioned — toggle reverts" error
// in Settings → Diagnostics. Full uv provisioning + sidecar IPC lands
// in v0.6.1.
//
// What it does today:
//   - Reads `clawdmeter.antigravity.sdkMode` UserDefaults bool
//   - On toggle ON: spawns `python3 tools/clawdmeter-agents/main.py`
//     with a synthetic header, captures the stdout → if it returns the
//     `sdk_not_provisioned` skeleton error, surfaces in Diagnostics +
//     reverts the toggle to OFF.
//   - On toggle OFF: cleans up.
//
// What it will do in v0.6.1:
//   - Bundle a uv binary
//   - Run `uv venv ~/Library/Application Support/Clawdmeter/python`
//   - Run `uv pip install google-antigravity~=0.0.3`
//   - Spawn observer.py + the helper agents under launchd
//   - Wire stdio JSON-lines to SDKObservationProvider
//   - Handle crash recovery via SIGCHLD + 3-strike fallback to Disk mode

import Foundation
import OSLog

/// Sidecar manager. Skeleton in v0.6.0; full impl in v0.6.1.
@MainActor
public final class AntigravitySidecarManager {

    public static let shared = AntigravitySidecarManager()

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "AntigravitySidecarManager")
    private let userDefaults = UserDefaults.standard
    private let sdkModeKey = "clawdmeter.antigravity.sdkMode"

    /// Last error from a provisioning attempt. Rendered in Settings →
    /// Diagnostics. Nil when no attempt has been made or last attempt
    /// succeeded.
    public private(set) var lastProvisioningError: String?

    /// Read-only view of the SDK mode toggle. Drives the analytics
    /// subtitle ("· SDK mode" vs "· disk mode").
    public var sdkModeActive: Bool {
        get { userDefaults.bool(forKey: sdkModeKey) }
    }

    /// Attempts to enable SDK mode. v0.6.0 skeleton: invokes main.py,
    /// captures the `sdk_not_provisioned` error, reverts the toggle,
    /// stores the error for Diagnostics. v0.6.1: full uv provisioning.
    /// Completion runs on the main actor.
    public func enableSDKMode() async -> Result<Void, SidecarError> {
        // Probe the sidecar via main.py to validate we can at least
        // reach Python. This is a smoke-test until v0.6.1's real
        // provisioning lands.
        do {
            let response = try await probeSidecar()
            // v0.6.0 expected response: skeleton error. v0.6.1 expected
            // response: "ready" → keep toggle ON.
            switch response {
            case .skeleton(let msg):
                lastProvisioningError = msg
                userDefaults.set(false, forKey: sdkModeKey)
                logger.info("SDK mode skeleton hit; toggle reverted: \(msg, privacy: .public)")
                return .failure(.notProvisioned(detail: msg))
            case .ready:
                lastProvisioningError = nil
                userDefaults.set(true, forKey: sdkModeKey)
                return .success(())
            }
        } catch {
            let detail = error.localizedDescription
            lastProvisioningError = "Sidecar probe failed: \(detail)"
            userDefaults.set(false, forKey: sdkModeKey)
            return .failure(.probeFailed(detail: detail))
        }
    }

    /// Disables SDK mode. Cleans up any running sidecar process.
    public func disableSDKMode() {
        userDefaults.set(false, forKey: sdkModeKey)
        lastProvisioningError = nil
        logger.info("SDK mode disabled by user toggle.")
    }

    /// Probes the sidecar with a no-op header and parses the response.
    /// Used by the v0.6.0 toggle to validate the Python + script
    /// structure is reachable before the real provisioning lands.
    private func probeSidecar() async throws -> SidecarProbeResult {
        // Locate the sidecar entry point. v0.6.0 ships skeletons in
        // tools/clawdmeter-agents/ — discovered relative to the Mac app
        // bundle in production, but for dev builds we walk up to the
        // repo root.
        guard let mainPy = locateSidecarMain() else {
            throw SidecarError.notProvisioned(detail: "sidecar main.py not found")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", mainPy.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()

        let header = #"{"agent":"probe"}"# + "\n"
        try stdin.fileHandleForWriting.write(contentsOf: Data(header.utf8))
        try stdin.fileHandleForWriting.close()

        // Wait up to 5s for the response. Way more than enough for the
        // skeleton; v0.6.1 may bump to handle slower startup.
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

        // Parse the first JSON line of output.
        guard let firstLine = output.split(separator: "\n").first,
              let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SidecarError.notProvisioned(detail: "no JSON output from sidecar")
        }

        if let type = obj["type"] as? String, type == "ready",
           let version = obj["version"] as? String, version == "0.6.0-skeleton" {
            // Skeleton acknowledged. Now look at the second line for the
            // explicit `sdk_not_provisioned` payload.
            let lines = output.split(separator: "\n")
            for line in lines.dropFirst() {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let code = obj["code"] as? String, code == "sdk_not_provisioned" {
                    return .skeleton(message: obj["msg"] as? String ?? "SDK mode not yet provisioned")
                }
            }
            return .skeleton(message: "SDK mode skeleton — full impl in v0.6.1")
        }

        // v0.6.1: when fully provisioned, the sidecar will emit a
        // different `ready` payload without the skeleton version marker.
        if let type = obj["type"] as? String, type == "ready" {
            return .ready
        }
        return .skeleton(message: "Unexpected sidecar response — assume skeleton")
    }

    /// Locates the sidecar's `main.py`. Production .app bundles ship it
    /// as `Contents/Resources/clawdmeter-agents/main.py` (via the
    /// `project.yml` folder-reference resources entry, v0.7.14); dev
    /// builds running from the repo walk up to find
    /// `tools/clawdmeter-agents/main.py`. Mirrors the Codex SDK
    /// `locateMainMJSSource()` pattern so both SDKs resolve the same way.
    private func locateSidecarMain() -> URL? {
        // Bundled path takes priority — guarantees the .py the manager
        // probes matches the version that shipped with the .app.
        if let bundleResources = Bundle.main.resourceURL {
            let bundled = bundleResources
                .appendingPathComponent("clawdmeter-agents", isDirectory: true)
                .appendingPathComponent("main.py", isDirectory: false)
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        // Dev: walk up from the cwd to find the repo-relative source.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var dir = cwd
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("tools", isDirectory: true)
                .appendingPathComponent("clawdmeter-agents", isDirectory: true)
                .appendingPathComponent("main.py", isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
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
            case .notProvisioned(let detail): return "SDK mode not provisioned: \(detail)"
            case .probeFailed(let detail): return "Sidecar probe failed: \(detail)"
            }
        }
    }
}
