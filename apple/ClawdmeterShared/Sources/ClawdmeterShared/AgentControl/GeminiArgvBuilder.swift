import Foundation

/// Pure-Swift Gemini CLI argv builder. Lives in `ClawdmeterShared` so the
/// `AgentSpawnerGeminiArgvTests` suite can lock the exact argv shape
/// (regression against future Gemini CLI flag drift). The Mac
/// `AgentSpawner.geminiArgv(...)` wraps this with a `ShellRunner.locateBinary`
/// PATH lookup; no other call site should bake gemini-CLI flag knowledge
/// in by hand.
///
/// Flag contract (verified against gemini CLI 0.42.0):
///   - `-m <model>` — selects the model (`gemini-3.1-pro-high`, etc.).
///   - `--skip-trust` — trusts the current workspace for this session.
///   - `--approval-mode plan|auto_edit|yolo` — exactly one. Precedence:
///     plan > yolo (autopilot) > auto_edit > unset.
///   - `--resume <session-id>` — continues an existing chat.
///   - Extra args trail in the order the caller passed them.
public enum GeminiArgvBuilder {
    public static func argv(
        geminiBinary: String,
        model: String? = nil,
        planMode: Bool = false,
        autopilot: Bool = false,
        acceptEdits: Bool = false,
        resumeSessionId: String? = nil,
        trustWorkspace: Bool = false,
        extraArgs: [String] = []
    ) -> [String] {
        var argv = [geminiBinary]
        if let resumeSessionId, !resumeSessionId.isEmpty {
            argv += ["--resume", resumeSessionId]
        }
        if trustWorkspace {
            argv += ["--skip-trust"]
        }
        if let model, !model.isEmpty {
            argv += ["-m", model]
        }
        if planMode {
            argv += ["--approval-mode", "plan"]
        } else if autopilot {
            argv += ["--approval-mode", "yolo"]
        } else if acceptEdits {
            argv += ["--approval-mode", "auto_edit"]
        }
        argv.append(contentsOf: extraArgs)
        return argv
    }
}
