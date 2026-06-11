import SwiftUI
import ClawdmeterShared
import UniformTypeIdentifiers

struct RepoEnvImportSheet: View {
    @Environment(\.tahoe) private var t

    let workspaces: [CodeWorkspaceRecord]
    let sets: [RepoEnvSetRecord]
    let defaultWorkspaceId: UUID?
    let repoRootProvider: (UUID) -> String?
    let previewProvider: (String, UUID) -> [RepoEnvImportPreviewRecord]
    let onCancel: () -> Void
    let onImport: (RepoEnvImportDraft) -> Bool

    @State private var importSource: RepoEnvVendorImportSource = .paste
    @State private var text = ""
    @State private var previews: [RepoEnvImportPreviewRecord] = []
    @State private var selectedWorkspaceIds: Set<UUID> = []
    @State private var selectedSetIds: Set<UUID> = []
    @State private var conflictStrategy: RepoEnvImportConflictStrategy = .skip
    @State private var kind: RepoEnvVariableKind = .sensitive
    @State private var isPickingFile = false
    @State private var fileError: String?
    @State private var previewDebounce: Task<Void, Never>?
    @State private var vendorOptions = RepoEnvVendorImportOptions()
    @State private var vendorProgress: RepoEnvVendorImportProgress?
    @State private var vendorImportTask: Task<Void, Never>?
    @State private var vendorError: String?
    // Cached so the view body doesn't re-run locateBinary (UserDefaults + isExecutableFile +
    // possible `which` shell-out) on every render — including each progress tick mid-import.
    @State private var vendorBinaryInstalled: Bool = false

