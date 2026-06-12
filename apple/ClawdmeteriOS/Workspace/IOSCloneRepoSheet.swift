import SwiftUI
import ClawdmeterShared

/// iOS counterpart to Mac's `CloneRepoSheet`. Posts to the daemon's
/// `/workspaces/from-github` endpoint. No NSOpenPanel — destination is a
/// text field validated against the cached `WorkspaceAllowListCache`.
struct IOSCloneRepoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var client: AgentControlClient
    @ObservedObject var allowList: WorkspaceAllowListCache
    var onSuccess: (CodeWorkspaceRecord) -> Void

    @State private var spec: String = ""
    @State private var destinationParent: String = ""
    @State private var isCloning: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showAuthBanner: Bool = false
    /// Persisted idempotency key for the Clone flow. Survives app kill
    /// via `RepoOnboardingIdempotencyStore` — if iOS dies between the
    /// daemon's clone completion and the response being observed, the
    /// retried tap reuses the same key and replays the daemon's cached
    /// response instead of re-executing the clone.
    @State private var idempotencyKey: String = RepoOnboardingIdempotencyStore.currentKey(for: .clone)

    var body: some View {
        NavigationStack {
            Form {
                Section("Repo") {
                    TextField("owner/repo or URL", text: $spec)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isCloning)
                }
                Section("Destination on Mac") {
                    TextField("/Users/.../code", text: $destinationParent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isCloning)
                    if let snapshot = allowList.snapshot, !snapshot.allowedRoots.isEmpty {
                        Text("Allowed: \(snapshot.allowedRoots.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if showAuthBanner {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("GitHub authentication failed", systemImage: "key.fill")
                                .font(.callout.weight(.semibold))
                            Text("On the Mac, run: `gh auth login`")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Clone from GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: ContinuumAnalytics.wrapButton(
                            "cancel",
                            {
 dismiss() 
                            }
                        )).disabled(isCloning)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isCloning ? "Cloning…" : "Clone", action: ContinuumAnalytics.wrapButton("clone_repo", { Task { await clone() } }))
                    .disabled(!canClone || isCloning)
                }
            }
            .task { await allowList.refresh() }
            .onAppear {
                if destinationParent.isEmpty,
                   let first = allowList.snapshot?.allowedRoots.first {
                    destinationParent = first
                }
            }
        }
    }

    private var canClone: Bool {
        !spec.trimmingCharacters(in: .whitespaces).isEmpty
            && !destinationParent.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func clone() async {
        errorMessage = nil
        showAuthBanner = false
        // Local pre-validation against the cached allow-list.
        switch allowList.validate(destinationParent) {
        case .failure(let reason):
            errorMessage = reason
            return
        case .success: break
        }
        isCloning = true
        defer { isCloning = false }
        let result = await client.cloneFromGitHubOnMac(
            spec: spec,
            destinationParent: destinationParent,
            idempotencyKey: idempotencyKey
        )
        if result.unsupportedServer {
            errorMessage = "This Mac is on an older version. Update Clawdmeter on the Mac to enable iOS clone."
            return
        }
        if let record = result.record {
            // Successful clone — clear the persisted key so the next
            // Clone sheet starts fresh.
            RepoOnboardingIdempotencyStore.clear(.clone)
            onSuccess(record)
            dismiss()
            return
        }
        if result.replayedWithoutRecord {
            // Daemon replayed a receipt-only entry from after-restart
            // audit-log recovery. The clone already happened on the
            // Mac. Refresh the workspace list and dismiss — no point
            // re-firing.
            RepoOnboardingIdempotencyStore.clear(.clone)
            _ = await client.refreshWorkspaces()
            dismiss()
            return
        }
        if let err = result.error {
            // Codex R4 #2: transport errors (URLSession threw before
            // any server response) MUST NOT clear the persisted key.
            // The Mac might have completed the clone; the next retry
            // needs the same key to either replay the daemon's cached
            // response or join its in-flight reservation. Surface the
            // banner so the user can retry when network recovers.
            if result.transportError {
                errorMessage = "Network error — try again when reachable. Your clone may still be running on the Mac."
                return
            }
            switch err {
            case .ghAuthFailed:
                // Clear the persisted key. Codex R3 #5: keeping the key
                // means a retry AFTER the user runs `gh auth login`
                // would replay the cached 401 (the daemon's outbox
                // recorded the failure). Fresh key on retry forces the
                // daemon to re-execute against the now-authenticated
                // gh, which is the user's actual intent.
                RepoOnboardingIdempotencyStore.clear(.clone)
                showAuthBanner = true
            case .alreadyRegistered:
                // Final outcome — clear the persisted key. The workspace
                // is already in client.workspaces via the daemon's
                // onWorkspaceRegistered callback.
                RepoOnboardingIdempotencyStore.clear(.clone)
                _ = await client.refreshWorkspaces()
                dismiss()
            default:
                // Final error — clear the persisted key so retry with
                // edited inputs gets a fresh slot.
                RepoOnboardingIdempotencyStore.clear(.clone)
                errorMessage = iosFriendlyMessage(for: err)
            }
        } else {
            errorMessage = "Clone failed for unknown reason."
        }
    }
}
