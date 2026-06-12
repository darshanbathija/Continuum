import AppKit
import SwiftUI
import ClawdmeterShared

struct VendorProvisioningSettingsView: View {
    @Environment(\.tahoe) private var t

    let service: VendorProvisioningService?
    let workspaceStore: WorkspaceStore?
    let envStore: RepoEnvStore?

    @State private var vendors: [VendorProvisioningVendor] = VendorProvisioningCatalog.vendors
    @State private var statuses: [String: VendorProvisioningStatus] = [:]
    @State private var filter: VendorProvisioningFilter = .all
    @State private var isChecking = false
    @State private var isInstallingAll = false
    @State private var installAllTask: Task<Void, Never>?
    @State private var installAllTargetCount = 0
    @State private var installProgressByVendor: [String: VendorInstallProgressUpdate.Phase] = [:]
    @State private var overallInstallProgress: Double = 0
    @State private var message: String?
    @State private var importVendor: VendorProvisioningVendor?
    @State private var actionTerminal: VendorProvisioningActionTerminal?

    private var workspaces: [CodeWorkspaceRecord] {
        workspaceStore?.all().sorted {
            $0.repoDisplayName.localizedCaseInsensitiveCompare($1.repoDisplayName) == .orderedAscending
        } ?? []
    }

    private var filteredVendors: [VendorProvisioningVendor] {
        vendors.filter { vendor in
            switch filter {
            case .all: return true
            case .storageDatabase: return vendor.category == .storageDatabase
            case .computeHosting: return vendor.category == .computeHosting
            case .domains: return vendor.category == .domains
            }
        }
    }

    private var scopedVendorsNeedingInstall: [VendorProvisioningVendor] {
        VendorProvisioningService.vendorsNeedingInstall(
            catalog: filteredVendors,
            statuses: Array(statuses.values)
        )
    }

    private var canInstallAll: Bool {
        !scopedVendorsNeedingInstall.isEmpty
    }

