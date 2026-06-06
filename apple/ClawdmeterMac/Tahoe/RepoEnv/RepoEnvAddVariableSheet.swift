import SwiftUI
import ClawdmeterShared

struct RepoEnvAddVariableSheet: View {
    @Environment(\.tahoe) private var t

    let workspaces: [CodeWorkspaceRecord]
    let sets: [RepoEnvSetRecord]
    let defaultWorkspaceId: UUID?
    let onCancel: () -> Void
    let onImport: () -> Void
    let onSave: (RepoEnvVariableDraft) -> Bool

    @State private var key = ""
    @State private var value = ""
    @State private var note = ""
    @State private var kind: RepoEnvVariableKind = .sensitive
    @State private var selectedWorkspaceIds: Set<UUID> = []
    @State private var selectedSetIds: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Env Variable")
                        .font(TahoeFont.body(16, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text("Values are stored in Keychain. Shared variables default to every set in each selected repo.")
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
                        TextField("OPENAI_API_KEY", text: $key)
                            .font(TahoeFont.mono(12))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("settings.env.variable.key")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Value")
                            .font(TahoeFont.body(12, weight: .bold))
                            .foregroundStyle(t.fg2)
                        SecureField("Paste value", text: $value)
                            .font(TahoeFont.mono(12))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("settings.env.variable.value")
                    }

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

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Note")
                            .font(TahoeFont.body(12, weight: .bold))
                            .foregroundStyle(t.fg2)
                        TextField("Optional context, owner, or usage note", text: $note)
                            .font(TahoeFont.body(12))
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sets In This Repo")
                            .font(TahoeFont.body(12, weight: .bold))
                            .foregroundStyle(t.fg2)
                        if sets.isEmpty {
                            Text("The default local set will be created automatically.")
                                .font(TahoeFont.body(12))
                                .foregroundStyle(t.fg3)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], alignment: .leading, spacing: 8) {
                                ForEach(sets) { set in
                                    let selected = selectedSetIds.contains(set.id)
                                    Button {
                                        if selected {
                                            selectedSetIds.remove(set.id)
                                        } else {
                                            selectedSetIds.insert(set.id)
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            if selected {
                                                TahoeIcon("check", size: 8, weight: .bold)
                                            }
                                            Text(set.name)
                                                .lineLimit(1)
                                        }
                                        .font(TahoeFont.body(11.5, weight: .semibold))
                                        .foregroundStyle(selected ? t.accent : t.fg3)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .background {
                                        Capsule()
                                            .fill(selected ? t.accentAlpha(0.12) : t.accentAlpha(0.035))
                                    }
                                    .overlay {
                                        Capsule()
                                            .stroke(selected ? t.accentAlpha(0.45) : t.hairline, lineWidth: 1)
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.env.variable.sets")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Share With Repos")
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
                .padding(.bottom, 18)
            }

            HStack(spacing: 12) {
                Button(action: onImport) {
                    HStack(spacing: 7) {
                        TahoeIcon("tray", size: 12)
                        Text("Import .env")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.env.variable.import")

                Text("or add one variable")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)

                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add Another") {
                    if onSave(draft) {
                        key = ""
                        value = ""
                        note = ""
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canSave)
                Button("Save") {
                    if onSave(draft) {
                        onCancel()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.env.variable.save")
                .disabled(!canSave)
            }
            .padding(.top, 16)
            .overlay(alignment: .top) {
                TahoeHair()
            }
        }
        .padding(24)
        .onAppear {
            if selectedWorkspaceIds.isEmpty, let defaultWorkspaceId {
                selectedWorkspaceIds.insert(defaultWorkspaceId)
            }
            if selectedSetIds.isEmpty {
                selectedSetIds = Set(sets.map(\.id))
            }
        }
    }

    private var canSave: Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedWorkspaceIds.isEmpty
            && !value.isEmpty
    }

    private var draft: RepoEnvVariableDraft {
        RepoEnvVariableDraft(
            key: key,
            value: value,
            note: note,
            kind: kind,
            isEnabled: true,
            workspaceIds: selectedWorkspaceIds,
            setIds: selectedSetIds
        )
    }
}
