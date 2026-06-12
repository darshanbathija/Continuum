import SwiftUI
import ClawdmeterShared

// MARK: - Settings section

struct CustomProviderSettingsSection: View {
    var runtime: AppRuntime?

    var body: some View {
        if let runtime {
            CustomProviderSettingsContent(runtime: runtime)
        } else {
            CustomProviderSettingsUnavailableContent()
        }
    }
}

private struct CustomProviderSettingsUnavailableContent: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        Text("Custom providers are unavailable in this preview.")
            .font(TahoeFont.body(12.5))
            .foregroundStyle(t.fg3)
    }
}

struct CustomProviderEditorPresentation: Identifiable {
    let id = UUID()
    var editingRecord: CustomProviderRecord?
}

private struct CustomProviderSettingsContent: View {
    @Environment(\.tahoe) private var t
    let runtime: AppRuntime

    @State private var editorPresentation: CustomProviderEditorPresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CustomProviderRows(
                store: runtime.customProviderStore,
                client: runtime.loopbackClient,
                registry: runtime.agentSessionRegistry,
                onEdit: { record in
                    editorPresentation = CustomProviderEditorPresentation(editingRecord: record)
                }
            )

            Button {
                editorPresentation = CustomProviderEditorPresentation(editingRecord: nil)
            } label: {
                HStack(spacing: 6) {
                    TahoeIcon("plus", size: 11, weight: .bold)
                    Text("Add provider")
                        .font(TahoeFont.body(12.5, weight: .semibold))
                }
                .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityIdentifier("settings.provider.custom.add")
        }
        .sheet(item: $editorPresentation) { presentation in
            CustomProviderEditorSheet(
                store: runtime.customProviderStore,
                client: runtime.loopbackClient,
                editingRecord: presentation.editingRecord
            ) {
                editorPresentation = nil
            }
        }
    }
}

// MARK: - Rows

struct CustomProviderRows: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var store: CustomProviderStore
    var client: AgentControlClient?
    var registry: AgentSessionRegistry?
    var onEdit: (CustomProviderRecord) -> Void

    @State private var catalog: ModelCatalog = .bundled
    @State private var recordPendingDelete: CustomProviderRecord?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.records.isEmpty {
                Text("Connect OpenAI- or Anthropic-compatible endpoints (Baseten, DeepInfra, Moonshot, …). Models are fetched from `/v1/models` after a successful test.")
                    .font(TahoeFont.body(12.5))
                    .foregroundStyle(t.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.records) { record in
                    CustomProviderRow(
                        record: record,
                        store: store,
                        catalog: catalog,
                        isEnabled: enabledBinding(for: record),
                        onEdit: { onEdit(record) },
                        onDelete: {
                            recordPendingDelete = record
                            showDeleteConfirm = true
                        },
                        onSelectModel: { modelId in
                            selectDefaultModel(modelId, for: record)
                        }
                    )
                    if record.id != store.records.last?.id {
                        TahoeHair()
                    }
                }
            }
        }
        .task { await refreshCatalog() }
        .onReceive(store.$records) { _ in
            catalog = catalogMergedWithStore(catalog)
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showDeleteConfirm,
            presenting: recordPendingDelete
        ) { record in
            Button("Delete", role: .destructive) {
                delete(record)
            }
            Button("Cancel", role: .cancel) {
                recordPendingDelete = nil
            }
        } message: { record in
            Text(deleteDialogMessage(for: record))
        }
    }

    private var deleteDialogTitle: String {
        "Delete custom provider?"
    }

    private func deleteDialogMessage(for record: CustomProviderRecord) -> String {
        let active = registry?.sessions(customProviderId: record.id)
            .filter { $0.archivedAt == nil }
            .count ?? 0
        if active > 0 {
            return "\(record.displayLabel) has \(active) active session\(active == 1 ? "" : "s"). Deleting does not stop live sessions, but they cannot respawn on this endpoint."
        }
        return "Remove \(record.displayLabel) from Settings. Live sessions keep running until they end."
    }

    private func enabledBinding(for record: CustomProviderRecord) -> Binding<Bool> {
        Binding(
            get: { record.isEnabled },
            set: { newValue in
                do {
                    try store.setEnabled(id: record.id, isEnabled: newValue)
                    Task { await refreshCatalog() }
                } catch {
                    // Best-effort — store surfaces typed errors via OSLog.
                }
            }
        )
    }

    private func selectDefaultModel(_ modelId: String, for record: CustomProviderRecord) {
        do {
            try store.setDefaultModel(id: record.id, modelId: modelId)
        } catch {}
    }

    private func delete(_ record: CustomProviderRecord) {
        do {
            try store.delete(id: record.id)
            recordPendingDelete = nil
            Task { await refreshCatalog() }
        } catch {}
    }

    private func refreshCatalog() async {
        if let client {
            await client.refreshModelCatalog()
            catalog = client.modelCatalog
        } else {
            catalog = catalogMergedWithStore(.bundled)
        }
    }

    private func catalogMergedWithStore(_ base: ModelCatalog) -> ModelCatalog {
        ModelCatalog(
            claude: base.claude,
            codex: base.codex,
            gemini: base.gemini,
            opencode: base.opencode,
            cursor: base.cursor,
            grok: base.grok,
            enabledProviderIDs: base.enabledProviderIDs,
            customProviders: store.allRecords().map { store.wireSummary(for: $0) },
            updatedAt: base.updatedAt
        )
    }
}

