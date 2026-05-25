// v0.26.5: dropped the `#if os(macOS)` gate.
// `UsageHistoryLoader` lives in Shared and the iOS target compiles it, so
// referencing `ClawdmeterRealHome` from there used to fail iOS build with
// "cannot find 'ClawdmeterRealHome' in scope". `getpwuid` is POSIX and
// available on every Darwin platform; on iOS / watchOS it returns the
// app's container home (same as `NSHomeDirectory()`), which is exactly
// what we want there — there's no "real user home" to bypass.
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Resolve the *real* user home directory, bypassing macOS App Sandbox
/// redirection.
///
/// `NSHomeDirectory()` and `FileManager.homeDirectoryForCurrentUser` return
/// the sandbox container path (`~/Library/Containers/<bundle-id>/Data/`)
/// inside a sandboxed app. Codex, Gemini/Antigravity, and OpenCode all
/// write their auth bundles + state to the user's *actual* `~/` though, so
/// path resolution that uses the sandbox home will silently miss every
/// provider state dir even when the v0.26.2 read-only sandbox exceptions
/// permit the reads.
///
/// `getpwuid(getuid())->pw_dir` reads the canonical home from the system
/// password database — bypasses sandbox redirection at the POSIX layer.
///
/// This is the Shared-module twin of `clawdmeterRealUserHome()` in
/// `apple/ClawdmeterMac/AgentControl/OpencodeAuthFile.swift` (v0.23.5). It
/// lives in Shared so the provider sources (CodexTokenProvider,
/// GeminiTokenProvider, CodexSource's JSONL parser, …) can call into it
/// without taking a dependency on the Mac module. The Mac-module copy
/// remains for backward source compatibility.
public enum ClawdmeterRealHome {

    /// Path string of the real user home (no trailing slash).
    public static func path() -> String {
        // POSIX: getpwuid returns a pointer into a static buffer; read the
        // pw_dir field immediately to avoid use-after-free.
        if let pw = getpwuid(getuid()),
           let cstr = pw.pointee.pw_dir {
            return String(cString: cstr)
        }
        // Defensive fallback: NSHomeDirectoryForUser also reads the pwd
        // database; double-fallback to NSHomeDirectory() (sandbox path) so
        // path-building never returns nil and tests never crash.
        #if canImport(Darwin)
        if let username = ProcessInfo.processInfo.environment["USER"],
           let real = NSHomeDirectoryForUser(username) {
            return real
        }
        #else
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return home
        }
        #endif
        return NSHomeDirectory()
    }

    /// URL of the real user home, as a directory URL.
    public static func url() -> URL {
        URL(fileURLWithPath: path(), isDirectory: true)
    }
}
