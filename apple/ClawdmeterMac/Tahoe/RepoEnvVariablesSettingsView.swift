import SwiftUI
import ClawdmeterShared
import AppKit
import UniformTypeIdentifiers

struct RepoEnvVariablesSettingsView: View {
    @Environment(\.tahoe) private var t

    let workspaceStore: WorkspaceStore?
    let envStore: RepoEnvStore?
    let resolver: RepoEnvRuntimeResolver?

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
                Button(action: createSet) {
                    TahoeIcon("plus", size: 12, weight: .bold)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings.env.create-set")
                .disabled(newSetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Create env set")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(sets) { set in
                    Button {
                        guard let workspace = selectedWorkspace, let envStore else { return }
                        envStore.setActiveSet(workspaceId: workspace.id, setId: set.id)
                        materializeSelectedRepo()
                        refresh(selectFirstIfNeeded: false)
                    } label: {
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
                Button(action: { isImportingVariables = true }) {
                    HStack(spacing: 6) {
                        TahoeIcon("tray", size: 11, weight: .semibold)
                        Text("Import .env")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.env.import")
                Button(action: { isAddingVariable = true }) {
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
                        Button("Enable in \(activeSet.name)") {
                            setSelectedVariables(enabled: true, in: activeSet)
                        }
                        .buttonStyle(.bordered)
                        Button("Disable in \(activeSet.name)") {
                            setSelectedVariables(enabled: false, in: activeSet)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Enable All Sets") {
                        setSelectedVariables(enabledInAllSets: true)
                    }
                    .buttonStyle(.bordered)
                    Button("Delete", role: .destructive) {
                        deleteSelectedVariables()
                    }
                    .buttonStyle(.bordered)
                    Button("Clear") {
                        selectedVariableIds.removeAll()
                    }
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(t.accentAlpha(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                Button("Details") {
                    detailVariable = variable
                }
                Button("Edit") {
                    editMode = .edit(variable)
                }
                Button("Rotate Value") {
                    editMode = .rotate(variable)
                }
                Button("Duplicate") {
                    duplicateVariable(variable)
                }
                Button("Copy Key") {
                    copyToPasteboard(variable.key)
                }
                Divider()
                Button("Enable in all sets") {
                    setVariable(variable.id, enabledInAllSets: true)
                }
                Button("Disable in all sets") {
                    setVariable(variable.id, enabledInAllSets: false)
                }
                if let activeSet {
                    Button("Disable in \(activeSet.name)") {
                        setAssignment(variableId: variable.id, setId: activeSet.id, enabled: false)
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    deleteVariable(variable.id)
                }
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
                Button {
                    setAssignment(variableId: variable.id, setId: set.id, enabled: !enabled)
                } label: {
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
                        Button("\(enabled ? "Disable" : "Enable") \(set.name)") {
                            setAssignment(variableId: variable.id, setId: set.id, enabled: !enabled)
                        }
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
                        Button("Adopt") { adoptManual(conflict) }
                            .buttonStyle(.bordered)
                        Button("Import") { importManual(conflict, shouldRemoveManualLine: false) }
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
        TahoeGlass(radius: 20, tone: .panel) {
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
        if selectFirstIfNeeded || selectedWorkspaceId == nil || !workspaces.contains(where: { $0.id == selectedWorkspaceId }) {
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
        guard let envStore, let workspace = selectedWorkspace else { return false }
        do {
            let batch = try envStore.importVariables(
                previews: draft.previews,
                workspaceIds: Array(draft.workspaceIds),
                selectedSetIds: draft.setIds,
                currentWorkspaceId: workspace.id,
                conflictStrategy: draft.conflictStrategy,
                kind: draft.kind,
                actor: NSUserName()
            )
            let materialized = materializeSelectedRepo()
            lastImportSummary = "Imported \(batch.importedCount), overwrote \(batch.overwrittenCount), skipped \(batch.skippedCount)."
            isImportingVariables = false
            refresh(selectFirstIfNeeded: false)
            return materialized
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

private enum RepoEnvScopeTab: String, CaseIterable, Identifiable {
    case project = "Project"
    case shared = "Shared"

    var id: String { rawValue }
}

private enum RepoEnvKindFilter: String, CaseIterable, Identifiable {
    case all = "All Sources"
    case repo = "Repo Only"
    case shared = "Shared Only"

    var id: String { rawValue }
}

private enum RepoEnvTypeFilter: String, CaseIterable, Identifiable {
    case all = "All Types"
    case sensitive = "Sensitive"
    case plain = "Plain"
    case system = "System"

    var id: String { rawValue }
}

private enum RepoEnvStatusFilter: String, CaseIterable, Identifiable {
    case all = "All Status"
    case inActiveSet = "Active Set"
    case notInActiveSet = "Not Active"
    case conflicts = "Conflicts"
    case disabled = "Disabled"

    var id: String { rawValue }
}

private enum RepoEnvSortMode: String, CaseIterable, Identifiable {
    case updatedDesc = "Last Updated"
    case keyAsc = "Name A-Z"
    case keyDesc = "Name Z-A"
    case status = "Status"
    case setCount = "Set Count"

    var id: String { rawValue }
}

private enum RepoEnvVariableStatus {
    case active
    case notInActiveSet
    case conflict
    case disabled

    var label: String {
        switch self {
        case .active: return "Active"
        case .notInActiveSet: return "Not active"
        case .conflict: return "Conflict"
        case .disabled: return "Disabled"
        }
    }

    var rank: Int {
        switch self {
        case .conflict: return 0
        case .disabled: return 1
        case .notInActiveSet: return 2
        case .active: return 3
        }
    }

    func color(_ t: TahoeTokens) -> Color {
        switch self {
        case .active: return t.accent
        case .notInActiveSet: return t.fg3
        case .conflict: return .red
        case .disabled: return t.fg4
        }
    }
}

private enum RepoEnvEditMode: Identifiable {
    case edit(RepoEnvVariableRecord)
    case rotate(RepoEnvVariableRecord)
    case duplicate(RepoEnvVariableRecord, value: String)

    var id: String {
        switch self {
        case .edit(let variable): return "edit-\(variable.id)"
        case .rotate(let variable): return "rotate-\(variable.id)"
        case .duplicate(let variable, _): return "duplicate-\(variable.id)"
        }
    }

    var variable: RepoEnvVariableRecord {
        switch self {
        case .edit(let variable), .rotate(let variable), .duplicate(let variable, _):
            return variable
        }
    }

    var title: String {
        switch self {
        case .edit: return "Edit Env Variable"
        case .rotate: return "Rotate Env Variable"
        case .duplicate: return "Duplicate Env Variable"
        }
    }

    var isRotate: Bool {
        if case .rotate = self { return true }
        return false
    }
}

private struct RepoEnvVariableDraft {
    var key: String
    var value: String
    var note: String
    var kind: RepoEnvVariableKind
    var isEnabled: Bool
    var workspaceIds: Set<UUID>
    var setIds: Set<UUID>
}

private struct RepoEnvImportDraft {
    var previews: [RepoEnvImportPreviewRecord]
    var workspaceIds: Set<UUID>
    var setIds: Set<UUID>
    var conflictStrategy: RepoEnvImportConflictStrategy
    var kind: RepoEnvVariableKind
}

private extension RepoEnvVariableScope {
    var displayName: String {
        switch self {
        case .local:
            return "repo variable"
        case .shared:
            return "shared variable"
        }
    }
}

private struct RepoEnvAddVariableSheet: View {
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

private struct RepoEnvEditVariableSheet: View {
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

private struct RepoEnvImportSheet: View {
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(t.accentAlpha(0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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

private struct RepoEnvVariableDetailSheet: View {
    @Environment(\.tahoe) private var t

    let variable: RepoEnvVariableRecord
    let workspaces: [CodeWorkspaceRecord]
    let envStore: RepoEnvStore?
    let selectedWorkspaceId: UUID?
    let onReveal: () throws -> String
    let onChanged: () -> Void
    let onClose: () -> Void

    @State private var revealedValue: String?
    @State private var revealError: String?
    @State private var assignmentError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(variable.key)
                        .font(TahoeFont.mono(18, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text("\(variable.kind.displayName) · \(variable.scope.displayName)")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                }
                Spacer()
                Button(action: onClose) {
                    TahoeIcon("x", size: 12, weight: .bold)
                }
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailSummary
                    assignmentMatrix
                    auditTrail
                }
                .padding(.bottom, 18)
            }
        }
        .padding(24)
    }

    private var detailSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Value")
                .font(TahoeFont.body(12, weight: .bold))
                .foregroundStyle(t.fg2)
            HStack {
                Text(revealedValue ?? "••••••••")
                    .font(TahoeFont.mono(12, weight: .semibold))
                    .foregroundStyle(revealedValue == nil ? t.fg3 : t.fg)
                    .lineLimit(3)
                Spacer()
                Button(revealedValue == nil ? "Reveal" : "Hide") {
                    if revealedValue == nil {
                        revealValue()
                    } else {
                        revealedValue = nil
                    }
                }
                .buttonStyle(.bordered)
            }
            if let note = variable.note, !note.isEmpty {
                Text(note)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            }
            if let revealError {
                Text(revealError)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.accentAlpha(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(t.hairline, lineWidth: 1)
        }
    }

    private var assignmentMatrix: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assignment Matrix")
                .font(TahoeFont.body(12, weight: .bold))
                .foregroundStyle(t.fg2)
            if let assignmentError {
                Text(assignmentError)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(.red)
            }
            ForEach(workspaces) { workspace in
                let sets = envStore?.sets(for: workspace.id) ?? []
                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.repoDisplayName)
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(workspace.id == selectedWorkspaceId ? t.accent : t.fg2)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(sets) { set in
                            Toggle(set.name, isOn: Binding(
                                get: {
                                    envStore?.assignment(variableId: variable.id, workspaceId: workspace.id, setId: set.id)?.isEnabled == true
                                },
                                set: { enabled in
                                    do {
                                        try envStore?.setAssignment(variableId: variable.id, workspaceId: workspace.id, setId: set.id, enabled: enabled)
                                        assignmentError = nil
                                        onChanged()
                                    } catch {
                                        assignmentError = error.localizedDescription
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .font(TahoeFont.body(11.5))
                        }
                    }
                }
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.accentAlpha(0.025))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(t.hairline, lineWidth: 1)
                }
            }
        }
    }

    private var auditTrail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audit")
                .font(TahoeFont.body(12, weight: .bold))
                .foregroundStyle(t.fg2)
            let events = envStore?.auditEvents(for: variable.id) ?? []
            if events.isEmpty {
                Text("No audit events yet.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            } else {
                ForEach(events.prefix(10)) { event in
                    HStack(spacing: 10) {
                        Text(event.action.rawValue)
                            .font(TahoeFont.body(10.5, weight: .bold))
                            .foregroundStyle(t.accent)
                            .frame(width: 92, alignment: .leading)
                        Text(event.message)
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(relative(event.createdAt))
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg4)
                    }
                }
            }
        }
    }

    private func revealValue() {
        do {
            revealedValue = try onReveal()
            revealError = nil
        } catch {
            revealError = error.localizedDescription
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
