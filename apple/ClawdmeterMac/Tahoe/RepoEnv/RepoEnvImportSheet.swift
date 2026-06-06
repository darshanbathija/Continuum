import SwiftUI
import ClawdmeterShared
import UniformTypeIdentifiers

struct RepoEnvImportSheet: View {
    @Environment(\.tahoe) private var t

    let workspaces: [CodeWorkspaceRecord]
    let sets: [RepoEnvSetRecord]
    let defaultWorkspaceId: UUID?
    let previewProvider: (String, UUID) -> [RepoEnvImportPreviewRecord]
    let onCancel: () -> Void
    let onImport: (RepoEnvImportDraft) -> Bool

    @State private var text = ""
    @State private var previews: [RepoEnvImportPreviewRecord] = []
    @State private var selectedWorkspaceIds: Set<UUID> = []
    @State private var selectedSetIds: Set<UUID> = []
    @State private var conflictStrategy: RepoEnvImportConflictStrategy = .skip
    @State private var kind: RepoEnvVariableKind = .sensitive
    @State private var isPickingFile = false
    @State private var fileError: String?
    @State private var previewDebounce: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import .env")
                        .font(TahoeFont.body(16, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text("Paste env contents or import a local file, then review parsed keys before saving.")
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
                    HStack(spacing: 12) {
                        Button {
                            isPickingFile = true
                        } label: {
                            HStack(spacing: 7) {
                                TahoeIcon("tray", size: 12)
                                Text("Import .env")
                            }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("settings.env.import.file")

                        Picker("Duplicates", selection: $conflictStrategy) {
                            ForEach(RepoEnvImportConflictStrategy.allCases) { strategy in
                                Text(strategy.displayName).tag(strategy)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)

                        Picker("Type", selection: $kind) {
                            ForEach(RepoEnvVariableKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 128)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Contents")
                            .font(TahoeFont.body(12, weight: .bold))
                            .foregroundStyle(t.fg2)
                        TextEditor(text: $text)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(minHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(t.accentAlpha(0.035))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(t.hairline, lineWidth: 1)
                            }
                            .accessibilityIdentifier("settings.env.import.contents")
                            // Debounce: typing fires onChange per keystroke; coalesce so we re-parse once typing settles.
                            .onChange(of: text) { _, _ in scheduleRefreshPreview() }
                    }

                    if let fileError {
                        Text(fileError)
                            .font(TahoeFont.body(11))
                            .foregroundStyle(.red)
                    }

                    importTargets
                    importPreviewTable
                }
                .padding(.bottom, 18)
            }

            HStack {
                Text(importSummary)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Import") {
                    _ = onImport(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canImport)
                .accessibilityIdentifier("settings.env.import.save")
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
            refreshPreview()
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.plainText, .text, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                    text = try String(contentsOf: url, encoding: .utf8)
                    fileError = nil
                    refreshPreview()
                } catch {
                    fileError = error.localizedDescription
                }
            case .failure(let error):
                fileError = error.localizedDescription
            }
        }
    }

    private var importTargets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Targets")
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
                        refreshPreview()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(TahoeFont.body(12))
            }
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
                            if selected { TahoeIcon("check", size: 8, weight: .bold) }
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

    private var importPreviewTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preview")
                    .font(TahoeFont.body(12, weight: .bold))
                    .foregroundStyle(t.fg2)
                Spacer()
                Text("\(previews.filter(\.canImport).count) importable")
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.fg3)
            }
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(previews.prefix(80)) { preview in
                    HStack(spacing: 10) {
                        Text("\(preview.line)")
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(t.fg4)
                            .frame(width: 34, alignment: .trailing)
                        Text(preview.key ?? "—")
                            .font(TahoeFont.mono(11.5, weight: .bold))
                            .foregroundStyle(preview.canImport ? t.fg : t.fg4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(previewStatusLabel(preview.status))
                            .font(TahoeFont.body(10.5, weight: .bold))
                            .foregroundStyle(preview.canImport ? t.accent : t.fg4)
                            .frame(width: 92, alignment: .leading)
                        Text(preview.message)
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg3)
                            .frame(width: 180, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    if preview.id != previews.prefix(80).last?.id {
                        TahoeHair()
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(t.accentAlpha(0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(t.hairline, lineWidth: 1)
            }
            .accessibilityIdentifier("settings.env.import.preview")
        }
    }

    private var canImport: Bool {
        !selectedWorkspaceIds.isEmpty && previews.contains(where: \.canImport)
    }

    private var draft: RepoEnvImportDraft {
        RepoEnvImportDraft(
            previews: previews,
            workspaceIds: selectedWorkspaceIds,
            setIds: selectedSetIds,
            conflictStrategy: conflictStrategy,
            kind: kind
        )
    }

    private var importSummary: String {
        let ready = previews.filter { $0.status == .ready }.count
        let duplicates = previews.filter { $0.status == .duplicate }.count
        let invalid = previews.filter { $0.status == .invalid || $0.status == .emptyValue }.count
        return "\(ready) ready · \(duplicates) duplicates · \(invalid) invalid"
    }

    // Coalesce keystroke-driven re-parses behind a 200ms timer so previewProvider runs once typing settles, not per character.
    private func scheduleRefreshPreview() {
        previewDebounce?.cancel()
        previewDebounce = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            refreshPreview()
        }
    }

    private func refreshPreview() {
        // Definitive refreshes (paste/file-load/target toggle) supersede any pending debounce.
        previewDebounce?.cancel()
        previewDebounce = nil
        guard let workspaceId = selectedWorkspaceIds.first ?? defaultWorkspaceId else {
            previews = []
            return
        }
        previews = previewProvider(text, workspaceId)
    }

    private func previewStatusLabel(_ status: RepoEnvImportPreviewStatus) -> String {
        switch status {
        case .ready: return "Ready"
        case .duplicate: return "Duplicate"
        case .invalid: return "Invalid"
        case .emptyValue: return "Empty"
        case .skipped: return "Skipped"
        }
    }
}
