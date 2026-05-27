import SwiftUI
import AppKit
import ClawdmeterShared

/// "Quick start" sheet. Creates `parent/name`, runs `git init` inside, and
/// registers the new directory as a workspace. Name validation rejects
/// empty / slash / leading-dot. No README scaffolding — keep it minimal,
/// matching Conductor's flow.
struct QuickStartRepoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onboarding: RepoOnboarding
    var onSuccess: (CodeWorkspaceRecord) -> Void

    @State private var name: String = ""
    @State private var parent: String = ""
    @State private var isCreating: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quick start")
                .font(.system(size: 18, weight: .semibold))

            Text("Create a new empty git repository.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                TextField("Name", text: $name, prompt: Text("scratchpad"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCreating)
                HStack {
                    TextField("Parent folder", text: $parent, prompt: Text("/Users/.../code"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseParent)
                        .disabled(isCreating)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button(isCreating ? "Creating…" : "Create") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate || isCreating)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            parent = UserDefaults.standard.string(forKey: PathAllowList.defaultParentKey)
                ?? defaultParentFallback()
        }
    }

    private var canCreate: Bool {
        (try? RepoOnboarding.validateQuickStartName(name)) != nil && !parent.isEmpty
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.title = "Pick a parent folder"
        if !parent.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: parent)
        }
        if panel.runModal() == .OK, let url = panel.urls.first {
            parent = url.path
        }
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let record = try await onboarding.quickStart(name: name, in: parent)
            onSuccess(record)
            dismiss()
        } catch let err as RepoOnboardingError {
            errorMessage = [err.errorDescription, err.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: " — ")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func defaultParentFallback() -> String {
        // Real home — sandboxed builds otherwise default into the
        // container, which clashes with PathAllowList's real-home roots.
        (ClawdmeterRealHome.path() as NSString).appendingPathComponent("code")
    }
}
