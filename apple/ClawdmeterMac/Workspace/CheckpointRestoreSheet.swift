import SwiftUI
import ClawdmeterShared

/// Modal sheet presented when the user picks "restore to this checkpoint"
/// from the chat overflow menu. Shows the captured diff + the blocking
/// reasons (if any), and gates the destructive action behind a confirm.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. Pure
/// value-typed props (`plan`, `isRestoring`) + two closures; no
/// `@State`/`@ObservedObject` of its own — fully decoupled from the
/// parent workspace's @State graph.
struct CheckpointRestoreSheet: View {
    let plan: CheckpointRestorePlan
    let isRestoring: Bool
    let onCancel: () -> Void
    let onRestore: () -> Void

    private var diffBody: String {
        let stat = plan.diffStat.isEmpty ? "No tracked file changes." : plan.diffStat
        let patch = plan.diffPatch.isEmpty ? "" : "\n\n\(plan.diffPatch)"
        let suffix = plan.patchTruncated ? "\n\n[Diff preview truncated]" : ""
        return stat + patch + suffix
    }

    var body: some View {
        // A6 (foundation): body-invalidation tap. No-op in production.
        BodyInvalidationCounter.bump("CheckpointRestoreSheet")
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: plan.isBlocked ? "exclamationmark.triangle.fill" : "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(plan.isBlocked ? .orange : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore Checkpoint")
                        .font(.system(size: 15, weight: .semibold))
                    Text(plan.target.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                labeledRef("Target", plan.target.refName)
                labeledRef("Safety", plan.safety.refName)
                if !plan.untrackedSnapshotPaths.isEmpty {
                    Text("Restores \(plan.untrackedSnapshotPaths.count) untracked file\(plan.untrackedSnapshotPaths.count == 1 ? "" : "s") from the checkpoint sidecar.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if !plan.blockingReasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.blockingReasons, id: \.self) { reason in
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    if !plan.dirtyStatusLines.isEmpty {
                        Text(plan.dirtyStatusLines.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            Text("Preview")
                .font(.system(size: 12, weight: .semibold))
            ScrollView {
                Text(diffBody)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 240)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: onRestore) {
                    Text(isRestoring ? "Restoring…" : "Restore to checkpoint")
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isBlocked || isRestoring)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
    }

    private func labeledRef(_ label: String, _ ref: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(ref)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
