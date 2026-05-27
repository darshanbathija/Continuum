import SwiftUI
import ClawdmeterShared

/// Lists the iOS outbox's pending + failed commands. Pending entries
/// show a small spinner + retry count; failed entries get a Retry /
/// Cancel pair. Empty state collapses to a single info line.
///
/// Reached from the session detail overflow menu (`Outbox`) and from a
/// global root-level "Commands" tab.
public struct iOSOutboxPane: View {
    @ObservedObject var outbox: MobileCommandOutbox
    /// Optional filter: when non-nil, restricts both lists to entries
    /// for this session. Used by the per-session entry path.
    var sessionId: UUID?

    public init(outbox: MobileCommandOutbox, sessionId: UUID? = nil) {
        self.outbox = outbox
        self.sessionId = sessionId
    }

    public var body: some View {
        let pending = filtered(outbox.pending)
        let failed = filtered(outbox.failed)
        if pending.isEmpty && failed.isEmpty {
            ContentUnavailableView(
                "All caught up",
                systemImage: "checkmark.circle",
                description: Text("No pending or failed commands.")
            )
        } else {
            List {
                if !pending.isEmpty {
                    Section("Pending (\(pending.count))") {
                        ForEach(pending, id: \.idempotencyKey) { row($0, isPending: true) }
                    }
                }
                if !failed.isEmpty {
                    Section("Failed (\(failed.count))") {
                        ForEach(failed, id: \.idempotencyKey) { row($0, isPending: false) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ envelope: MobileCommandEnvelope, isPending: Bool) -> some View {
        HStack(spacing: 12) {
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(envelope.kind.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle(for: envelope))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: !isPending) {
            if !isPending {
                Button {
                    outbox.retry(idempotencyKey: envelope.idempotencyKey)
                } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .tint(.blue)
            }
            Button(role: .destructive) {
                outbox.discard(idempotencyKey: envelope.idempotencyKey)
            } label: { Label("Cancel", systemImage: "xmark") }
        }
    }

    private func filtered(_ list: [MobileCommandEnvelope]) -> [MobileCommandEnvelope] {
        guard let sessionId else { return list }
        return list.filter { $0.sessionId == sessionId }
    }

    private func subtitle(for envelope: MobileCommandEnvelope) -> String {
        var parts: [String] = []
        if envelope.retryCount > 0 {
            parts.append("retry #\(envelope.retryCount)")
        }
        if let last = envelope.lastAttemptAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            parts.append(formatter.localizedString(for: last, relativeTo: Date()))
        } else {
            parts.append("queued")
        }
        if let sid = envelope.sessionId, sessionId == nil {
            parts.append("session " + sid.uuidString.prefix(8))
        }
        return parts.joined(separator: " • ")
    }
}

private extension MobileCommandKind {
    var displayName: String {
        switch self {
        case .send: return "Send message"
        case .interrupt: return "Stop"
        case .approve: return "Approve plan"
        case .permissionResponse: return "Permission response"
        case .terminalInput: return "Terminal input"
        case .createPR: return "Create PR"
        case .mergePR: return "Merge PR"
        case .changeModel: return "Change model"
        case .changeEffort: return "Change effort"
        case .changeMode: return "Change mode"
        case .setAutopilot: return "Toggle autopilot"
        case .pickWinner: return "Pick winner"
        case .updateWorkspace: return "Update workspace defaults"
        case .openLocalFolder: return "Open project on Mac"
        case .cloneFromGitHub: return "Clone from GitHub"
        case .quickStartRepo: return "Quick start"
        case .wakeMac: return "Wake Mac"
        }
    }
}
