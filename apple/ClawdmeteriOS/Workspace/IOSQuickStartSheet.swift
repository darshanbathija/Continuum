import SwiftUI
import ClawdmeterShared

/// iOS counterpart to Mac's `QuickStartRepoSheet`. Posts to the daemon's
/// `/workspaces/quick-start` endpoint with name + parent. Daemon mkdir's
/// `parent/name` and runs `git init`.
struct IOSQuickStartSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var client: AgentControlClient
    @ObservedObject var allowList: WorkspaceAllowListCache
    var onSuccess: (CodeWorkspaceRecord) -> Void

    @State private var name: String = ""
    @State private var parent: String = ""
    @State private var isCreating: Bool = false
    @State private var errorMessage: String? = nil
    /// Persisted idempotency key for the Quick Start flow. Survives app
    /// kill via `RepoOnboardingIdempotencyStore` so a retry after the
    /// daemon completed `mkdir + git init` replays the cached response
    /// instead of failing with "folder already exists".
    @State private var idempotencyKey: String = RepoOnboardingIdempotencyStore.currentKey(for: .quickStart)

    var body: some View {
        NavigationStack {
            Form {
                Section("New repo") {
                    TextField("Name (e.g. scratchpad)", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isCreating)
                }
                Section("Parent folder on Mac") {
                    TextField("/Users/.../code", text: $parent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isCreating)
                    if let snapshot = allowList.snapshot, !snapshot.allowedRoots.isEmpty {
                        Text("Allowed: \(snapshot.allowedRoots.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Quick start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(isCreating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isCreating ? "Creating…" : "Create") {
                        Task { await create() }
                    }
                    .disabled(!canCreate || isCreating)
                }
            }
            .task { await allowList.refresh() }
            .onAppear {
                if parent.isEmpty,
                   let first = allowList.snapshot?.allowedRoots.first {
                    parent = first
                }
            }
        }
    }

    private var canCreate: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && !n.contains("/") && !n.hasPrefix(".") && !parent.isEmpty
    }

    private func create() async {
        errorMessage = nil
        switch allowList.validate(parent) {
        case .failure(let reason):
            errorMessage = reason
            return
        case .success: break
        }
        isCreating = true
        defer { isCreating = false }
        let result = await client.quickStartRepoOnMac(
            name: name,
            parent: parent,
            idempotencyKey: idempotencyKey
        )
        if result.unsupportedServer {
            errorMessage = "This Mac is on an older version. Update Clawdmeter on the Mac to enable iOS Quick Start."
            return
        }
        if let record = result.record {
            RepoOnboardingIdempotencyStore.clear(.quickStart)
            onSuccess(record)
            dismiss()
            return
        }
        if result.replayedWithoutRecord {
            RepoOnboardingIdempotencyStore.clear(.quickStart)
            _ = await client.refreshWorkspaces()
            dismiss()
            return
        }
        if let err = result.error {
            // Codex R4 #2: transport error preserves the key — the Mac
            // may still complete; next retry must reuse the key to
            // replay or join in-flight reservation.
            if result.transportError {
                errorMessage = "Network error — try again when reachable. The Mac may still be processing."
                return
            }
            switch err {
            case .alreadyRegistered:
                RepoOnboardingIdempotencyStore.clear(.quickStart)
                _ = await client.refreshWorkspaces()
                dismiss()
            default:
                RepoOnboardingIdempotencyStore.clear(.quickStart)
                errorMessage = iosFriendlyMessage(for: err)
            }
        } else {
            errorMessage = "Quick start failed for unknown reason."
        }
    }
}