private struct CustomProviderRow: View {
    @Environment(\.tahoe) private var t
    let record: CustomProviderRecord
    @ObservedObject var store: CustomProviderStore
    let catalog: ModelCatalog
    @Binding var isEnabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSelectModel: (String) -> Void

    private var choice: ProviderChoice { .custom(record.id) }

    private var statusInfo: (ProviderDeviceAuthStatus, String?) {
        CustomProviderSettingsSupport.deviceAuthStatus(for: record, store: store)
    }

    private var selectedModelId: String? {
        record.defaultModelId ?? record.models.first?.id
    }

    private var selectedEntry: ModelCatalogEntry? {
        guard let selectedModelId else { return nil }
        return choice.models(in: catalog).first { $0.id == selectedModelId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    CustomProviderGlyph(label: record.displayLabel, size: 28)
                    CustomProviderDot(record.id, size: 7)
                        .offset(x: 2, y: 2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(record.displayLabel)
                            .font(TahoeFont.body(13.5, weight: .semibold))
                            .foregroundStyle(t.fg)
                        ProviderAuthTypeBadge(authType: .custom)
                    }
                    Text(hostSubtitle)
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                    if let message = statusInfo.1, !isEnabled {
                        Text(message)
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg3)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button("Edit", action: onEdit)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.provider.custom.\(record.id).edit")
                    Button("Delete", action: onDelete)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.provider.custom.\(record.id).delete")
                }
                modelMenu
                if isEnabled {
                    Button("Disconnect") {
                        isEnabled = false
                    }
                    .buttonStyle(.plain)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.fg2)
                    .help("Disconnect \(record.displayLabel)")
                    .accessibilityIdentifier("settings.provider.custom.\(record.id).disconnect")
                } else {
                    Button {
                        isEnabled = true
                    } label: {
                        HStack(spacing: 4) {
                            TahoeIcon("plus", size: 10, weight: .bold)
                            Text("Connect")
                        }
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(t.hairline, lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Connect \(record.displayLabel)")
                    .accessibilityIdentifier("settings.provider.custom.\(record.id).connect")
                }
            }
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.provider.custom.\(record.id)")
    }

    private var hostSubtitle: String {
        CustomProviderRecord.hostLabel(from: record.baseURL) ?? record.baseURL
    }

