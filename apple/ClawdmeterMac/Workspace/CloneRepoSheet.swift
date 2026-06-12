import SwiftUI
import AppKit
import ClawdmeterShared

/// "Open GitHub project" sheet. Form: spec field + destination parent +
/// gh-detection status row + Clone button. On Clone, shells out via
/// `RepoOnboarding.cloneFromGitHub` and surfaces auth failures with copy
/// commands the user can paste into Terminal.
struct CloneRepoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onboarding: RepoOnboarding
    /// Called with the registered workspace on success. Sheet dismisses
    /// itself; the parent uses this to focus the new repo in the sidebar.
    var onSuccess: (CodeWorkspaceRecord) -> Void

    @State private var spec: String = ""
    @State private var destinationParent: String = ""
    @State private var status: Status = .idle
    @State private var ghDetected: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showAuthBanner: Bool = false

    enum Status {
        case idle
        case cloning
        case finished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open GitHub project")
                .font(.system(size: 18, weight: .semibold))

            Form {
                TextField("owner/repo or URL", text: $spec,
                          prompt: Text("anthropics/claude-code-sdk"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(status == .cloning)

                HStack {
                    TextField("Destination parent", text: $destinationParent,
                              prompt: Text("/Users/.../code"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: ContinuumAnalytics.wrapButton("choose", chooseDestination))
                        .disabled(status == .cloning)
                }

                ghStatusRow
            }

            if showAuthBanner {
                authBanner
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if status == .cloning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Cloning \(normalizedSpec ?? spec)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: ContinuumAnalytics.wrapButton(
                        "cancel",
                        {
 dismiss() 
                        }
                    ))
                    .keyboardShortcut(.cancelAction)
                    .disabled(status == .cloning)
                Button(status == .cloning ? "Cloning…" : "Clone", action: ContinuumAnalytics.wrapButton(
                        "cloning_cloning_clone",
                        {
                    Task { await clone() }
                
                        }
                    ))
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canClone || status == .cloning)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            ghDetected = ShellRunner.locateBinary("gh") != nil
            destinationParent = UserDefaults.standard.string(forKey: PathAllowList.defaultParentKey)
                ?? defaultParentFallback()
        }
    }

    // MARK: - Computed UI

    private var canClone: Bool {
        normalizedSpec != nil && !destinationParent.isEmpty
    }

    private var normalizedSpec: String? {
        try? RepoOnboarding.normalizeCloneSpec(spec)
    }

    @ViewBuilder
    private var ghStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: ghDetected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ghDetected ? .green : .orange)
            if ghDetected {
                Text("GitHub CLI installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("GitHub CLI not found — install for private repos: ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Copy install command", action: ContinuumAnalytics.wrapButton(
                        "copy_install_command",
                        {
                    copyToClipboard("brew install gh")
                
                        }
                    ))
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var authBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").foregroundStyle(.orange)
                Text("GitHub authentication failed")
                    .font(.callout.weight(.semibold))
            }
            Text("Run `gh auth login` in Terminal, then try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Copy `gh auth login`", action: ContinuumAnalytics.wrapButton(
                        "copy_gh_auth_login",
                        {
                    copyToClipboard("gh auth login")
                
                        }
                    ))
                .buttonStyle(.link)
                .font(.caption)
                if !ghDetected {
                    Button("Copy `brew install gh`", action: ContinuumAnalytics.wrapButton(
                            "copy_brew_install_gh",
                            {
                        copyToClipboard("brew install gh")
                    
                            }
                        ))
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.5))
        )
    }

    // MARK: - Actions

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.title = "Pick a destination folder"
        if !destinationParent.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: destinationParent)
        }
        if panel.runModal() == .OK, let url = panel.urls.first {
            destinationParent = url.path
        }
    }

    private func clone() async {
        guard let _ = normalizedSpec else {
            errorMessage = "Spec doesn't look like a GitHub repo (try `owner/repo`)."
            return
        }
        status = .cloning
        errorMessage = nil
        showAuthBanner = false
        do {
            let record = try await onboarding.cloneFromGitHub(
                spec: spec,
                destinationParent: destinationParent
            )
            status = .finished
            onSuccess(record)
            dismiss()
        } catch let err as RepoOnboardingError {
            status = .idle
            switch err {
            case .ghAuthFailed:
                showAuthBanner = true
                errorMessage = nil
            case .alreadyRegistered:
                // RepoOnboarding's onWorkspaceRegistered callback already
                // fired for the existing record; the sidebar has handled it.
                // Just dismiss with a toast-like message.
                errorMessage = err.errorDescription
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    await MainActor.run { dismiss() }
                }
            default:
                errorMessage = [err.errorDescription, err.recoverySuggestion]
                    .compactMap { $0 }
                    .joined(separator: " — ")
            }
        } catch {
            status = .idle
            errorMessage = error.localizedDescription
        }
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func defaultParentFallback() -> String {
        // Real home — sandboxed builds otherwise default into the
        // container, which clashes with PathAllowList's real-home roots.
        (ClawdmeterRealHome.path() as NSString).appendingPathComponent("code")
    }
}
