// Lifecycle manager for the Clawdmeter SDK-mode Python sidecar.
//
// v0.7.15 ships the real provisioning that v0.6.1 had spec'd:
//   - Locates bundled `uv` under Contents/Resources/Vendor/uv/uv
//   - Runs `uv venv ~/Library/Application Support/Clawdmeter/python` to
//     create a sealed Python 3.13 venv on first enable (~10-15s cold)
//   - Runs `uv pip install google-antigravity~=0.0.3` into the venv
//     (~5-10s on a warm pip cache; may fail if Google hasn't published
//     the SDK yet — see the fallback below)
//   - Probes the sidecar by spawning main.py with the venv's Python and
//     validating it can `import google.antigravity`
//
// Failure handling — three layers of grace:
//   1. uv binary missing (dev build w/o `tools/download-bundled-uv.sh`)
//      → SidecarError.notProvisioned("uv binary not bundled — run
//        tools/download-bundled-uv.sh and rebuild").
//   2. `uv pip install google-antigravity` fails (no internet, package
//      doesn't exist, version conflict) → SidecarError.notProvisioned
//      with uv's stderr captured. Toggle reverts. Disk mode unaffected.
//   3. `import google.antigravity` fails inside the venv after install
//      claimed success → SidecarError.notProvisioned("SDK import failed").
//
// Hot-toggle:
//   - OFF → ON: provisioning runs once (~15s with progress); subsequent
//     ON cycles reuse the venv (~500ms probe).
//   - ON → OFF: just flips the UserDefaults flag. The sidecar process
//     is best-effort terminated; the venv stays on disk for fast re-enable.

