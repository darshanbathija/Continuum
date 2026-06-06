import Foundation
import Network
import ClawdmeterShared

// MARK: - Antigravity Plan endpoint (wire v7)

extension AgentControlServer {
    /// `GET /sessions/:id/antigravity-plan` — returns the parsed Plan
    /// snapshot for a Gemini session. Works in Disk mode (default);
    /// SDK mode (Commit 10) extends the data source via the sidecar.
    ///
    /// Brain resolution strategy:
    ///   1. Look up `~/.gemini/antigravity/agyhub_summaries_proto.pb` for
    ///      brain UUIDs whose cwd matches the session's repoKey.
    ///   2. If multiple, pick the brain dir with the newest mtime.
    ///   3. Parse the brain dir via BrainPlanParser.
    ///   4. Encode as AntigravityPlanSnapshot and send.
    func handleGetAntigravityPlan(sessionId: String, connection: NWConnection) async {
        guard let uuid = UUID(uuidString: sessionId), let session = registry.session(id: uuid) else {
            sendResponse(.notFound, on: connection); return
        }
        // REV-Antigravity-polling (v0.8): chat sessions never have an
        // Antigravity brain — short-circuit before touching session.repoKey
        // (which is nil for chat sessions, would crash the URL constructor).
        guard session.kind == .code else {
            sendResponse(.notFound, on: connection); return
        }
        // Only respond for Gemini sessions. Claude/Codex sessions don't
        // have an Antigravity brain — return 404 with a clear shape so
        // iOS can fall back to "Plan tab not applicable for this agent".
        guard session.agent == .gemini else {
            sendResponse(.notFound, on: connection); return
        }

        let home = ClawdmeterRealHome.url()
        let antigravityDir = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        let indexURL = antigravityDir.appendingPathComponent("agyhub_summaries_proto.pb", isDirectory: false)
        let stateURL = antigravityDir.appendingPathComponent("antigravity_state.pbtxt", isDirectory: false)

        let index = BrainSummaryIndexer.read(at: indexURL)
        // session.repoKey is non-nil here because the kind-guard above
        // short-circuits chat sessions; force-unwrap is safe.
        let cwdURL = URL(fileURLWithPath: session.repoKey!)
        var candidateUUIDs = BrainSummaryIndexer.lookup(cwd: cwdURL, in: index)
        if candidateUUIDs.isEmpty {
            // Fallback: glob all brain dirs and let mtime drive the pick.
            let brainsDir = antigravityDir.appendingPathComponent("brain", isDirectory: true)
            if let entries = try? FileManager.default.contentsOfDirectory(at: brainsDir, includingPropertiesForKeys: nil) {
                candidateUUIDs = entries.map { $0.lastPathComponent }
            }
        }

        let brainsDir = antigravityDir.appendingPathComponent("brain", isDirectory: true)
        let bestBrain = candidateUUIDs
            .map { brainsDir.appendingPathComponent($0, isDirectory: true) }
            .max(by: { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            })

        let state = try? AntigravityStateReader.read(at: stateURL)
        let sdkModeActive = UserDefaults.standard.bool(forKey: "clawdmeter.antigravity.sdkMode")
        let modelName = state?.displayModelName

        let snapshot: AntigravityPlanSnapshot
        if let brain = bestBrain {
            let planState = BrainPlanParser.parse(brainURL: brain)
            switch planState {
            case .ready(let plan):
                let convURL = antigravityDir
                    .appendingPathComponent("conversations", isDirectory: true)
                    .appendingPathComponent("\(plan.brainUUID).pb", isDirectory: false)
                let probe = ConversationProtoParser.probe(conversationURL: convURL, brainURL: brain)
                let totalUsage = WireTokenUsage(
                    total: probe.estimatedTokens,
                    prompt: nil, candidate: nil, thoughts: nil, cached: nil,
                    isEstimate: true
                )
                snapshot = AntigravityPlanSnapshot(
                    sessionId: session.id,
                    brainUUID: plan.brainUUID,
                    taskHeadline: plan.taskHeadline,
                    taskBody: plan.taskBody,
                    planSteps: Self.flatten(steps: plan.steps),
                    annotations: plan.annotations.map { WireBrainArtifact(id: $0.id, filename: $0.filename, body: $0.body) },
                    totalUsage: totalUsage,
                    lastUpdated: plan.lastUpdated,
                    model: modelName,
                    sdkModeActive: sdkModeActive,
                    awaitingFirstTurn: false
                )
            case .awaitingFirstTurn, .absent:
                snapshot = AntigravityPlanSnapshot(
                    sessionId: session.id,
                    brainUUID: brain.lastPathComponent,
                    taskHeadline: "",
                    taskBody: "",
                    planSteps: [],
                    annotations: [],
                    totalUsage: nil,
                    lastUpdated: Date(),
                    model: modelName,
                    sdkModeActive: sdkModeActive,
                    awaitingFirstTurn: true
                )
            }
        } else {
            // No brain dir at all — same shape as awaiting first turn,
            // empty brainUUID so iOS doesn't pretend it has a real id.
            snapshot = AntigravityPlanSnapshot(
                sessionId: session.id,
                brainUUID: "",
                taskHeadline: "",
                taskBody: "",
                planSteps: [],
                annotations: [],
                totalUsage: nil,
                lastUpdated: Date(),
                model: modelName,
                sdkModeActive: sdkModeActive,
                awaitingFirstTurn: true
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(snapshot) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// Flattens a nested tree of `BrainPlanStep` into a depth-indexed
    /// list of `WirePlanStep`. iOS renders the flat list with
    /// `.padding(.leading, CGFloat(step.depth) * 16)`.
    private static func flatten(steps: [BrainPlanStep]) -> [WirePlanStep] {
        var out: [WirePlanStep] = []
        for step in steps {
            out.append(WirePlanStep(id: step.id, label: step.label, isComplete: step.isComplete, depth: step.depth))
            out.append(contentsOf: flatten(steps: step.children))
        }
        return out
    }
}
