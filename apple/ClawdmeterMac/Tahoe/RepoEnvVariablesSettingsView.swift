import SwiftUI
import ClawdmeterShared
import AppKit

struct RepoEnvVariablesSettingsView: View {
    @Environment(\.tahoe) private var t

    let workspaceStore: WorkspaceStore?
    let envStore: RepoEnvStore?
    let resolver: RepoEnvRuntimeResolver?
    /// When set (e.g. from the repo settings sheet), prefer this workspace on load.
    var preferredWorkspaceId: UUID? = nil
    /// Hide the repo picker and keep the view scoped to one repository.
    var lockRepositorySelection: Bool = false

    @State private var workspaces: [CodeWorkspaceRecord] = []
    @State private var selectedWorkspaceId: UUID?
    @State private var sets: [RepoEnvSetRecord] = []
    @State private var variables: [RepoEnvVariableRecord] = []
    @State private var manualConflicts: [RepoEnvConflict] = []
    @State private var searchText = ""
    @State private var scopeTab: RepoEnvScopeTab = .project
    @State private var kindFilter: RepoEnvKindFilter = .all
    @State private var typeFilter: RepoEnvTypeFilter = .all
    @State private var statusFilter: RepoEnvStatusFilter = .all
    @State private var sortMode: RepoEnvSortMode = .updatedDesc
    @State private var setFilterId: UUID?
    @State private var selectedVariableIds: Set<UUID> = []
    @State private var editMode: RepoEnvEditMode?
    @State private var detailVariable: RepoEnvVariableRecord?
    @State private var isImportingVariables = false
    @State private var lastImportSummary: String?
    @State private var newSetName = ""
    @State private var isAddingVariable = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsPanel(
                title: "Repo Environment Sets",
                subtitle: "Choose a repo, create named sets, and decide which variables exist in each set.",
                accessibilityIdentifier: "settings.env.root"
            ) {
                if workspaceStore == nil || envStore == nil {
                    unavailable
                } else if workspaces.isEmpty {
                    Text("No repository workspaces have been recorded yet.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                } else {
                    repoSelector
                    TahoeHair().padding(.vertical, 8)
                    setSelector
                    TahoeHair().padding(.vertical, 8)
                    variableMatrix
                }
            }

            settingsPanel(
                title: ".env.local Manual Lines",
                subtitle: "Lines outside the Clawdmeter-managed block stay untouched. Conflicting keys must be adopted or removed before launch."
            ) {
                manualRows
            }

            if let errorText {
                Text(errorText)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(.red)
            }

            if let lastImportSummary {
                Text(lastImportSummary)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.fg2)
            }
        }
        .task { refresh(selectFirstIfNeeded: true) }
        .onChange(of: preferredWorkspaceId) { _, _ in refresh(selectFirstIfNeeded: true) }
        .onChange(of: selectedWorkspaceId) { _, _ in refresh(selectFirstIfNeeded: false) }
        .sheet(isPresented: $isAddingVariable) {
            RepoEnvAddVariableSheet(
                workspaces: workspaces,
                sets: sets,
                defaultWorkspaceId: selectedWorkspaceId,
                onCancel: { isAddingVariable = false },
                onImport: {
                    isAddingVariable = false
                    isImportingVariables = true
                },
                onSave: addVariable
            )
            .frame(minWidth: 680, minHeight: 650)
        }
        .sheet(item: $editMode) { mode in
            RepoEnvEditVariableSheet(
                mode: mode,
                workspaces: workspaces,
                sets: sets,
                defaultWorkspaceId: selectedWorkspaceId,
                assignedWorkspaceIds: assignedWorkspaceIds(for: mode.variable),
                selectedSetIds: enabledSetIds(for: mode.variable),
                onCancel: { editMode = nil },
                onReveal: { try envStore?.readVariableValue(variableId: mode.variable.id) ?? "" },
                onSave: { saveEdit($0, mode: mode) }
            )
            .frame(minWidth: 700, minHeight: 680)
        }
        .sheet(item: $detailVariable) { variable in
            RepoEnvVariableDetailSheet(
                variable: latestVariable(variable) ?? variable,
                workspaces: workspaces,
                envStore: envStore,
                selectedWorkspaceId: selectedWorkspaceId,
                onReveal: { try envStore?.readVariableValue(variableId: variable.id) ?? "" },
                onChanged: {
                    materializeSelectedRepo()
                    refresh(selectFirstIfNeeded: false)
                },
                onClose: { detailVariable = nil }
            )
            .frame(minWidth: 760, minHeight: 680)
        }
        .sheet(isPresented: $isImportingVariables) {
            RepoEnvImportSheet(
                workspaces: workspaces,
                sets: sets,
                defaultWorkspaceId: selectedWorkspaceId,
                repoRootProvider: { workspaceId in
                    workspaces.first { $0.id == workspaceId }?.repoRoot
                },
                previewProvider: { text, workspaceId in
                    envStore?.previewImport(text, workspaceId: workspaceId) ?? []
                },
                onCancel: { isImportingVariables = false },
                onImport: importVariables
            )
            .frame(minWidth: 760, minHeight: 700)
        }
    }

    private var selectedWorkspace: CodeWorkspaceRecord? {
        guard let selectedWorkspaceId else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceId }
    }

    private var activeSet: RepoEnvSetRecord? {
        sets.first { $0.isActive } ?? sets.first
    }

    private var filteredVariables: [RepoEnvVariableRecord] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = variables

        if scopeTab == .shared {
            result = result.filter { $0.scope == .shared }
        }

        switch kindFilter {
        case .all:
            break
        case .repo:
            result = result.filter { $0.scope == .local }
        case .shared:
            result = result.filter { $0.scope == .shared }
        }

        switch typeFilter {
        case .all:
            break
        case .sensitive:
            result = result.filter { $0.kind == .sensitive }
        case .plain:
            result = result.filter { $0.kind == .plain }
        case .system:
            result = result.filter { $0.kind == .system }
        }

        switch statusFilter {
        case .all:
            break
        case .inActiveSet:
            if let activeSet {
                result = result.filter { assignmentEnabled(variableId: $0.id, setId: activeSet.id) }
            }
        case .conflicts:
            result = result.filter { hasManualConflict($0) }
        case .disabled:
            result = result.filter { !$0.isEnabled }
        case .notInActiveSet:
            if let activeSet {
                result = result.filter { !assignmentEnabled(variableId: $0.id, setId: activeSet.id) }
            }
        }

        if let setFilterId {
            result = result.filter { assignmentEnabled(variableId: $0.id, setId: setFilterId) }
        }

        if !trimmedSearch.isEmpty {
            result = result.filter { variable in
                variable.key.localizedCaseInsensitiveContains(trimmedSearch)
                    || enabledSetNames(for: variable).joined(separator: " ").localizedCaseInsensitiveContains(trimmedSearch)
                    || variable.scope.displayName.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }

        switch sortMode {
        case .updatedDesc:
            result.sort { $0.updatedAt > $1.updatedAt }
        case .keyAsc:
            result.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        case .keyDesc:
            result.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedDescending }
        case .status:
            result.sort { variableStatus($0).rank < variableStatus($1).rank }
        case .setCount:
            result.sort { enabledSetNames(for: $0).count > enabledSetNames(for: $1).count }
        }

        return result
    }

    private var unavailable: some View {
        Text("Runtime settings are not available in previews.")
            .font(TahoeFont.body(12))
            .foregroundStyle(t.fg3)
    }

    private var repoSelector: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Repository")
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg)
                if let workspace = selectedWorkspace {
                    Text(workspace.repoRoot)
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !lockRepositorySelection {
                Spacer(minLength: 0)
                Picker("Repository", selection: $selectedWorkspaceId) {
                    ForEach(workspaces) { workspace in
                        Text(workspace.repoDisplayName).tag(Optional(workspace.id))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    private var setSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Sets")
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg)
                Spacer(minLength: 0)
                TextField("local, staging, prod", text: $newSetName)
                    .font(TahoeFont.body(12))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .accessibilityIdentifier("settings.env.new-set-name")
                    .onSubmit(createSet)
                Button(action: ContinuumAnalytics.wrapButton("repo_env_create_set", createSet)) {
                    TahoeIcon("plus", size: 12, weight: .bold)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings.env.create-set")
                .disabled(newSetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Create env set")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(sets) { set in
                    Button(action: ContinuumAnalytics.wrapButton("repo_env_select_set", {
                        guard let workspace = selectedWorkspace, let envStore else { return }
                        envStore.setActiveSet(workspaceId: workspace.id, setId: set.id)
                        materializeSelectedRepo()
                        refresh(selectFirstIfNeeded: false)
                    })) {
                        HStack(spacing: 6) {
                            if set.isActive {
                                TahoeIcon("check", size: 9, weight: .bold)
                            }
                            Text(set.name)
                        }
                        .font(TahoeFont.body(11.5, weight: set.isActive ? .bold : .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(set.isActive ? t.accent : t.fg2)
                    .background {
                        Capsule()
                            .fill(set.isActive ? t.accentAlpha(0.14) : t.accentAlpha(0.04))
                    }
                    .overlay {
                        Capsule()
                            .stroke(set.isActive ? t.accentAlpha(0.5) : t.hairline, lineWidth: 1)
                    }
                }
            }
        }
    }

    private var variableMatrix: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Variables")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text("Search, filter, and choose which sets receive each variable. Values stay masked and live in Keychain.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                }
                Spacer(minLength: 0)
                Button(action: ContinuumAnalytics.wrapButton("repo_env_import_variables", { isImportingVariables = true })) {
                    HStack(spacing: 6) {
                        TahoeIcon("tray", size: 11, weight: .semibold)
                        Text("Import .env")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.env.import")
                Button(action: ContinuumAnalytics.wrapButton("repo_env_add_variable", { isAddingVariable = true })) {
                    HStack(spacing: 6) {
                        TahoeIcon("plus", size: 11, weight: .bold)
                        Text("Add Variable")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.env.add-variable")
            }

            Picker("Variable scope", selection: $scopeTab) {
                ForEach(RepoEnvScopeTab.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .accessibilityIdentifier("settings.env.scope-tabs")

            variableFilterBar
            bulkActionBar
            variableTable
        }
    }

    private var variableFilterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                TahoeIcon("search", size: 11)
                    .foregroundStyle(t.fg4)
                TextField("Search variables", text: $searchText)
                    .font(TahoeFont.body(12))
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("settings.env.search")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        TahoeIcon("x", size: 9, weight: .bold)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(t.fg4)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(t.accentAlpha(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(t.hairline, lineWidth: 1)
            }

            Picker("Sets", selection: $setFilterId) {
                Text("All Sets").tag(Optional<UUID>.none)
                ForEach(sets) { set in
                    Text(set.name).tag(Optional(set.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 132)
            .accessibilityIdentifier("settings.env.set-filter")

            Picker("Source", selection: $kindFilter) {
                ForEach(RepoEnvKindFilter.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 142)
            .accessibilityIdentifier("settings.env.source-filter")

            Picker("Type", selection: $typeFilter) {
                ForEach(RepoEnvTypeFilter.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 128)
            .accessibilityIdentifier("settings.env.type-filter")

            Picker("Status", selection: $statusFilter) {
                ForEach(RepoEnvStatusFilter.allCases) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 142)
            .accessibilityIdentifier("settings.env.status-filter")

            Picker("Sort", selection: $sortMode) {
                ForEach(RepoEnvSortMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 138)
            .accessibilityIdentifier("settings.env.sort")
        }
    }

    private var bulkActionBar: some View {
        Group {
            if !selectedVariableIds.isEmpty {
                HStack(spacing: 10) {
                    Text("\(selectedVariableIds.count) selected")
                        .font(TahoeFont.body(12, weight: .bold))
                        .foregroundStyle(t.fg2)
                    Spacer(minLength: 0)
                    if let activeSet {
                        Button("Enable in \(activeSet.name)", action: ContinuumAnalytics.wrapButton("repo_env_bulk_enable_in_set", {
                            setSelectedVariables(enabled: true, in: activeSet)
                        }))
                        .buttonStyle(.bordered)
                        Button("Disable in \(activeSet.name)", action: ContinuumAnalytics.wrapButton("repo_env_bulk_disable_in_set", {
                            setSelectedVariables(enabled: false, in: activeSet)
                        }))
                        .buttonStyle(.bordered)
                    }
                    Button("Enable All Sets", action: ContinuumAnalytics.wrapButton("repo_env_bulk_enable_all_sets", {
                        setSelectedVariables(enabledInAllSets: true)
                    }))
                    .buttonStyle(.bordered)
                    Button("Delete", role: .destructive, action: ContinuumAnalytics.wrapButton("repo_env_bulk_delete", deleteSelectedVariables))
                    .buttonStyle(.bordered)
                    Button("Clear", action: ContinuumAnalytics.wrapButton("repo_env_bulk_clear_selection", {
                        selectedVariableIds.removeAll()
                    }))
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(t.accentAlpha(0.07))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(t.accentAlpha(0.35), lineWidth: 1)
                }
                .accessibilityIdentifier("settings.env.bulk-actions")
            }
        }
    }

    private var variableTable: some View {
        VStack(spacing: 0) {
            variableTableHeader
            if filteredVariables.isEmpty {
                VStack(spacing: 8) {
                    TahoeIcon("code", size: 20)
                        .foregroundStyle(t.fg4)
                    Text(variables.isEmpty ? "No variables are assigned to this repo yet." : "No variables match these filters.")
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.fg2)
                    Text("Add a variable or loosen the filters above.")
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            } else {
                ForEach(Array(filteredVariables.enumerated()), id: \.element.id) { index, variable in
                    variableRow(variable)
                    if index != filteredVariables.count - 1 {
                        TahoeHair()
                    }
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
        .accessibilityIdentifier("settings.env.variable-table")
    }

    private var variableTableHeader: some View {
        HStack(spacing: 8) {
            Button {
                toggleSelectAllFiltered()
            } label: {
                Image(systemName: filteredVariables.allSatisfy { selectedVariableIds.contains($0.id) } && !filteredVariables.isEmpty ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t.fg3)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            tableHeaderText("Key", width: nil)
            tableHeaderText("Sets", width: 156)
            tableHeaderText("Repos", width: 76)
            tableHeaderText("Type", width: 76)
            tableHeaderText("Value", width: 88)
            tableHeaderText("Status", width: 88)
            tableHeaderText("Updated", width: 78)
            tableHeaderText("", width: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(t.accentAlpha(0.035))
    }

    private func variableRow(_ variable: RepoEnvVariableRecord) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                toggleSelection(variable.id)
            } label: {
                Image(systemName: selectedVariableIds.contains(variable.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selectedVariableIds.contains(variable.id) ? t.accent : t.fg4)
            }
            .buttonStyle(.plain)
            .frame(width: 20)

            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(variable.scope == .shared ? t.accentAlpha(0.12) : t.accentAlpha(0.055))
                    TahoeIcon(variable.scope == .shared ? "globe" : "code", size: 12, weight: .semibold)
                        .foregroundStyle(variable.scope == .shared ? t.accent : t.fg3)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(variable.key)
                        .font(TahoeFont.mono(12, weight: .bold))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Text(variable.scope.displayName)
                            .font(TahoeFont.body(10.5, weight: .semibold))
                            .foregroundStyle(variable.scope == .shared ? t.accent : t.fg3)
                        if variable.note?.isEmpty == false {
                            TahoeIcon("doc", size: 9)
                                .foregroundStyle(t.fg4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            setChipStrip(for: variable)
                .frame(width: 156, alignment: .leading)

            Text(repoSummary(for: variable))
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.fg3)
                .frame(width: 76, alignment: .leading)

            kindBadge(variable.kind)
                .frame(width: 76, alignment: .leading)

            HStack(spacing: 6) {
                TahoeIcon("eye", size: 11)
                    .foregroundStyle(t.fg4)
                Text("••••••••")
                    .font(TahoeFont.mono(11, weight: .semibold))
                    .foregroundStyle(t.fg3)
            }
            .frame(width: 88, alignment: .leading)
            .help("Values are read from Keychain only for launch and materialization.")

            statusBadge(for: variable)
                .frame(width: 88, alignment: .leading)

            Text(relativeUpdatedText(variable.updatedAt))
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg3)
                .frame(width: 78, alignment: .leading)

            Menu {
                Button("Details", action: ContinuumAnalytics.wrapButton("repo_env_variable_details", {
                    detailVariable = variable
                }))
                Button("Edit", action: ContinuumAnalytics.wrapButton("repo_env_variable_edit", {
                    editMode = .edit(variable)
                }))
                Button("Rotate Value", action: ContinuumAnalytics.wrapButton("repo_env_variable_rotate", {
                    editMode = .rotate(variable)
                }))
                Button("Duplicate", action: ContinuumAnalytics.wrapButton("repo_env_variable_duplicate", {
                    duplicateVariable(variable)
                }))
                Button("Copy Key", action: ContinuumAnalytics.wrapButton("repo_env_variable_copy_key", {
                    copyToPasteboard(variable.key)
                }))
                Divider()
                Button("Enable in all sets", action: ContinuumAnalytics.wrapButton("repo_env_variable_enable_all_sets", {
                    setVariable(variable.id, enabledInAllSets: true)
                }))
                Button("Disable in all sets", action: ContinuumAnalytics.wrapButton("repo_env_variable_disable_all_sets", {
                    setVariable(variable.id, enabledInAllSets: false)
                }))
                if let activeSet {
                    Button("Disable in \(activeSet.name)", action: ContinuumAnalytics.wrapButton("repo_env_variable_disable_in_set", {
                        setAssignment(variableId: variable.id, setId: activeSet.id, enabled: false)
                    }))
                }
                Divider()
                Button("Delete", role: .destructive, action: ContinuumAnalytics.wrapButton("repo_env_variable_delete", {
                    deleteVariable(variable.id)
                }))
            } label: {
                TahoeIcon("ellipsis", size: 13, weight: .semibold)
                    .foregroundStyle(t.fg3)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .frame(width: 28)
            .accessibilityIdentifier("settings.env.variable.actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture {
            detailVariable = variable
        }
        .accessibilityIdentifier("settings.env.variable.row")
    }

    private func setChipStrip(for variable: RepoEnvVariableRecord) -> some View {
        HStack(spacing: 6) {
            ForEach(sets.prefix(3)) { set in
                let enabled = assignmentEnabled(variableId: variable.id, setId: set.id)
                Button(action: ContinuumAnalytics.wrapButton("repo_env_toggle_set_assignment", {
                    setAssignment(variableId: variable.id, setId: set.id, enabled: !enabled)
                })) {
                    HStack(spacing: 4) {
                        if enabled {
                            TahoeIcon("check", size: 7, weight: .bold)
                        }
                        Text(set.name)
                            .lineLimit(1)
                    }
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(enabled ? t.accent : t.fg3)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .frame(maxWidth: 72)
                }
                .buttonStyle(.plain)
                .background {
                    Capsule()
                        .fill(enabled ? t.accentAlpha(0.12) : t.accentAlpha(0.035))
                }
                .overlay {
                    Capsule()
                        .stroke(enabled ? t.accentAlpha(0.45) : t.hairline, lineWidth: 1)
                }
                .help(enabled ? "Enabled in \(set.name)" : "Disabled in \(set.name)")
            }

            if sets.count > 3 {
                Menu {
                    ForEach(sets.dropFirst(3)) { set in
                        let enabled = assignmentEnabled(variableId: variable.id, setId: set.id)
                        Button("\(enabled ? "Disable" : "Enable") \(set.name)", action: ContinuumAnalytics.wrapButton("repo_env_overflow_toggle_set", {
                            setAssignment(variableId: variable.id, setId: set.id, enabled: !enabled)
                        }))
                    }
                } label: {
                    Text("+\(sets.count - 3)")
                        .font(TahoeFont.body(10.5, weight: .bold))
                        .foregroundStyle(t.fg3)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background {
                            Capsule().fill(t.accentAlpha(0.035))
                        }
                        .overlay {
                            Capsule().stroke(t.hairline, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tableHeaderText(_ title: String, width: CGFloat?) -> some View {
        Text(title)
            .font(TahoeFont.body(10.5, weight: .bold))
            .foregroundStyle(t.fg3)
            .textCase(.uppercase)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func kindBadge(_ kind: RepoEnvVariableKind) -> some View {
        Text(kind.displayName)
            .font(TahoeFont.body(10.5, weight: .bold))
            .foregroundStyle(kind == .sensitive ? t.accent : t.fg3)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(kind == .sensitive ? t.accentAlpha(0.1) : t.accentAlpha(0.035))
            }
            .overlay {
                Capsule().stroke(kind == .sensitive ? t.accentAlpha(0.35) : t.hairline, lineWidth: 1)
            }
    }

    private func statusBadge(for variable: RepoEnvVariableRecord) -> some View {
        let status = variableStatus(variable)
        return Text(status.label)
            .font(TahoeFont.body(10.5, weight: .bold))
            .foregroundStyle(status.color(t))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(status.color(t).opacity(0.1))
            }
            .overlay {
                Capsule().stroke(status.color(t).opacity(0.28), lineWidth: 1)
            }
    }

    private func variableStatus(_ variable: RepoEnvVariableRecord) -> RepoEnvVariableStatus {
        if hasManualConflict(variable) { return .conflict }
        if !variable.isEnabled { return .disabled }
        if let activeSet, !assignmentEnabled(variableId: variable.id, setId: activeSet.id) { return .notInActiveSet }
        return .active
    }

    private func hasManualConflict(_ variable: RepoEnvVariableRecord) -> Bool {
        manualConflicts.contains { $0.key == variable.key }
    }

    private func repoSummary(for variable: RepoEnvVariableRecord) -> String {
        let count = envStore?.assignedWorkspaceIds(variableId: variable.id).count ?? 0
        guard count > 1 else { return selectedWorkspace?.repoDisplayName ?? "Repo" }
        return "\(count) repos"
    }

    private var manualRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selectedWorkspace == nil {
                Text("Select a repository to inspect .env.local.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            } else if manualConflicts.isEmpty {
                Text("No manual .env.local variables outside the managed block.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            } else {
                ForEach(manualConflicts, id: \.self) { conflict in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conflict.key)
                                .font(TahoeFont.mono(12, weight: .bold))
                                .foregroundStyle(t.fg)
                            Text("line \(conflict.line)")
                                .font(TahoeFont.body(11))
                                .foregroundStyle(t.fg3)
                        }
                        Spacer(minLength: 0)
                        Button("Adopt", action: ContinuumAnalytics.wrapButton("repo_env_conflict_adopt", { adoptManual(conflict) }))
                            .buttonStyle(.bordered)
                        Button("Import", action: ContinuumAnalytics.wrapButton("repo_env_conflict_import", { importManual(conflict, shouldRemoveManualLine: false) }))
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func settingsPanel<Content: View>(
        title: String,
        subtitle: String,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    if let accessibilityIdentifier {
                        Text(title.uppercased())
                            .font(TahoeFont.body(11, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(t.fg3)
                            .accessibilityIdentifier(accessibilityIdentifier)
                    } else {
                        Text(title.uppercased())
                            .font(TahoeFont.body(11, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(t.fg3)
                    }
                    Text(subtitle)
                        .font(TahoeFont.body(12.5))
                        .foregroundStyle(t.fg3)
                }
                .padding(.bottom, 18)
                content()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func refresh(selectFirstIfNeeded: Bool) {
        workspaces = workspaceStore?.all()
            .sorted { $0.repoDisplayName.localizedCaseInsensitiveCompare($1.repoDisplayName) == .orderedAscending } ?? []
        if let preferredWorkspaceId,
           workspaces.contains(where: { $0.id == preferredWorkspaceId }) {
            selectedWorkspaceId = preferredWorkspaceId
        } else if selectFirstIfNeeded || selectedWorkspaceId == nil || !workspaces.contains(where: { $0.id == selectedWorkspaceId }) {
            selectedWorkspaceId = workspaces.first?.id
        }
        guard let workspace = selectedWorkspace, let envStore else {
            sets = []
            variables = []
            manualConflicts = []
            return
        }
        _ = envStore.ensureDefaultSet(workspaceId: workspace.id)
        sets = envStore.sets(for: workspace.id)
        if let setFilterId, !sets.contains(where: { $0.id == setFilterId }) {
            self.setFilterId = nil
        }
        variables = envStore.variables(for: workspace.id)
        selectedVariableIds = selectedVariableIds.intersection(Set(variables.map(\.id)))
        if let detailVariable, let latest = variables.first(where: { $0.id == detailVariable.id }) {
            self.detailVariable = latest
        }
        refreshManualConflicts()
    }

    private func refreshManualConflicts() {
        guard let workspace = selectedWorkspace else {
            manualConflicts = []
            return
        }
        let fileURL = URL(fileURLWithPath: workspace.repoRoot, isDirectory: true)
            .appendingPathComponent(".env.local")
        manualConflicts = RepoEnvFileMaterializer().inspectManualKeys(fileURL: fileURL)
    }

    private func createSet() {
        guard let workspace = selectedWorkspace, let envStore else { return }
        let trimmed = newSetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let created = envStore.createSet(workspaceId: workspace.id, name: trimmed, makeActive: false)
            for variable in envStore.variables(for: workspace.id) {
                try envStore.setAssignment(
                    variableId: variable.id,
                    workspaceId: workspace.id,
                    setId: created.id,
                    enabled: variable.scope == .shared
                )
            }
            newSetName = ""
            refresh(selectFirstIfNeeded: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func addVariable(key: String, value: String, workspaceIds: Set<UUID>, selectedSetIds: Set<UUID>) {
        guard let envStore else { return }
        do {
            let ids = Array(workspaceIds)
            let created = try envStore.createVariable(
                key: key,
                value: value,
                workspaceIds: ids,
                scope: ids.count > 1 ? .shared : .local
            )
            if let workspace = selectedWorkspace, workspaceIds.contains(workspace.id), !sets.isEmpty {
                let enabledSetIds = selectedSetIds.isEmpty ? Set(sets.map(\.id)) : selectedSetIds
                for set in sets {
                    try envStore.setAssignment(
                        variableId: created.id,
                        workspaceId: workspace.id,
                        setId: set.id,
                        enabled: enabledSetIds.contains(set.id)
                    )
                }
            }
            guard materializeSelectedRepo() else {
                refresh(selectFirstIfNeeded: false)
                return
            }
            isAddingVariable = false
            refresh(selectFirstIfNeeded: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    @discardableResult
    private func addVariable(_ draft: RepoEnvVariableDraft) -> Bool {
        guard let envStore else { return false }
        do {
            let ids = Array(draft.workspaceIds)
            let created = try envStore.createVariable(
                key: draft.key,
                value: draft.value,
                workspaceIds: ids,
                scope: ids.count > 1 ? .shared : .local,
                kind: draft.kind,
                note: draft.note,
                actor: NSUserName()
            )
            if let workspace = selectedWorkspace, draft.workspaceIds.contains(workspace.id), !sets.isEmpty {
                let enabledSetIds = draft.setIds.isEmpty ? Set(sets.map(\.id)) : draft.setIds
                for set in sets {
                    try envStore.setAssignment(
                        variableId: created.id,
                        workspaceId: workspace.id,
                        setId: set.id,
                        enabled: enabledSetIds.contains(set.id)
                    )
                }
            }
            guard materializeSelectedRepo() else {
                refresh(selectFirstIfNeeded: false)
                return false
            }
            refresh(selectFirstIfNeeded: false)
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func assignmentEnabled(variableId: UUID, setId: UUID) -> Bool {
        guard let workspace = selectedWorkspace else { return false }
        return envStore?.assignment(variableId: variableId, workspaceId: workspace.id, setId: setId)?.isEnabled == true
    }

    private func setAssignment(variableId: UUID, setId: UUID, enabled: Bool) {
        guard let workspace = selectedWorkspace, let envStore else { return }
        do {
            try envStore.setAssignment(variableId: variableId, workspaceId: workspace.id, setId: setId, enabled: enabled)
            _ = materializeSelectedRepo()
            refresh(selectFirstIfNeeded: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func setVariable(_ variableId: UUID, enabledInAllSets enabled: Bool) {
        guard let workspace = selectedWorkspace, let envStore else { return }
        do {
            for set in sets {
                try envStore.setAssignment(variableId: variableId, workspaceId: workspace.id, setId: set.id, enabled: enabled)
            }
            _ = materializeSelectedRepo()
            refresh(selectFirstIfNeeded: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func deleteVariable(_ variableId: UUID) {
        do {
            try envStore?.deleteVariable(variableId)
            selectedVariableIds.remove(variableId)
            _ = materializeSelectedRepo()
            refresh(selectFirstIfNeeded: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func deleteSelectedVariables() {
        do {
            for id in selectedVariableIds {
                try envStore?.deleteVariable(id)
            }
            selectedVariableIds.removeAll()
            _ = materializeSelectedRepo()
            refresh(selectFirstIfNeeded: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func setSelectedVariables(enabled: Bool, in set: RepoEnvSetRecord) {
        guard let workspace = selectedWorkspace, let envStore else { return }
        do {
            for id in selectedVariableIds {
                try envStore.setAssignment(variableId: id, workspaceId: workspace.id, setId: set.id, enabled: enabled)
            }
            _ = materializeSelectedRepo()
            refresh(selectFirstIfNeeded: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func setSelectedVariables(enabledInAllSets enabled: Bool) {
        guard let workspace = selectedWorkspace, let envStore else { return }
        do {
            for id in selectedVariableIds {
                for set in sets {
                    try envStore.setAssignment(variableId: id, workspaceId: workspace.id, setId: set.id, enabled: enabled)
                }
            }
            _ = materializeSelectedRepo()
            refresh(selectFirstIfNeeded: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedVariableIds.contains(id) {
            selectedVariableIds.remove(id)
        } else {
            selectedVariableIds.insert(id)
        }
    }

    private func toggleSelectAllFiltered() {
        let ids = Set(filteredVariables.map(\.id))
        if !ids.isEmpty, ids.isSubset(of: selectedVariableIds) {
            selectedVariableIds.subtract(ids)
        } else {
            selectedVariableIds.formUnion(ids)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func duplicateVariable(_ variable: RepoEnvVariableRecord) {
        do {
            let value = try envStore?.readVariableValue(variableId: variable.id) ?? ""
            editMode = .duplicate(variable, value: value)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveEdit(_ draft: RepoEnvVariableDraft, mode: RepoEnvEditMode) -> Bool {
        guard let envStore else { return false }
        do {
            switch mode {
            case .edit(let variable):
                try envStore.updateVariableMetadata(
                    variableId: variable.id,
                    key: draft.key,
                    note: draft.note,
                    kind: draft.kind,
                    isEnabled: draft.isEnabled,
                    actor: NSUserName()
                )
                if !draft.value.isEmpty {
                    try envStore.updateVariableValue(variableId: variable.id, value: draft.value, actor: NSUserName())
                }
                try applyWorkspaceDraft(draft, variableId: variable.id)
            case .rotate(let variable):
                guard !draft.value.isEmpty else { return false }
                try envStore.updateVariableValue(
                    variableId: variable.id,
                    value: draft.value,
                    markRotated: true,
                    actor: NSUserName()
                )
            case .duplicate:
                guard addVariable(draft) else { return false }
                editMode = nil
                return true
            }
            editMode = nil
            guard materializeSelectedRepo() else {
                refresh(selectFirstIfNeeded: false)
                return false
            }
            refresh(selectFirstIfNeeded: false)
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func applyWorkspaceDraft(_ draft: RepoEnvVariableDraft, variableId: UUID) throws {
        guard let envStore else { return }
        let currentWorkspaceId = selectedWorkspace?.id
        let currentlyAssigned = envStore.assignedWorkspaceIds(variableId: variableId)
        for workspace in workspaces {
            if draft.workspaceIds.contains(workspace.id) {
                let workspaceSets = envStore.sets(for: workspace.id)
                let targetSets = workspaceSets.isEmpty
                    ? [envStore.ensureDefaultSet(workspaceId: workspace.id)]
                    : workspaceSets
                let enabledSetIds = workspace.id == currentWorkspaceId && !draft.setIds.isEmpty
                    ? draft.setIds
                    : Set(targetSets.map(\.id))
                for set in targetSets {
                    try envStore.setAssignment(
                        variableId: variableId,
                        workspaceId: workspace.id,
                        setId: set.id,
                        enabled: enabledSetIds.contains(set.id)
                    )
                }
            } else if currentlyAssigned.contains(workspace.id) {
                try envStore.removeAssignments(
                    variableId: variableId,
                    workspaceId: workspace.id,
                    actor: NSUserName()
                )
            }
        }
    }

    private func importVariables(_ draft: RepoEnvImportDraft) -> Bool {
        guard let envStore else { return false }
        let targetIds = Array(draft.workspaceIds)
        guard !targetIds.isEmpty else { return false }
        // Set selection (draft.setIds) applies to the "current" workspace, and we
        // materialize what we imported into — both come from the sheet's targets, not the
        // settings page's selected repo. The sheet can target a different repo (and the
        // vendor flow always does single-workspace), so keying off selectedWorkspace would
        // write the .env to the wrong repo.
        let currentWorkspaceId = selectedWorkspaceId
            .flatMap { draft.workspaceIds.contains($0) ? $0 : nil } ?? targetIds[0]
        do {
            let batch = try envStore.importVariables(
                previews: draft.previews,
                workspaceIds: targetIds,
                selectedSetIds: draft.setIds,
                currentWorkspaceId: currentWorkspaceId,
                conflictStrategy: draft.conflictStrategy,
                kind: draft.kind,
                actor: NSUserName()
            )
            // Import has persisted. Materialize each target repo's .env; a materialize
            // failure surfaces via errorText but is NOT reported as an import failure —
            // the records are already saved, so retrying would duplicate/overwrite them.
            materializeRepos(targetIds)
            lastImportSummary = "Imported \(batch.importedCount), overwrote \(batch.overwrittenCount), skipped \(batch.skippedCount)."
            isImportingVariables = false
            refresh(selectFirstIfNeeded: false)
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func assignedWorkspaceIds(for variable: RepoEnvVariableRecord) -> Set<UUID> {
        envStore?.assignedWorkspaceIds(variableId: variable.id) ?? []
    }

    private func enabledSetIds(for variable: RepoEnvVariableRecord) -> Set<UUID> {
        Set(sets.filter { assignmentEnabled(variableId: variable.id, setId: $0.id) }.map(\.id))
    }

    private func latestVariable(_ variable: RepoEnvVariableRecord) -> RepoEnvVariableRecord? {
        variables.first { $0.id == variable.id }
    }

    private func enabledSetNames(for variable: RepoEnvVariableRecord) -> [String] {
        sets
            .filter { assignmentEnabled(variableId: variable.id, setId: $0.id) }
            .map(\.name)
    }

    private func relativeUpdatedText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @discardableResult
    private func materializeSelectedRepo() -> Bool {
        guard let repoRoot = selectedWorkspace?.repoRoot else { return true }
        do {
            _ = try resolver?.materializeActiveSet(repoRoot: repoRoot)
            errorText = nil
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    /// Materialize the active set into each given workspace's .env. Used by import, which
    /// can target repos other than the currently-selected one. Sets errorText to the first
    /// failure (or clears it when every target succeeds).
    private func materializeRepos(_ workspaceIds: [UUID]) {
        var firstError: String?
        for id in workspaceIds {
            guard let repoRoot = workspaces.first(where: { $0.id == id })?.repoRoot else { continue }
            do {
                _ = try resolver?.materializeActiveSet(repoRoot: repoRoot)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        errorText = firstError
    }

    private func adoptManual(_ conflict: RepoEnvConflict) {
        importManual(conflict, shouldRemoveManualLine: true)
    }

    private func importManual(_ conflict: RepoEnvConflict, shouldRemoveManualLine: Bool) {
        guard let workspace = selectedWorkspace,
              let value = manualValue(for: conflict.key, repoRoot: workspace.repoRoot),
              let envStore
        else { return }
        do {
            _ = try envStore.createVariable(
                key: conflict.key,
                value: value,
                workspaceIds: [workspace.id],
                scope: .local
            )
            if shouldRemoveManualLine {
                try removeManualLine(for: conflict.key, repoRoot: workspace.repoRoot)
            }
            materializeSelectedRepo()
            refresh(selectFirstIfNeeded: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func manualValue(for key: String, repoRoot: String) -> String? {
        let url = URL(fileURLWithPath: repoRoot, isDirectory: true).appendingPathComponent(".env.local")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var inManagedBlock = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.contains(RepoEnvFileMaterializer.beginMarker) {
                inManagedBlock = true
                continue
            }
            if rawLine.contains(RepoEnvFileMaterializer.endMarker) {
                inManagedBlock = false
                continue
            }
            guard !inManagedBlock,
                  RepoEnvFileMaterializer.key(inEnvLine: rawLine) == key,
                  let eq = rawLine.firstIndex(of: "=")
            else { continue }
            let rawValue = String(rawLine[rawLine.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.count >= 2 {
                return String(rawValue.dropFirst().dropLast())
            }
            return rawValue
        }
        return nil
    }

    private func removeManualLine(for key: String, repoRoot: String) throws {
        let url = URL(fileURLWithPath: repoRoot, isDirectory: true).appendingPathComponent(".env.local")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var inManagedBlock = false
        var kept: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.contains(RepoEnvFileMaterializer.beginMarker) {
                inManagedBlock = true
                kept.append(rawLine)
                continue
            }
            if rawLine.contains(RepoEnvFileMaterializer.endMarker) {
                inManagedBlock = false
                kept.append(rawLine)
                continue
            }
            if !inManagedBlock, RepoEnvFileMaterializer.key(inEnvLine: rawLine) == key {
                continue
            }
            kept.append(rawLine)
        }
        try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