    private var modelMenu: some View {
        Menu {
            let sections = ProviderModelPickerSupport.sections(for: choice, catalog: catalog, query: "")
            if sections.isEmpty {
                Text("Fetch models with Test API")
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        Button {
                            onSelectModel(entry.id)
                        } label: {
                            HStack {
                                Text(entry.displayName)
                                if entry.id == selectedModelId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedEntry?.displayName ?? "Default model")
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                TahoeIcon("chevronDown", size: 9)
            }
            .foregroundStyle(t.fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 240, alignment: .trailing)
            .background(Color.white.opacity(0.055), in: Capsule())
            .overlay(Capsule().stroke(t.hairline, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .disabled(record.models.isEmpty)
        .accessibilityIdentifier("settings.provider.custom.\(record.id).model")
    }
}

// MARK: - Editor sheet

struct CustomProviderEditorSheet: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var store: CustomProviderStore
    var client: AgentControlClient?
    var editingRecord: CustomProviderRecord?
    var onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var kind: CustomProviderKind = .openAICompatible
    @State private var baseURL = ""
    @State private var useKeychain = true
    @State private var envVarName = ""
    @State private var apiKey = ""
    @State private var touchedAPIKey = false
    @State private var draftModels: [CustomProviderModel] = []
    @State private var defaultModelId: String?
    @State private var testState: CustomProviderEditorTestState = .notTested
    @State private var isSaving = false
    @State private var saveError: String?

    private var isEditing: Bool { editingRecord != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    labelField
                    kindPicker
                    baseURLField
                    keySection
                    testSection
                    defaultModelSection
                    if !testState.isSuccess, testState != .notTested {
                        Text("You can save without a successful test, but the provider may fail at spawn time.")
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg3)
                    }
                    if testState == .notTested, canSave {
                        Text("Saving without testing is allowed; run Test API to populate the model list.")
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg3)
                    }
                    if let saveError {
                        Text(saveError)
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(.red)
                    }
                    Text("Environment-variable keys are read from the daemon's launch environment. Changes require restarting the app.")
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg4)
                }
            }
            footer
        }
        .padding(22)
        .frame(width: 520)
        .frame(minHeight: 480)
        .background(t.surfaceSolid)
        .onAppear(perform: loadDraft)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isEditing ? "Edit custom provider" : "Add custom provider")
                .font(TahoeFont.body(18, weight: .bold))
                .foregroundStyle(t.fg)
            Text("OpenAI- and Anthropic-compatible neo-cloud endpoints")
                .font(TahoeFont.body(12.5))
                .foregroundStyle(t.fg3)
        }
    }

    private var labelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Label")
                .font(TahoeFont.body(12, weight: .semibold))
                .foregroundStyle(t.fg2)
            TextField("Defaults to \(placeholderHost)", text: $label)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API type")
                .font(TahoeFont.body(12, weight: .semibold))
                .foregroundStyle(t.fg2)
            Picker("API type", selection: $kind) {
                ForEach(CustomProviderKind.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var baseURLField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Base URL")
                .font(TahoeFont.body(12, weight: .semibold))
                .foregroundStyle(t.fg2)
            TextField("https://api.example.com", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if !baseURL.isEmpty, !baseURLParses {
                Text("Enter a valid https URL (no trailing /v1).")
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API key")
                .font(TahoeFont.body(12, weight: .semibold))
                .foregroundStyle(t.fg2)
            Picker("Storage", selection: $useKeychain) {
                Text("Save to Keychain").tag(true)
                Text("Use environment variable").tag(false)
            }
            .pickerStyle(.segmented)
            if useKeychain {
                SecureField(isEditing ? "•••••••• (unchanged)" : "API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { _, _ in touchedAPIKey = true }
            } else {
                TextField("Variable name", text: $envVarName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text(envVarCaption)
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(envVarFound ? .green : t.fg3)
            }
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await runTest() }
                } label: {
                    Text(testButtonTitle)
                        .font(TahoeFont.body(12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canTest || testState.isRunning)
                if testState.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
            testStatusLine
        }
    }

    @ViewBuilder
    private var testStatusLine: some View {
        switch testState {
        case .notTested:
            Text("Not tested")
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
        case .running:
            Text("Testing connection…")
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg2)
        case .passed(let count):
            Text("Test passed · \(count) model\(count == 1 ? "" : "s")")
                .font(TahoeFont.body(11.5, weight: .semibold))
                .foregroundStyle(.green)
        case .failed(let detail):
            Text("Test failed ✗ \(detail)")
                .font(TahoeFont.body(11.5, weight: .semibold))
                .foregroundStyle(.red)
                .help(detail)
        }
    }

    @ViewBuilder
    private var defaultModelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Default model")
                .font(TahoeFont.body(12, weight: .semibold))
                .foregroundStyle(t.fg2)
            Menu {
                if draftModels.isEmpty {
                    Text("Run Test API first")
                }
                ForEach(draftModels) { model in
                    Button {
                        defaultModelId = model.id
                    } label: {
                        HStack {
                            Text(model.displayName ?? model.id)
                            if model.id == defaultModelId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(defaultModelLabel)
                        .font(TahoeFont.body(12, weight: .semibold))
                    Spacer()
                    TahoeIcon("chevronDown", size: 9)
                }
                .foregroundStyle(t.fg)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.hairline, lineWidth: 0.5))
            }
            .disabled(draftModels.isEmpty)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button(isSaving ? "Saving…" : "Save") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave || isSaving)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var placeholderHost: String {
        CustomProviderRecord.hostLabel(from: normalizedBaseURLDraft()) ?? "host"
    }

    private var baseURLParses: Bool {
        (try? CustomProviderStore.normalizeBaseURL(baseURL)) != nil
    }

    private var envVarCaption: String {
        let name = envVarName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter the variable name the daemon should read." }
        return envVarFound ? "Found in environment ✓" : "Not set in this process — restart the app after exporting."
    }

    private var envVarFound: Bool {
        let name = envVarName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return ProcessInfo.processInfo.environment[name]?.isEmpty == false
    }

    private var canTest: Bool {
        baseURLParses && resolvedKeyForProbe() != nil
    }

    private var canSave: Bool {
        guard baseURLParses else { return false }
        if useKeychain {
            if isEditing, !touchedAPIKey { return true }
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !envVarName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var testButtonTitle: String {
        switch testState {
        case .running: return "Testing…"
        default: return "Test API"
        }
    }

    private var defaultModelLabel: String {
        guard let defaultModelId else { return "Select a model" }
        return draftModels.first(where: { $0.id == defaultModelId })?.displayName
            ?? defaultModelId
    }

    private func loadDraft() {
        guard let editingRecord else { return }
        label = editingRecord.label
        kind = editingRecord.kind
        baseURL = editingRecord.baseURL
        draftModels = editingRecord.models
        defaultModelId = editingRecord.defaultModelId ?? editingRecord.models.first?.id
        if case .environmentVariable(let name) = editingRecord.keySource {
            useKeychain = false
            envVarName = name
        } else {
            useKeychain = true
        }
        if editingRecord.lastTestResult?.success == true {
            testState = .passed(count: editingRecord.lastTestResult?.modelCount ?? draftModels.count)
        } else if editingRecord.lastTestResult?.success == false {
            testState = .failed(editingRecord.lastTestResult?.errorDetail ?? "Test failed")
        }
    }

    private func normalizedBaseURLDraft() -> String {
        (try? CustomProviderStore.normalizeBaseURL(baseURL)) ?? baseURL
    }

    private func resolvedKeySource() -> CustomProviderKeySource {
        if useKeychain {
            return .keychain
        }
        return .environmentVariable(name: envVarName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func resolvedKeyForProbe() -> String? {
        if useKeychain {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            if isEditing, let editingRecord {
                return try? store.resolveAPIKey(for: editingRecord)
            }
            return nil
        }
        let name = envVarName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return ProcessInfo.processInfo.environment[name]
    }

    private func runTest() async {
        guard let key = resolvedKeyForProbe() else {
            testState = .failed("API key unavailable")
            return
        }
        testState = .running
        let probe = CustomProviderAPIProbe()
        let result = await probe.fetchModels(
            kind: kind,
            baseURL: normalizedBaseURLDraft(),
            apiKey: key
        )
        if result.success {
            draftModels = result.models
            if defaultModelId == nil {
                defaultModelId = result.models.first?.id
            }
            testState = .passed(count: result.models.count)
        } else {
            testState = .failed(result.errorDetail ?? "Request failed")
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyToWrite: String? = {
            if useKeychain {
                if !trimmedKey.isEmpty { return trimmedKey }
                if isEditing, !touchedAPIKey { return nil }
                return nil
            }
            return nil
        }()
        let outcome: CustomProviderTestOutcome? = {
            switch testState {
            case .passed(let count):
                return CustomProviderTestOutcome(success: true, modelCount: count, testedAt: Date())
            case .failed(let detail):
                return CustomProviderTestOutcome(success: false, errorDetail: detail, testedAt: Date())
            default:
                return editingRecord?.lastTestResult
            }
        }()
        do {
            if let editingRecord {
                _ = try store.update(
                    id: editingRecord.id,
                    label: label,
                    kind: kind,
                    baseURL: baseURL,
                    keySource: resolvedKeySource(),
                    apiKey: keyToWrite,
                    isEnabled: editingRecord.isEnabled,
                    defaultModelId: defaultModelId,
                    models: draftModels.isEmpty ? nil : draftModels,
                    lastTestResult: outcome
                )
            } else {
                _ = try store.create(
                    label: label,
                    kind: kind,
                    baseURL: baseURL,
                    keySource: resolvedKeySource(),
                    apiKey: keyToWrite,
                    defaultModelId: defaultModelId,
                    models: draftModels,
                    lastTestResult: outcome
                )
            }
            await client?.refreshModelCatalog()
            dismiss()
            onDismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Support

private enum CustomProviderEditorTestState: Equatable {
    case notTested
    case running
    case passed(count: Int)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isSuccess: Bool {
        if case .passed = self { return true }
        return false
    }
}

enum CustomProviderSettingsSupport {
    @MainActor
    static func deviceAuthStatus(
        for record: CustomProviderRecord,
        store: CustomProviderStore
    ) -> (ProviderDeviceAuthStatus, String?) {
        let runtimeMissing: Bool = {
            switch record.kind {
            case .anthropicCompatible:
                return ShellRunner.locateBinary("claude") == nil
            case .openAICompatible:
                return ShellRunner.locateBinary("codex") == nil
            }
        }()
        if runtimeMissing {
            let detail = record.kind == .anthropicCompatible
                ? "Install the Claude CLI to spawn sessions"
                : "Install the Codex CLI to spawn sessions"
            return (.notInstalled, detail)
        }
        if (try? store.resolveAPIKey(for: record)) == nil {
            switch record.keySource {
            case .keychain:
                return (.unauthenticated, "API key not found in Keychain")
            case .environmentVariable(let name):
                let found = ProcessInfo.processInfo.environment[name]?.isEmpty == false
                return (.unauthenticated, found ? "Could not resolve API key" : "Environment variable \(name) is not set in this process")
            }
        }
        if record.lastTestResult?.success == true {
            return (.authenticated, nil)
        }
        if record.lastTestResult?.success == false {
            return (.unauthenticated, record.lastTestResult?.errorDetail)
        }
        return (.installed, "Not tested yet")
    }
}