    private let vendorImporter = RepoEnvVendorSecretsImporter()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourcePicker
                    if importSource == .paste {
                        pasteControls
                    } else {
                        vendorControls
                    }
                    if vendorProgress != nil, importSource != .paste {
                        vendorProgressBar
                    }
                    if let vendorError {
                        Text(vendorError)
                            .font(TahoeFont.body(11))
                            .foregroundStyle(.red)
                    }
                    if let fileError {
                        Text(fileError)
                            .font(TahoeFont.body(11))
                            .foregroundStyle(.red)
                    }
                    importTargets
                    if importSource == .paste || !previews.isEmpty {
                        importPreviewTable
                    }
                }
                .padding(.bottom, 18)
            }

            footer
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
            syncVendorRepoRoot()
            refreshVendorBinaryStatus()
            refreshPreview()
        }
        .onChange(of: selectedWorkspaceIds) { _, _ in
            syncVendorRepoRoot()
        }
        .onChange(of: importSource) { _, newSource in
            vendorError = nil
            refreshVendorBinaryStatus()
            if newSource == .paste {
                vendorProgress = nil
                vendorImportTask?.cancel()
                vendorImportTask = nil
            }
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

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import Environment Variables")
                    .font(TahoeFont.body(16, weight: .bold))
                    .foregroundStyle(t.fg)
                Text(headerSubtitle)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            }
            Spacer()
            Button(action: onCancel) {
                TahoeIcon("x", size: 12, weight: .bold)
            }
            .buttonStyle(.borderless)
            .disabled(isVendorImporting)
        }
    }

    private var headerSubtitle: String {
        switch importSource {
        case .paste:
            return "Paste env contents or import a local file, then review parsed keys before saving."
        case .aws:
            return "Pull secrets from AWS Secrets Manager using the aws CLI, then import them into repo sets."
        case .vercel:
            return "Pull project env vars from Vercel using the vercel CLI for the selected repository."
        case .gcp:
            return "Pull secrets from GCP Secret Manager using the gcloud CLI, then import them into repo sets."
        }
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $importSource) {
            ForEach(RepoEnvVendorImportSource.allCases) { source in
                Text(source.rawValue).tag(source)
            }
        }
        .pickerStyle(.segmented)
        // Lock the source while a vendor import is running so a mid-flight tab switch can't
        // leave the task running against a source the UI no longer represents.
        .disabled(isVendorImporting)
        .accessibilityIdentifier("settings.env.import.source")
    }

    private var pasteControls: some View {
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
                    .onChange(of: text) { _, _ in scheduleRefreshPreview() }
            }
        }
    }

    private var vendorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
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

            vendorOptionsFields

            HStack(spacing: 10) {
                vendorCLIHint
                Spacer(minLength: 0)
            }

            if !hasSingleVendorWorkspace {
                Text(vendorWorkspaceHint)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var vendorOptionsFields: some View {
        switch importSource {
        case .paste:
            EmptyView()
        case .aws:
            VStack(alignment: .leading, spacing: 10) {
                labeledField(title: "AWS Region", placeholder: "Optional — uses CLI default") {
                    TextField("us-east-1", text: $vendorOptions.awsRegion)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField(title: "Name Prefix", placeholder: "Optional filter") {
                    TextField("prod/", text: $vendorOptions.awsNamePrefix)
                        .textFieldStyle(.roundedBorder)
                }
            }
        case .vercel:
            VStack(alignment: .leading, spacing: 10) {
                labeledField(title: "Environment") {
                    Picker("Environment", selection: $vendorOptions.vercelEnvironment) {
                        ForEach(RepoEnvVercelEnvironment.allCases) { environment in
                            Text(environment.displayName).tag(environment)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Text(vercelRepoHint)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg3)
            }
        case .gcp:
            VStack(alignment: .leading, spacing: 10) {
                labeledField(title: "GCP Project", placeholder: "Optional — uses gcloud default") {
                    TextField("my-project", text: $vendorOptions.gcpProject)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField(title: "Name Prefix", placeholder: "Optional filter") {
                    TextField("prod-", text: $vendorOptions.gcpNamePrefix)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var vendorCLIHint: some View {
        Group {
            if let binary = importSource.cliBinaryName {
                let installed = vendorBinaryInstalled
                HStack(spacing: 6) {
                    TahoeIcon(installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", size: 11)
                        .foregroundStyle(installed ? t.accent : .orange)
                    Text(installed ? "\(binary) CLI detected on PATH." : "\(binary) CLI not found. Install it before importing.")
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg3)
                }
            }
        }
    }

    private var vercelRepoHint: String {
        if let workspaceId = selectedVendorWorkspaceId,
           let root = repoRootProvider(workspaceId) {
            return "Uses linked Vercel project in \(URL(fileURLWithPath: root).lastPathComponent)."
        }
        return "Select exactly one target repository workspace with a linked Vercel project."
    }

    private var selectedVendorWorkspaceId: UUID? {
        guard selectedWorkspaceIds.count == 1 else { return nil }
        return selectedWorkspaceIds.first
    }

    private var hasSingleVendorWorkspace: Bool {
        selectedWorkspaceIds.count == 1
    }

    private var vendorWorkspaceHint: String {
        if selectedWorkspaceIds.isEmpty {
            return "Select one repository workspace to import vendor secrets."
        }
        return "Select exactly one repository workspace for vendor import."
    }

    private func labeledField<Content: View>(
        title: String,
        placeholder: String = "",
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TahoeFont.body(12, weight: .bold))
                .foregroundStyle(t.fg2)
            content()
            if !placeholder.isEmpty {
                Text(placeholder)
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.fg4)
            }
        }
    }

    private var vendorProgressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView(value: vendorProgress?.fraction ?? 0)
                    .progressViewStyle(.linear)
                Text("Importing variables")
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Spacer(minLength: 0)
                if isVendorImporting {
                    Button("Cancel") {
                        vendorImportTask?.cancel()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.env.import.vendor-cancel")
                }
            }
            Text(vendorProgress?.statusLabel ?? "")
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg3)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("settings.env.import.vendor-progress")
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
                        syncVendorRepoRoot()
                        refreshPreview()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(TahoeFont.body(12))
                .disabled(isVendorImporting)
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
                    .disabled(isVendorImporting)
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

    private var footer: some View {
        HStack {
            Text(importSummary)
                .font(TahoeFont.body(12, weight: .semibold))
                .foregroundStyle(t.fg2)
            Spacer()
            Button("Cancel", action: onCancel)
                .disabled(isVendorImporting)
            if importSource == .paste {
                Button("Import") {
                    _ = onImport(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canImport)
                .accessibilityIdentifier("settings.env.import.save")
            } else {
                Button(importSource.oneClickLabel) {
                    vendorImportTask?.cancel()
                    vendorImportTask = Task { await runVendorImport() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartVendorImport || isVendorImporting)
                .accessibilityIdentifier("settings.env.import.vendor-save")
            }
        }
    }

    private var canImport: Bool {
        !selectedWorkspaceIds.isEmpty && previews.contains(where: \.canImport)
    }

    private var canStartVendorImport: Bool {
        guard hasSingleVendorWorkspace else { return false }
        guard importSource.cliBinaryName != nil, vendorBinaryInstalled else { return false }
        if importSource == .vercel {
            guard let workspaceId = selectedVendorWorkspaceId,
                  repoRootProvider(workspaceId) != nil
            else { return false }
        }
        return true
    }

    private var isVendorImporting: Bool {
        guard let vendorProgress else { return false }
        switch vendorProgress.phase {
        case .complete, .failed:
            return false
        default:
            return true
        }
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
        if case .complete(let variableCount, let secretCount, let skippedCount) = vendorProgress?.phase {
            var message: String
            if let secretCount, secretCount != variableCount {
                message = "Imported \(variableCount) variable\(variableCount == 1 ? "" : "s") from \(secretCount) secret\(secretCount == 1 ? "" : "s") in \(importSource.displayName)."
            } else {
                message = "Imported \(variableCount) variable\(variableCount == 1 ? "" : "s") from \(importSource.displayName)."
            }
            if skippedCount > 0 {
                message += " \(skippedCount) skipped (couldn't be read)."
            }
            return message
        }
        let ready = previews.filter { $0.status == .ready }.count
        let duplicates = previews.filter { $0.status == .duplicate }.count
        let invalid = previews.filter { $0.status == .invalid || $0.status == .emptyValue }.count
        if importSource != .paste, isVendorImporting {
            return vendorProgress?.statusLabel ?? "Importing secrets…"
        }
        return "\(ready) ready · \(duplicates) duplicates · \(invalid) invalid"
    }

    private func syncVendorRepoRoot() {
        vendorOptions.repoRoot = selectedVendorWorkspaceId.flatMap { repoRootProvider($0) }
    }

    private func refreshVendorBinaryStatus() {
        guard let binary = importSource.cliBinaryName else {
            vendorBinaryInstalled = false
            return
        }
        vendorBinaryInstalled = ShellRunner.locateBinary(binary) != nil
    }

    private func scheduleRefreshPreview() {
        previewDebounce?.cancel()
        previewDebounce = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            refreshPreview()
        }
    }

    private func refreshPreview() {
        previewDebounce?.cancel()
        previewDebounce = nil
        // Paste/file imports support multiple target workspaces; preview against the
        // first selected one (vendor imports enforce a single workspace separately).
        // Using selectedVendorWorkspaceId here (nil unless exactly one is selected)
        // blanked previews for multi-target paste imports.
        guard let workspaceId = selectedWorkspaceIds.first ?? defaultWorkspaceId else {
            previews = []
            return
        }
        previews = previewProvider(text, workspaceId)
    }

    @MainActor
    private func runVendorImport() async {
        vendorError = nil
        syncVendorRepoRoot()
        guard let workspaceId = selectedVendorWorkspaceId else {
            vendorError = RepoEnvVendorSecretsImportError.singleWorkspaceRequired.localizedDescription
            return
        }
        vendorProgress = .init(phase: .listing)

        do {
            let fetchResult = try await vendorImporter.fetchSecrets(
                source: importSource,
                options: vendorOptions
            ) { update in
                Task { @MainActor in
                    // Drop a late fetching-progress hop that lands after we've moved on to
                    // importing/complete — these @MainActor hops aren't ordered, and a stale
                    // .fetching would otherwise flip the UI back to "still importing".
                    if case .fetching = update.phase, let current = vendorProgress?.phase {
                        switch current {
                        case .importing, .complete: return
                        default: break
                        }
                    }
                    vendorProgress = update
                }
            }

            try Task.checkCancellation()

            // Parse fetched secrets straight into previews — never stash the plaintext in the
            // `text` editor state, which would linger in memory and show if the user flipped
            // back to the Paste tab.
            previews = previewProvider(fetchResult.envText, workspaceId)

            let importable = previews.filter(\.canImport)
            guard !importable.isEmpty else {
                throw RepoEnvVendorSecretsImportError.noSecretsFound(
                    "Fetched \(fetchResult.variableCount) variable\(fetchResult.variableCount == 1 ? "" : "s") from \(fetchResult.secretCount) secret\(fetchResult.secretCount == 1 ? "" : "s"), but none were importable."
                )
            }

            let variableCount = importable.count
            vendorProgress = .init(phase: .importing(current: 0, total: variableCount))
            try await Task.yield()
            vendorProgress = .init(phase: .importing(current: variableCount, total: variableCount))
            let succeeded = onImport(draft)
            previews = []  // import done — don't retain fetched secret values in view state
            if succeeded {
                let skippedCount = fetchResult.skippedSecretNames.count
                vendorProgress = .init(
                    phase: .complete(
                        variableCount: variableCount,
                        secretCount: fetchResult.secretCount == variableCount ? nil : fetchResult.secretCount,
                        skippedCount: skippedCount
                    )
                )
                // Auto-dismiss on a clean import; if some secrets were skipped, stay open so
                // the user can read the skipped count before closing manually.
                if skippedCount == 0 {
                    try? await Task.sleep(for: .milliseconds(350))
                    onCancel()
                }
            } else {
                vendorProgress = .init(phase: .failed("Import failed after fetching secrets."))
            }
        } catch is CancellationError {
            vendorProgress = nil
            previews = []
        } catch {
            vendorProgress = .init(phase: .failed(error.localizedDescription))
            vendorError = error.localizedDescription
            previews = []
        }
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
