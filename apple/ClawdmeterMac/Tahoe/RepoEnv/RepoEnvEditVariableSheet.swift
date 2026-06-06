import SwiftUI
import ClawdmeterShared

struct RepoEnvEditVariableSheet: View {
    @Environment(\.tahoe) private var t

    let mode: RepoEnvEditMode
    let workspaces: [CodeWorkspaceRecord]
    let sets: [RepoEnvSetRecord]
    let defaultWorkspaceId: UUID?
    let assignedWorkspaceIds: Set<UUID>
    let selectedSetIds: Set<UUID>
    let onCancel: () -> Void
    let onReveal: () throws -> String
    let onSave: (RepoEnvVariableDraft) -> Bool

    @State private var key = ""
    @State private var value = ""
    @State private var note = ""
    @State private var kind: RepoEnvVariableKind = .sensitive
    @State private var isEnabled = true
    @State private var selectedWorkspaceIds: Set<UUID> = []
    @State private var selectedSetIdsState: Set<UUID> = []
    @State private var revealError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(TahoeFont.body(16, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text(mode.isRotate ? "Enter the replacement value. Metadata and assignments stay unchanged." : "Update metadata, value, repo sharing, and set assignment.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                }
                Spacer()
                Button(action: onCancel) {
                    TahoeIcon("x", size: 12, weight: .bold)
                }
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Key")
                            .font(TahoeFont.body(12, weight: .bold))
                            .foregroundStyle(t.fg2)
                        TextField("KEY", text: $key)
                            .font(TahoeFont.mono(12))
                            .textFieldStyle(.roundedBorder)
                            .disabled(mode.isRotate)
                            .accessibilityIdentifier("settings.env.edit.key")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(mode.isRotate ? "New Value" : "Value")
                                .font(TahoeFont.body(12, weight: .bold))
                                .foregroundStyle(t.fg2)
                            Spacer()
                            if !mode.isRotate {
                                Button("Reveal Current") {
                                    revealCurrentValue()
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        SecureField(mode.isRotate ? "Replacement value" : "Leave blank to keep current value", text: $value)
                            .font(TahoeFont.mono(12))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("settings.env.edit.value")
                        if let revealError {
                            Text(revealError)
                                .font(TahoeFont.body(11))
                                .foregroundStyle(.red)
                        }
                    }

                    if !mode.isRotate {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Type")
                                .font(TahoeFont.body(12, weight: .bold))
                                .foregroundStyle(t.fg2)
                            Picker("Type", selection: $kind) {
                                ForEach(RepoEnvVariableKind.allCases) { kind in
                                    Text(kind.displayName).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Toggle("Enabled", isOn: $isEnabled)
                            .toggleStyle(.checkbox)
                            .font(TahoeFont.body(12, weight: .semibold))

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Note")
                                .font(TahoeFont.body(12, weight: .bold))
                                .foregroundStyle(t.fg2)
                            TextField("Optional context, owner, or usage note", text: $note)
                                .font(TahoeFont.body(12))
                                .textFieldStyle(.roundedBorder)
                        }

                        workspaceChecklist
                        setChecklist
                    }
                }
                .padding(.bottom, 18)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(mode.isRotate ? "Rotate" : "Save") {
                    _ = onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.env.edit.save")
                .disabled(!canSave)
            }
            .padding(.top, 16)
            .overlay(alignment: .top) {
                TahoeHair()
            }
        }
        .padding(24)
        .onAppear(perform: seed)
    }

    private var workspaceChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Repos")
                .font(TahoeFont.body(12, weight: .bold))
                .foregroundStyle(t.fg2)
            ForEach(workspaces) { workspace in
                Toggle(workspace.repoDisplayName, isOn: Binding(
                    get: { selectedWorkspaceIds.contains(workspace.id) },
                    set: { enabled in
                        if enabled {
                            selectedWorkspaceIds.insert(workspace.id)
                        } else {
                            selectedWorkspaceIds.remove(workspace.id)
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(TahoeFont.body(12))
            }
        }
    }

    private var setChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sets In This Repo")
                .font(TahoeFont.body(12, weight: .bold))
                .foregroundStyle(t.fg2)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(sets) { set in
                    let selected = selectedSetIdsState.contains(set.id)
                    Button {
                        if selected {
                            selectedSetIdsState.remove(set.id)
                        } else {
                            selectedSetIdsState.insert(set.id)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if selected {
                                TahoeIcon("check", size: 8, weight: .bold)
                            }
                            Text(set.name).lineLimit(1)
                        }
                        .font(TahoeFont.body(11.5, weight: .semibold))
                        .foregroundStyle(selected ? t.accent : t.fg3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .background {
                        Capsule().fill(selected ? t.accentAlpha(0.12) : t.accentAlpha(0.035))
                    }
                    .overlay {
                        Capsule().stroke(selected ? t.accentAlpha(0.45) : t.hairline, lineWidth: 1)
                    }
                }
            }
        }
    }

    private var canSave: Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedWorkspaceIds.isEmpty
            && (!mode.isRotate || !value.isEmpty)
    }

    private var draft: RepoEnvVariableDraft {
        RepoEnvVariableDraft(
            key: key,
            value: value,
            note: note,
            kind: kind,
            isEnabled: isEnabled,
            workspaceIds: selectedWorkspaceIds,
            setIds: selectedSetIdsState
        )
    }

    private func seed() {
        switch mode {
        case .edit(let variable), .rotate(let variable):
            key = variable.key
            note = variable.note ?? ""
            kind = variable.kind
            isEnabled = variable.isEnabled
            selectedWorkspaceIds = assignedWorkspaceIds.isEmpty ? Set(defaultWorkspaceId.map { [$0] } ?? []) : assignedWorkspaceIds
            selectedSetIdsState = selectedSetIds.isEmpty ? Set(sets.map(\.id)) : selectedSetIds
        case .duplicate(let variable, let originalValue):
            key = "\(variable.key)_COPY"
            value = originalValue
            note = variable.note ?? ""
            kind = variable.kind
            isEnabled = true
            selectedWorkspaceIds = assignedWorkspaceIds.isEmpty ? Set(defaultWorkspaceId.map { [$0] } ?? []) : assignedWorkspaceIds
            selectedSetIdsState = selectedSetIds.isEmpty ? Set(sets.map(\.id)) : selectedSetIds
        }
    }

    private func revealCurrentValue() {
        do {
            value = try onReveal()
            revealError = nil
        } catch {
            revealError = error.localizedDescription
        }
    }
}
