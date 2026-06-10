import Foundation

/// Seeds a fresh per-instance `CLAUDE_CONFIG_DIR` so the Claude CLI
/// doesn't drop into first-run onboarding (theme picker → trust dialog)
/// inside a daemon-spawned session. The primary account's real
/// `~/.claude` already completed onboarding interactively; secondary
/// instances get their config root created by Continuum and would
/// otherwise hit the wizard on first spawn — which swallows the
/// session's opening prompt (the PTY input answers the wizard instead).
///
/// We write the minimal flag set the CLI checks, and ONLY when no
/// `.claude.json` exists yet — a user-managed file is never touched.
public enum ClaudeConfigSeeder {

    /// The onboarding flags written into `<configRoot>/.claude.json`.
    /// Kept minimal on purpose: every extra key risks fighting the CLI's
    /// own migrations. `hasCompletedOnboarding` is the wizard gate;
    /// the theme matches Continuum's always-dark rendering.
    static let seedFlags: [String: Any] = [
        "hasCompletedOnboarding": true,
        "theme": "dark",
    ]

    /// Create `configRoot` (and parents) if needed and write the seed
    /// `.claude.json` when absent. Returns true when the dir is ready
    /// for a first spawn (seeded now or already present).
    @discardableResult
    public static func seed(at configRoot: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: configRoot, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let configFile = configRoot.appendingPathComponent(".claude.json")
        if fm.fileExists(atPath: configFile.path) {
            // Respect whatever the CLI (or the user) already wrote.
            return true
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: seedFlags,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try data.write(to: configFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
