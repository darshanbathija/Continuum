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
    /// Stable idempotency key for this sheet's lifetime. Generated once at
    /// mount; reused on every Clone tap so a lost response retried with
    /// the same key replays the cached server result instead of
    /// re-executing the clone (which would 409 with "destination exists").
    @State private var idempotencyKey: String = UUID().uuidString

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
            onSuccess(record)
            dismiss()
            return
        }
        if let err = result.error {
            switch err {
            case .ghAuthFailed:
                showAuthBanner = true
            case .alreadyRegistered:
                // Refresh + close — workspace is now in client.workspaces.
                _ = await client.refreshWorkspaces()
                dismiss()
            default:
                errorMessage = iosFriendlyMessage(for: err)
            }
        } else {
            errorMessage = "Clone failed for unknown reason."
        }
    }
}
