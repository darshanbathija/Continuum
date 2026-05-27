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
                    Button("Cancel") { dismiss() }.disabled(isCloning)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isCloning ? "Cloning…" : "Clone") {
                        Task { await clone() }
                    }
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
        if let err = result.error {
            switch err {
            case .ghAuthFailed:
                // Auth-failed is retryable after the user runs `gh auth
                // login`; keep the key so the immediate retry replays
                // the cached failure. The daemon's LRU TTL will retire
                // the slot before the user fixes auth and retries.
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