    private var installAllButtonTitle: String {
        let count = scopedVendorsNeedingInstall.count
        if isInstallingAll {
            return "Installing..."
        }
        if count > 0 {
            return "Install All (\(count))"
        }
        return "Install All"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            panel(
                title: "Provisioning",
                subtitle: "Connect vendor CLIs in order — install, authenticate, then import env variables into repo sets."
            ) {
                if service == nil || workspaceStore == nil || envStore == nil {
                    Text("Runtime provisioning is not available in previews.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                } else {
                    headerControls
                    if isInstallingAll {
                        installAllProgressBar
                    }
                    TahoeHair().padding(.vertical, 12)
                    filterBar
                    VStack(spacing: 10) {
                        ForEach(filteredVendors) { vendor in
                            VendorProvisioningRow(
                                vendor: vendor,
                                status: statuses[vendor.id],
                                installPhase: installProgressByVendor[vendor.id],
                                hasWorkspaces: !workspaces.isEmpty,
                                actionsDisabled: isInstallingAll,
                                onAction: { action in
                                    Task { await perform(action: action, vendor: vendor) }
                                },
                                onImport: { importVendor = vendor }
                            )
                        }
                    }
                }
            }

            if let message {
                Text(message)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.fg2)
                    .accessibilityIdentifier("settings.provisioning.message")
            }
        }
        .task {
            vendors = service?.vendorsResponse().vendors ?? VendorProvisioningCatalog.vendors
            if statuses.isEmpty, service != nil {
                await checkDevice()
            }
        }
        .sheet(item: $importVendor) { vendor in
            VendorEnvImportSheet(
                vendor: vendor,
                service: service,
                workspaceStore: workspaceStore,
                envStore: envStore,
                onClose: { importVendor = nil }
            )
            .frame(minWidth: 760, minHeight: 700)
        }
        .sheet(item: $actionTerminal) { terminal in
            VendorProvisioningActionTerminalSheet(
                terminal: terminal,
                onClose: {
                    actionTerminal = nil
                    if terminal.shouldRecheckOnClose {
                        Task { await checkDevice() }
                    }
                }
            )
        }
        .accessibilityIdentifier("settings.provisioning.root")
    }

    private var headerControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Device Check")
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg)
                Text("Scans for installed CLIs and authenticated accounts, then guides you through install → sign-in → env import.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            }
            Spacer(minLength: 0)
            Button {
                installAllTask?.cancel()
                installAllTask = Task { await installAll() }
            } label: {
                HStack(spacing: 6) {
                    TahoeIcon("terminal", size: 11, weight: .bold)
                    Text(installAllButtonTitle)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isChecking || isInstallingAll || !canInstallAll)
            .help(installAllHelpText)
            .accessibilityIdentifier("settings.provisioning.install-all")
            Button {
                Task { await checkDevice() }
            } label: {
                HStack(spacing: 6) {
                    TahoeIcon("refresh", size: 11, weight: .bold)
                    Text(isChecking ? "Checking..." : "Check Device")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isChecking || isInstallingAll)
            .accessibilityIdentifier("settings.provisioning.check-device")
        }
    }

    private var installAllHelpText: String {
        if canInstallAll {
            let scope = filter == .all ? "missing" : "missing in \(filter.title)"
            return "Install \(scopedVendorsNeedingInstall.count) \(scope) vendor CLI\(scopedVendorsNeedingInstall.count == 1 ? "" : "s") in the background."
        }
        return "Run Check Device first or install CLIs individually."
    }

    private var installAllProgressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView(value: overallInstallProgress)
                    .progressViewStyle(.linear)
                Text("Installing vendor CLIs")
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Spacer(minLength: 0)
                Button("Cancel", action: ContinuumAnalytics.wrapButton("vendor_provisioning_install_all_cancel", {
                    installAllTask?.cancel()
                }))
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.provisioning.install-all-cancel")
            }
            Text(installAllProgressLabel)
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg3)
        }
        .padding(.top, 10)
        .accessibilityIdentifier("settings.provisioning.install-all-progress")
    }

    private var installAllProgressLabel: String {
        let active = installProgressByVendor.first { _, phase in
            if case .installing = phase { return true }
            return false
        }
        if let active {
            let vendor = vendors.first { $0.id == active.key }
            return "Installing \(vendor?.displayName ?? active.key)..."
        }
        let completed = installProgressByVendor.values.filter {
            if case .succeeded = $0 { return true }
            if case .failed = $0 { return true }
            return false
        }.count
        if completed > 0, installAllTargetCount > 0 {
            return "Finished \(completed) of \(installAllTargetCount) installs."
        }
        return "Preparing installs..."
    }

    private var filterBar: some View {
        Picker("Category", selection: $filter) {
            ForEach(VendorProvisioningFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 520)
        .disabled(isInstallingAll)
        .accessibilityIdentifier("settings.provisioning.category-filter")
    }

    private func panel<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased())
                        .font(TahoeFont.body(11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(t.fg3)
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

    private func checkDevice() async {
        guard let service else { return }
        isChecking = true
        defer { isChecking = false }
        let response = await service.checkDevice()
        vendors = response.vendors
        statuses = Dictionary(uniqueKeysWithValues: response.statuses.map { ($0.vendorId, $0) })
        installProgressByVendor = [:]
        message = "Checked \(response.statuses.count) vendors."
    }

    private func installAll() async {
        guard let service else { return }
        if statuses.isEmpty {
            await checkDevice()
        }
        guard canInstallAll else {
            message = VendorProvisioningError.noInstallTargets.localizedDescription
            return
        }

        let targets = scopedVendorsNeedingInstall
        installAllTargetCount = targets.count
        isInstallingAll = true
        overallInstallProgress = 0
        for vendor in targets {
            installProgressByVendor.removeValue(forKey: vendor.id)
        }
        defer {
            isInstallingAll = false
            installAllTask = nil
            if overallInstallProgress < 1 {
                overallInstallProgress = 1
            }
        }

        do {
            let result = try await service.installAllMissing(
                statuses: Array(statuses.values),
                vendors: targets
            ) { update in
                Task { @MainActor in
                    installProgressByVendor[update.vendorId] = update.phase
                    overallInstallProgress = update.overallProgress
                }
            }
            for (vendorId, failureMessage) in result.failedVendorIds {
                installProgressByVendor[vendorId] = .failed(failureMessage)
            }
            message = result.message
            let response = await service.checkDevice()
            vendors = response.vendors
            statuses = Dictionary(uniqueKeysWithValues: response.statuses.map { ($0.vendorId, $0) })
            for vendorId in result.succeededVendorIds {
                installProgressByVendor.removeValue(forKey: vendorId)
            }
        } catch is CancellationError {
            for (vendorId, phase) in installProgressByVendor {
                if case .installing = phase {
                    installProgressByVendor[vendorId] = .failed("Install cancelled.")
                }
            }
            message = "Install cancelled."
        } catch {
            message = error.localizedDescription
        }
    }

    private func perform(action: VendorProvisioningAction, vendor: VendorProvisioningVendor) async {
        guard let service else { return }
        if isInstallingAll, action.kind != .signup {
            return
        }
        do {
            let response = try await service.performAction(vendorId: vendor.id, actionId: action.id)
            message = response.message
            if let paneId = response.terminalPaneId,
               let host = await TerminalPtyRegistry.shared.host(id: paneId) {
                actionTerminal = VendorProvisioningActionTerminal(
                    id: paneId,
                    title: "\(vendor.displayName) \(action.label)",
                    host: host,
                    shouldRecheckOnClose: action.kind == .install || action.kind == .authenticate
                )
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct VendorProvisioningActionTerminal: Identifiable {
    let id: String
    let title: String
    let host: TerminalPtyHost
    var shouldRecheckOnClose: Bool = false
}

private struct VendorProvisioningActionTerminalSheet: View {
    @Environment(\.tahoe) private var t

    let terminal: VendorProvisioningActionTerminal
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TahoeIcon("terminal", size: 14, weight: .bold)
                    .foregroundStyle(t.accent)
                Text(terminal.title)
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg)
                Spacer(minLength: 0)
                Button("Close", action: ContinuumAnalytics.wrapButton("vendor_provisioning_terminal_close", onClose))
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            TahoeHair()

            DirectPtyTerminalView(host: terminal.host)
                .frame(minWidth: 760, minHeight: 480)

            Text("Close this window when finished — status will refresh automatically.")
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg3)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 760, minHeight: 540)
        .onDisappear {
            Task { await terminal.host.kill() }
        }
        .accessibilityIdentifier("settings.provisioning.action-terminal")
    }
}

private enum VendorProvisioningFilter: String, CaseIterable, Identifiable {
    case all
    case storageDatabase
    case computeHosting
    case domains

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .storageDatabase: return "Storage/DB"
        case .computeHosting: return "Compute"
        case .domains: return "Domains"
        }
    }
}