import Foundation
import OSLog

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

    /// Most-recent provisioning step name. Surfaced in the Antigravity
    /// settings sheet so users see "Running uv venv (~10s)…" rather
    /// than a 15-second blank spinner.
    public private(set) var provisioningStep: String?

    /// Read-only view of the SDK mode toggle. Drives the analytics
    /// subtitle ("· SDK mode" vs "· disk mode").
    public var sdkModeActive: Bool {
        get { userDefaults.bool(forKey: sdkModeKey) }
    }

    /// Absolute path to the sealed venv. Stays consistent across app
    /// launches so re-enable doesn't re-provision.
    private var venvRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Clawdmeter", isDirectory: true)
            .appendingPathComponent("python", isDirectory: true)
        return base
    }

    /// Path to the venv's `bin/python` once `uv venv` has run.
    private var venvPython: URL {
        venvRoot.appendingPathComponent("bin/python", isDirectory: false)
    }

    /// v0.22.27: checks that the `google` namespace package is actually
    /// installed inside the venv. After `uv pip install google-antigravity`,
    /// site-packages should contain `google/antigravity/` (namespace
    /// package — no `__init__.py` at `google/` itself). When the v0.22.20
    /// bad pin failed install silently, site-packages was left with only
    /// `_virtualenv.py` + `__pycache__`. This check distinguishes a
    /// real-installed venv from a shell-only one without spawning Python.
    ///
    /// Walks both common Python versions (3.13 today, 3.14 future).
    /// Returns true if the SDK package directory exists for at least
    /// one Python version, false otherwise (including when the venv
    /// itself doesn't exist yet).
    private func sdkPackageInstalled() -> Bool {
        let fm = FileManager.default
        let libRoot = venvRoot.appendingPathComponent("lib", isDirectory: true)
        guard fm.fileExists(atPath: libRoot.path),
              let pythonDirs = try? fm.contentsOfDirectory(atPath: libRoot.path) else {
            return false
        }
        for pyDir in pythonDirs where pyDir.hasPrefix("python") {
            let pkg = libRoot
                .appendingPathComponent(pyDir, isDirectory: true)
                .appendingPathComponent("site-packages/google/antigravity", isDirectory: true)
            if fm.fileExists(atPath: pkg.path) {
                return true
            }
        }
        return false
    }

    // MARK: - Public API

    /// Attempts to enable SDK mode. Runs full uv venv + pip install
    /// google-antigravity if the venv doesn't exist yet, then probes
    /// the sidecar to confirm `import google.antigravity` works.
    /// Reports progress through `provisioningStep` for the Settings
    /// sheet.
    public func enableSDKMode() async -> Result<Void, SidecarError> {
        do {
            // Step 1: locate the bundled uv binary. Required for both
            // first-run provisioning AND for `uv run` invocations of the
            // sidecar later.
            guard let uvBinary = locateUV() else {
                let detail = "uv binary not bundled — run tools/download-bundled-uv.sh and rebuild the Mac app"
                lastProvisioningError = detail
                userDefaults.set(false, forKey: sdkModeKey)
                return .failure(.notProvisioned(detail: detail))
            }

            // Step 2: provision the venv + pip install on first run.
            // Idempotent — fast path is ~150ms when venv already exists.
            //
            // v0.22.21 fix: bump the version pin from `~=0.0.3` to
            // `>=0.1.0,<0.2.0`. PyPI dropped every 0.0.x release of
            // `google-antigravity`; only 0.1.0+ exists today.
            // `uv pip install google-antigravity~=0.0.3` was failing
            // resolution silently, leaving the venv shell behind
            // (just .gitignore + .lock) but no `google` module —
            // which surfaced as the misleading "SDK installed but
            // import failed" probe error.
            //
            // Also v0.22.21: detect the "venv shell only" state
            // (directory exists, bin/python doesn't) and nuke it so
            // a fresh `uv venv` actually runs instead of being
            // skipped by the `!fileExists(venvPython)` short-circuit
            // doing nothing while the old shell sits there.
            //
            // v0.22.27: also detect "venv exists + bin/python exists
            // BUT google package was never installed" — this is what
            // happens when a previous app launched with the v0.22.20
            // bad pin (`~=0.0.3`) created the venv but pip install
            // silently failed, leaving site-packages with only
            // `_virtualenv.py`. Today's app with the good pin would
            // skip reinstall because bin/python is present. Detect by
            // looking for the actual `google/` namespace dir in
            // site-packages — that only exists if pip install
            // succeeded against a real version.
            if FileManager.default.fileExists(atPath: venvRoot.path)
                && (!FileManager.default.fileExists(atPath: venvPython.path)
                    || !sdkPackageInstalled()) {
                let path = self.venvRoot.path
                logger.info("Antigravity SDK: nuking stale venv at \(path, privacy: .public) so fresh provisioning can run.")
                try? FileManager.default.removeItem(at: venvRoot)
            }
            if !FileManager.default.fileExists(atPath: venvPython.path) {
                provisioningStep = "Creating Python 3.13 venv (~10s)…"
                try await runUV(uvBinary, args: ["venv", "--python", "3.13", venvRoot.path])

                provisioningStep = "Installing google-antigravity (~5s)…"
                try await runUV(
                    uvBinary,
                    args: ["pip", "install", "--python", venvPython.path, "google-antigravity>=0.1.0,<0.2.0"]
                )
            }

            // Step 3: probe the sidecar to confirm it can import the SDK
            // and respond. Uses the venv's Python directly (no `uv run`
            // wrapper needed — that'd just slow startup).
            provisioningStep = "Probing sidecar…"
            let response = try await probeSidecar()

            switch response {
            case .ready:
                provisioningStep = nil
                lastProvisioningError = nil
                userDefaults.set(true, forKey: sdkModeKey)
                logger.info("SDK mode provisioned + probe ready; toggle ON.")
                return .success(())
            case .skeleton(let msg):
                provisioningStep = nil
                lastProvisioningError = msg
                userDefaults.set(false, forKey: sdkModeKey)
                logger.info("SDK mode probe returned skeleton: \(msg, privacy: .public)")
                return .failure(.notProvisioned(detail: msg))
            case .sdkImportFailed(let detail):
                provisioningStep = nil
                lastProvisioningError = "SDK installed but import failed: \(detail)"
                userDefaults.set(false, forKey: sdkModeKey)
                return .failure(.notProvisioned(detail: detail))
            }
        } catch let err as SidecarError {
            provisioningStep = nil
            lastProvisioningError = err.errorDescription
            userDefaults.set(false, forKey: sdkModeKey)
            return .failure(err)
        } catch {
            provisioningStep = nil
            let detail = error.localizedDescription
            lastProvisioningError = "Sidecar probe failed: \(detail)"
            userDefaults.set(false, forKey: sdkModeKey)
            return .failure(.probeFailed(detail: detail))
        }
    }

    /// Disables SDK mode. The venv stays on disk for fast re-enable.
    public func disableSDKMode() {
        userDefaults.set(false, forKey: sdkModeKey)
        lastProvisioningError = nil
        provisioningStep = nil
        logger.info("SDK mode disabled by user toggle.")
    }

    // MARK: - Private impl

    /// Locates the bundled uv binary. Production .app bundles ship it
    /// as Contents/Resources/Vendor/uv/uv (via project.yml's
    /// `Vendor` folder reference). Dev builds running from the repo
    /// walk up to find `apple/ClawdmeterMac/Resources/Vendor/uv/uv`.
    /// Returns nil if neither exists — caller surfaces the
    /// "uv not bundled" error.
    private func locateUV() -> URL? {
        if let bundled = Bundle.main.url(
            forResource: "uv",
            withExtension: nil,
            subdirectory: "Vendor/uv"
        ) {
            return bundled
        }
        // Dev: walk up to find the repo-relative source.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var dir = cwd
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("apple", isDirectory: true)
                .appendingPathComponent("ClawdmeterMac", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("Vendor", isDirectory: true)
                .appendingPathComponent("uv", isDirectory: true)
                .appendingPathComponent("uv", isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Run a uv subcommand and wait for it. Captures stderr so failed
    /// installs surface the actual pip error in Diagnostics.
    private func runUV(_ uvBinary: URL, args: [String]) async throws {
        let process = Process()
        process.executableURL = uvBinary
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe() // discard stdout
        // uv reads HOME for cache location; pass through real env so it
        // works with the user's pip cache + any UV_* config they have.
        process.environment = ProcessInfo.processInfo.environment

        logger.info("uv \(args.joined(separator: " "), privacy: .public)")
        try process.run()

        // Wait for completion off the main actor.
        try await Task.detached {
            process.waitUntilExit()
        }.value

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.availableData
            let errStr = String(data: errData, encoding: .utf8) ?? "(no stderr)"
            // Trim to keep the Diagnostics view readable.
            let trimmed = errStr.split(separator: "\n").prefix(5).joined(separator: " ")
            throw SidecarError.notProvisioned(detail: "uv \(args.first ?? "?") failed: \(trimmed)")
        }
    }

    /// Locates the sidecar's `main.py`. Production .app bundles ship it
    /// as `Contents/Resources/clawdmeter-agents/main.py` (via the
    /// `project.yml` folder-reference resources entry); dev builds
    /// running from the repo walk up to find
    /// `tools/clawdmeter-agents/main.py`.
    private func locateSidecarMain() -> URL? {
        if let bundleResources = Bundle.main.resourceURL {
            let bundled = bundleResources
                .appendingPathComponent("clawdmeter-agents", isDirectory: true)
                .appendingPathComponent("main.py", isDirectory: false)
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
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

    /// Probes the sidecar with a no-op header. Spawns the venv's Python
    /// against main.py so the import check actually exercises the
    /// installed SDK. Reports `.ready` on success, `.sdkImportFailed`
    /// on import error, `.skeleton` if the script returned the legacy
    /// skeleton response.
    private func probeSidecar() async throws -> SidecarProbeResult {
        guard let mainPy = locateSidecarMain() else {
            throw SidecarError.notProvisioned(detail: "sidecar main.py not found")
        }
        guard FileManager.default.fileExists(atPath: venvPython.path) else {
            throw SidecarError.notProvisioned(detail: "venv python missing at \(venvPython.path)")
        }

        let process = Process()
        process.executableURL = venvPython
        process.arguments = [mainPy.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment

        try process.run()

        let header = #"{"agent":"probe"}"# + "\n"
        try stdin.fileHandleForWriting.write(contentsOf: Data(header.utf8))
        try stdin.fileHandleForWriting.close()

        // Read up to 10s for response (venv import can be slower on first run).
        let deadline = Date().addingTimeInterval(10)
        var output = ""
        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !process.isRunning && output.contains("\n") { break }
                if !process.isRunning && output.isEmpty { break }
                continue
            }
            output += String(decoding: chunk, as: UTF8.self)
            // Collect at least 2 lines (ready + status payload) before bailing.
            if output.components(separatedBy: "\n").count >= 3 { break }
        }
        process.terminate()
        // Audit P1 fix: reap the child to avoid zombie accumulation
        // across repeated probes.
        Task.detached { process.waitUntilExit() }

        // Parse lines as JSON; first line is the ready marker, the
        // subsequent line carries either the result or the error.
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let type = obj["type"] as? String {
                if type == "ready", obj["sdk_import_ok"] as? Bool == true {
                    return .ready
                }
                if type == "error", let code = obj["code"] as? String {
                    switch code {
                    case "sdk_not_provisioned":
                        return .skeleton(message: obj["msg"] as? String ?? "SDK mode skeleton")
                    case "sdk_import_failed":
                        return .sdkImportFailed(detail: obj["msg"] as? String ?? "import failed")
                    default:
                        return .skeleton(message: obj["msg"] as? String ?? "unknown sidecar error")
                    }
                }
            }
        }
        throw SidecarError.notProvisioned(detail: "no parseable response from sidecar")
    }

    public enum SidecarProbeResult {
        case ready
        case skeleton(message: String)
        case sdkImportFailed(detail: String)
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
