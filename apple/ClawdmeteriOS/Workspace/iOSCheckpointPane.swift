import SwiftUI
import ClawdmeterShared

struct iOSCheckpointPane: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tahoe) private var t
    @ObservedObject var client: AgentControlClient
    let session: AgentSession

    @State private var checkpoints: [CodeCheckpointSnapshot] = []
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var preparingId: UUID?
    @State private var restorePreview: CodeCheckpointRestorePreview?
    @State private var restoreTarget: CodeCheckpointRestorePreview?
    @State private var isRestoring = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button {
                    Task { await createCheckpoint() }
                } label: {
                    HStack {
                        Label("Create checkpoint", systemImage: "bookmark")
                        Spacer()
                        if isCreating { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isCreating || !client.supportsCodeWorkbenchRemote)
            } footer: {
                Text("Checkpoints are created on the paired Mac from the session's git workspace. Restore always creates a safety checkpoint first.")
            }

            if !client.supportsCodeWorkbenchRemote {
                Section {
                    ContentUnavailableView(
                        "Mac update required",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Update Clawdmeter on Mac for iOS checkpoint restore.")
                    )
                }
            } else if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading checkpoints...")
                    }
                }
            } else if checkpoints.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No checkpoints",
                        systemImage: "bookmark",
                        description: Text("Create one before approving a risky plan or sending a large follow-up.")
                    )
                }
            } else {
                Section("Saved") {
                    ForEach(checkpoints) { checkpoint in
                        checkpointRow(checkpoint)
                    }
                }
            }
        }
        .navigationTitle("Checkpoints")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: ContinuumAnalytics.wrapButton(
                        "done",
                        {
 dismiss() 
                        }
                    ))
            }
        }
        .refreshable { await refresh() }
        .task { await refresh() }
        .sheet(item: $restorePreview) { preview in
            NavigationStack {
                restorePreviewView(preview)
                    .navigationTitle("Restore Preview")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.large])
        }
        .alert("Restore checkpoint?", isPresented: Binding(
            get: { restoreTarget != nil },
            set: { if !$0 { restoreTarget = nil } }
        )) {
            Button("Restore", role: .destructive, action: ContinuumAnalytics.wrapButton(
                    "restore",
                    {
                Task { await restoreSelectedPreview() }
            
                    }
                ))
            .disabled(isRestoring)
            Button("Cancel", role: .cancel, action: ContinuumAnalytics.wrapButton(
                    "cancel",
                    {
 restoreTarget = nil 
                    }
                ))
        } message: {
            Text("This applies the checkpoint to the Mac worktree. A safety checkpoint has already been created.")
        }
        .alert("Checkpoint", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel, action: ContinuumAnalytics.wrapButton(
                    "ok",
                    {
 message = nil 
                    }
                ))
        } message: {
            Text(message ?? "")
        }
    }

    private func checkpointRow(_ checkpoint: CodeCheckpointSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(t.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(checkpoint.summary ?? "Checkpoint")
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg3)
                    Text(checkpoint.refName)
                        .font(TahoeFont.mono(10))
                        .foregroundStyle(t.fg4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            Button {
                Task { await prepareRestore(checkpoint) }
            } label: {
                HStack {
                    if preparingId == checkpoint.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    Text("Preview restore")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(preparingId != nil)
        }
        .padding(.vertical, 4)
    }

    private func restorePreviewView(_ preview: CodeCheckpointRestorePreview) -> some View {
        List {
            if preview.isBlocked {
                Section {
                    ForEach(preview.blockingReasons, id: \.self) { reason in
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Blocked")
                }
            }
            Section("Diff Stat") {
                if preview.diffStat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No tracked diff against this checkpoint.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(preview.diffStat)
                        .font(TahoeFont.mono(11))
                        .textSelection(.enabled)
                }
            }
            if !preview.dirtyStatusLines.isEmpty {
                Section("Current Dirty State") {
                    ForEach(preview.dirtyStatusLines.prefix(40), id: \.self) { line in
                        Text(line)
                            .font(TahoeFont.mono(11))
                    }
                }
            }
            Section("Patch Preview") {
                Text(preview.diffPatch.isEmpty ? "No patch." : preview.diffPatch)
                    .font(TahoeFont.mono(10.5))
                    .textSelection(.enabled)
                if preview.patchTruncated {
                    Text("Preview truncated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button(role: .destructive, action: ContinuumAnalytics.wrapButton(
                        "restore_checkpoint",
                        {
                    restoreTarget = preview
                    restorePreview = nil
                
                        }
                    )) {
                    Label("Restore to checkpoint", systemImage: "arrow.uturn.backward")
                }
                .disabled(preview.isBlocked || isRestoring)
            } footer: {
                Text("Restoring uses the prepared preview id. If the worktree changes after this preview, the Mac daemon re-checks safety before applying.")
            }
        }
    }

    @MainActor
    private func refresh() async {
        guard client.supportsCodeWorkbenchRemote else {
            isLoading = false
            return
        }
        isLoading = true
        checkpoints = await client.listCheckpoints(sessionId: session.id)
        isLoading = false
    }

    @MainActor
    private func createCheckpoint() async {
        guard client.supportsCodeWorkbenchRemote else { return }
        isCreating = true
        defer { isCreating = false }
        if let checkpoint = await client.createCheckpoint(sessionId: session.id, summary: "Manual checkpoint") {
            checkpoints.insert(checkpoint, at: 0)
            message = "Checkpoint saved."
        } else {
            message = client.lastError ?? "Could not create checkpoint."
        }
    }

    @MainActor
    private func prepareRestore(_ checkpoint: CodeCheckpointSnapshot) async {
        preparingId = checkpoint.id
        defer { preparingId = nil }
        if let preview = await client.prepareCheckpointRestore(sessionId: session.id, checkpointId: checkpoint.id) {
            restorePreview = preview
            if !checkpoints.contains(where: { $0.id == preview.safety.id }) {
                checkpoints.insert(preview.safety, at: 0)
            }
        } else {
            message = client.lastError ?? "Could not prepare restore preview."
        }
    }

    @MainActor
    private func restoreSelectedPreview() async {
        guard let preview = restoreTarget else { return }
        isRestoring = true
        defer {
            isRestoring = false
            restoreTarget = nil
        }
        if let response = await client.restoreCheckpoint(
            sessionId: session.id,
            checkpointId: preview.target.id,
            previewId: preview.id
        ), response.restored {
            message = "Checkpoint restored."
            await refresh()
        } else {
            message = client.lastError ?? "Could not restore checkpoint."
        }
    }
}