private struct VendorProvisioningRow: View {
    @Environment(\.tahoe) private var t

    let vendor: VendorProvisioningVendor
    let status: VendorProvisioningStatus?
    let installPhase: VendorInstallProgressUpdate.Phase?
    let hasWorkspaces: Bool
    let actionsDisabled: Bool
    let onAction: (VendorProvisioningAction) -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                TahoeIcon(iconName, size: 18, weight: .bold)
                    .foregroundStyle(t.accent)
                    .frame(width: 34, height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(t.accentAlpha(0.12))
                    }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(vendor.displayName)
                            .font(TahoeFont.body(14, weight: .semibold))
                            .foregroundStyle(t.fg)
                        statusPill
                        if let mcpCount = status?.mcpMatches.count, mcpCount > 0 {
                            Badge(text: "\(mcpCount) MCP", color: .blue)
                        }
                    }
                    Text(subtitle)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                        .lineLimit(2)
                    if !onboarding.guidance.isEmpty {
                        Text(onboarding.guidance)
                            .font(TahoeFont.body(11.5, weight: .semibold))
                            .foregroundStyle(onboarding.step == .configureEnv ? t.fg2 : t.accent)
                            .lineLimit(2)
                    }
                    if showsInstallProgress {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 220)
                            .accessibilityIdentifier("settings.provisioning.install-progress.\(vendor.id)")
                    }
                }
                Spacer(minLength: 0)
                actionsRow
            }

            if let status, !status.mcpMatches.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(status.mcpMatches) { match in
                        Text("\(match.kind) · \(match.name) · \(match.source)")
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(t.fg3)
                    }
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(t.glassTintHi.opacity(0.45))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.7)
        }
        .accessibilityIdentifier("settings.provisioning.vendor.\(vendor.id)")
    }

    private var onboarding: VendorProvisioningOnboardingGuide {
        VendorProvisioningOnboardingGuide.resolve(
            status: status,
            installPhase: mappedInstallPhase
        )
    }

    private var mappedInstallPhase: VendorProvisioningInstallPhase {
        guard let installPhase else { return .idle }
        switch installPhase {
        case .queued, .installing:
            return .installing
        case .failed:
            return .failed
        case .succeeded:
            return .succeeded
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 8) {
            ForEach(visibleActions) { action in
                actionButton(action)
            }
            if onboarding.showsAddEnv {
                addEnvButton
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: VendorProvisioningAction) -> some View {
        let base = Button(action: ContinuumAnalytics.wrapButton("vendor_provisioning_\(action.kind.rawValue)", { onAction(action) })) {
            HStack(spacing: 5) {
                TahoeIcon(icon(for: action.kind), size: 10, weight: .bold)
                Text(action.label)
            }
        }
        .disabled(actionsDisabled && action.kind != .signup)
        .help(action.command ?? action.url?.absoluteString ?? action.label)
        // if/else (not a ternary) keeps each button-style branch monomorphic —
        // a ternary between .borderedProminent and .bordered times out the
        // SwiftUI type-checker.
        if isPrimaryAction(action) {
            base.buttonStyle(.borderedProminent)
        } else {
            base.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var addEnvButton: some View {
        let base = Button(action: ContinuumAnalytics.wrapButton("vendor_provisioning_add_env", onImport)) {
            HStack(spacing: 5) {
                TahoeIcon("tray", size: 10, weight: .bold)
                Text("Add Env")
            }
        }
        .disabled(actionsDisabled || !hasWorkspaces)
        .help(hasWorkspaces ? "Import env variables into repo env sets" : "Add a repository first")
        .accessibilityIdentifier("settings.provisioning.import.\(vendor.id)")
        if onboarding.step == .configureEnv {
            base.buttonStyle(.borderedProminent)
        } else {
            base.buttonStyle(.bordered)
        }
    }

    private var visibleActions: [VendorProvisioningAction] {
        vendor.actions.filter { action in
            switch action.kind {
            case .install: return onboarding.showsInstall
            case .authenticate: return onboarding.showsAuthenticate
            case .signup: return onboarding.showsSignup
            }
        }
    }

    private func isPrimaryAction(_ action: VendorProvisioningAction) -> Bool {
        onboarding.primaryActionKind == action.kind
    }

    private var showsInstallProgress: Bool {
        guard let installPhase else { return false }
        if case .installing = installPhase {
            return true
        }
        return false
    }

    private var statusPill: some View {
        let text = onboarding.statusLabel
        let color: Color
        switch onboarding.step {
        case .unchecked:
            color = .gray
        case .installingCLI:
            color = .blue
        case .installCLI:
            if case .failed = installPhase {
                color = .red
            } else {
                color = .gray
            }
        case .authenticate:
            color = .orange
        case .configureEnv, .complete:
            color = .green
        }
        return Badge(text: text, color: color)
    }

    private var subtitle: String {
        if case .failed(let message) = installPhase {
            return message
        }
        var parts: [String] = []
        if let binary = status?.installedBinary {
            parts.append((binary as NSString).lastPathComponent)
        } else {
            parts.append(vendor.cliNames.joined(separator: " / "))
        }
        if let account = status?.accountLabel {
            parts.append(account)
        }
        if let project = status?.projectLabel {
            parts.append(project)
        }
        if let message = status?.message {
            parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    private var iconName: String {
        switch vendor.category {
        case .storageDatabase: return "stack"
        case .computeHosting: return "terminal"
        case .domains: return "globe"
        }
    }

    private func icon(for kind: VendorProvisioningActionKind) -> String {
        switch kind {
        case .install: return "terminal"
        case .authenticate: return "user"
        case .signup: return "external"
        }
    }
}

private struct Badge: View {
    @Environment(\.tahoe) private var t

    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(TahoeFont.body(10.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(color.opacity(0.12))
            }
            .overlay {
                Capsule().stroke(color.opacity(0.35), lineWidth: 0.7)
            }
    }
}

struct VendorEnvImportSheet: View {
    @Environment(\.tahoe) private var t

    let vendor: VendorProvisioningVendor
    let service: VendorProvisioningService?
    let workspaceStore: WorkspaceStore?
    let envStore: RepoEnvStore?
    let onClose: () -> Void

    @State private var values: [String: String] = [:]
    @State private var workspaces: [CodeWorkspaceRecord] = []
    @State private var currentWorkspaceId: UUID?
    @State private var currentSets: [RepoEnvSetRecord] = []
    @State private var selectedSetIds: Set<UUID> = []
    @State private var allRepos = false
    @State private var conflictStrategy: VendorEnvConflictStrategy = .skip
    @State private var previews: [VendorEnvPreviewItem] = []
    @State private var isWorking = false
    @State private var message: String?

    private var currentWorkspace: CodeWorkspaceRecord? {
        guard let currentWorkspaceId else { return nil }
        return workspaces.first { $0.id == currentWorkspaceId }
    }

    private var candidates: [VendorEnvCandidate] {
        vendor.envTemplates.compactMap { template in
            let value = values[template.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return nil }
            return VendorEnvCandidate(key: template.key, value: values[template.key] ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                TahoeIcon("tray", size: 18, weight: .bold)
                    .foregroundStyle(t.accent)
                    .frame(width: 34, height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(t.accentAlpha(0.12))
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add \(vendor.displayName) Env")
                        .font(TahoeFont.body(18, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text("Values are sent into RepoEnvStore import and stored in Keychain, not this sheet.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                }
                Spacer(minLength: 0)
                Button("Close", action: ContinuumAnalytics.wrapButton("vendor_env_import_close", onClose))
                    .buttonStyle(.bordered)
            }

            if workspaces.isEmpty {
                Text("No repository workspaces have been recorded yet.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            } else {
                form
                previewList
            }

            if let message {
                Text(message)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.fg2)
            }

            Spacer(minLength: 0)

            HStack {
                Picker("Conflict", selection: $conflictStrategy) {
                    ForEach(VendorEnvConflictStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .frame(width: 220)

                Spacer(minLength: 0)
                Button("Preview", action: ContinuumAnalytics.wrapButton("vendor_env_import_preview", {
                    Task { await preview() }
                }))
                .buttonStyle(.bordered)
                .disabled(isWorking || candidates.isEmpty || currentWorkspaceId == nil)
                .accessibilityIdentifier("settings.provisioning.env.preview")

                Button("Import", action: ContinuumAnalytics.wrapButton("vendor_env_import_submit", {
                    Task { await importValues() }
                }))
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || candidates.isEmpty || currentWorkspaceId == nil)
                .accessibilityIdentifier("settings.provisioning.env.import")
            }
        }
        .padding(22)
        .task {
            refreshWorkspaces()
        }
        .onChange(of: currentWorkspaceId) { _, _ in
            refreshSets()
            previews = []
        }
        .onChange(of: allRepos) { _, _ in
            previews = []
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Current Repo")
                        .font(TahoeFont.body(12, weight: .bold))
                        .foregroundStyle(t.fg2)
                    Picker("Current Repo", selection: $currentWorkspaceId) {
                        ForEach(workspaces) { workspace in
                            Text(workspace.repoDisplayName).tag(Optional(workspace.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    .accessibilityIdentifier("settings.provisioning.env.current-repo")
                }
                Toggle("All repos", isOn: $allRepos)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .toggleStyle(.switch)
                    .help("Imports to every workspace. Selected sets only specialize the current repo.")
                    .accessibilityIdentifier("settings.provisioning.env.all-repos")
                Spacer(minLength: 0)
            }

            if !currentSets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Repo Sets")
                        .font(TahoeFont.body(12, weight: .bold))
                        .foregroundStyle(t.fg2)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(currentSets) { set in
                            Button {
                                if selectedSetIds.contains(set.id) {
                                    selectedSetIds.remove(set.id)
                                } else {
                                    selectedSetIds.insert(set.id)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if selectedSetIds.contains(set.id) {
                                        TahoeIcon("check", size: 9, weight: .bold)
                                    }
                                    Text(set.name)
                                }
                                .font(TahoeFont.body(11.5, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(selectedSetIds.contains(set.id) ? t.accent : t.fg2)
                            .background {
                                Capsule()
                                    .fill(selectedSetIds.contains(set.id) ? t.accentAlpha(0.14) : t.accentAlpha(0.04))
                            }
                            .overlay {
                                Capsule().stroke(selectedSetIds.contains(set.id) ? t.accentAlpha(0.5) : t.hairline, lineWidth: 1)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Variables")
                    .font(TahoeFont.body(12, weight: .bold))
                    .foregroundStyle(t.fg2)
                ForEach(vendor.envTemplates) { template in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.key)
                                .font(TahoeFont.mono(12, weight: .bold))
                                .foregroundStyle(t.fg)
                            Text(template.label)
                                .font(TahoeFont.body(11))
                                .foregroundStyle(t.fg3)
                        }
                        .frame(width: 230, alignment: .leading)
                        Group {
                            if template.kind == .sensitive {
                                SecureField("Value", text: binding(for: template.key))
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField("Value", text: binding(for: template.key))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .accessibilityIdentifier("settings.provisioning.env.value.\(template.key)")
                        Badge(text: template.kind.rawValue, color: template.kind == .sensitive ? .orange : .blue)
                    }
                }
            }
        }
    }

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(TahoeFont.body(12, weight: .bold))
                .foregroundStyle(t.fg2)
            if previews.isEmpty {
                Text("Preview before import to see duplicate, invalid, and ready rows.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            } else {
                VStack(spacing: 6) {
                    ForEach(previews) { item in
                        HStack(spacing: 10) {
                            Text(item.key ?? "line \(item.line)")
                                .font(TahoeFont.mono(11.5, weight: .bold))
                                .foregroundStyle(t.fg)
                            Spacer(minLength: 0)
                            Text(item.status)
                                .font(TahoeFont.body(10.5, weight: .bold))
                                .foregroundStyle(item.canImport ? .green : .orange)
                            Text(item.message)
                                .font(TahoeFont.body(11))
                                .foregroundStyle(t.fg3)
                        }
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(t.glassTintHi.opacity(0.35))
                        }
                    }
                }
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    private func refreshWorkspaces() {
        workspaces = workspaceStore?.all().sorted {
            $0.repoDisplayName.localizedCaseInsensitiveCompare($1.repoDisplayName) == .orderedAscending
        } ?? []
        if currentWorkspaceId == nil || !workspaces.contains(where: { $0.id == currentWorkspaceId }) {
            currentWorkspaceId = workspaces.first?.id
        }
        refreshSets()
    }

    private func refreshSets() {
        guard let id = currentWorkspaceId, let envStore else {
            currentSets = []
            selectedSetIds = []
            return
        }
        _ = envStore.ensureDefaultSet(workspaceId: id)
        currentSets = envStore.sets(for: id)
        let active = currentSets.first(where: \.isActive) ?? currentSets.first
        selectedSetIds = Set(active.map { [$0.id] } ?? [])
    }

    private func preview() async {
        guard let service, let currentWorkspaceId else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let targetWorkspaceIds = allRepos ? workspaces.map(\.id) : [currentWorkspaceId]
            let response = try service.previewEnv(
                vendorId: vendor.id,
                request: VendorEnvPreviewRequest(
                    currentWorkspaceId: currentWorkspaceId,
                    workspaceIds: targetWorkspaceIds,
                    candidates: candidates
                )
            )
            previews = response.previews
            message = "Previewed \(response.previews.count) rows."
        } catch {
            message = error.localizedDescription
        }
    }

    private func importValues() async {
        guard let service, let currentWorkspaceId else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let targetWorkspaceIds = allRepos ? workspaces.map(\.id) : [currentWorkspaceId]
            let response = try service.importEnv(
                vendorId: vendor.id,
                request: VendorEnvImportRequest(
                    currentWorkspaceId: currentWorkspaceId,
                    workspaceIds: targetWorkspaceIds,
                    selectedSetIds: Array(selectedSetIds),
                    candidates: candidates,
                    conflictStrategy: conflictStrategy
                )
            )
            message = "Imported \(response.importedCount), overwrote \(response.overwrittenCount), skipped \(response.skippedCount)."
            previews = []
        } catch {
            message = error.localizedDescription
        }
    }
}
