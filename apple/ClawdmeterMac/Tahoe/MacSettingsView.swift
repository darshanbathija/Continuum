import SwiftUI
import AppKit
import ClawdmeterShared

/// Mac Settings — drives the global TahoeThemeStore so flipping a switch
/// here repaints every other surface. Ports `mac-settings.jsx`.
///
/// v0.12 button-wiring pass: the Auto-revive toggle now writes to the
/// per-provider `AppModel.setAutoReviveEnabled(_:)` for every provider
/// that supports the feature. Mirror-to-iPhone and Notify-at-90% remain
/// local state with hint copy explaining they're not yet wired (no
/// daemon endpoints exist for those today). Reset-to-defaults wired to
/// `TahoeThemeStore.resetToDefaults()`.
public struct MacSettingsView: View {
    @Environment(\.tahoe) private var t
    @Bindable public var theme: TahoeThemeStore

    @ObservedObject var claudeModel: AppModel
    @ObservedObject var codexModel: AppModel
    @ObservedObject var geminiModel: AppModel
    @ObservedObject var presentationStore: SessionPresentationStore
    @Binding private var requestedSection: String?
    @StateObject private var chimePlayer = ChimeAudioPlayer.shared
    /// v0.22.9: runtime threaded in so the consolidated settings page
    /// can embed PairingSettingsView (needs AppRuntime for the daemon
    /// + pairing token shape). Optional so Previews don't have to
    /// stand up a full runtime.
    var runtime: AppRuntime?

    /// Source of truth for the auto-revive toggle. Reads the real state
    /// off whichever provider supports it (Claude is the canonical one
    /// today). Setter fans out to every provider that supports auto-revive.
    @SceneStorage("clawdmeter.mac.settings.selectedSection") private var selectedSectionRaw: String = SettingsSection.visual.rawValue
    @State private var settingsSearch: String = ""

    // v0.22.9: dropped to `internal` because the `runtime` parameter
    // exposes `AppRuntime`, which lives in the Mac target (not the
    // shared library) and is itself `internal`. The Settings page is
    // only constructed from `MacRootView` inside the same target, so
    // the access change has no external impact.
    init(
        theme: TahoeThemeStore,
        claudeModel: AppModel,
        codexModel: AppModel,
        geminiModel: AppModel,
        runtime: AppRuntime? = nil,
        presentationStore: SessionPresentationStore,
        requestedSection: Binding<String?> = .constant(nil)
    ) {
        self.theme = theme
        self.claudeModel = claudeModel
        self.codexModel = codexModel
        self.geminiModel = geminiModel
        self.runtime = runtime
        self.presentationStore = presentationStore
        _requestedSection = requestedSection
    }

    /// Composite auto-revive state. True when any provider that supports
    /// auto-revive currently has it enabled. Setter writes to every
    /// supporting provider so the toggle is "all or nothing" — matches the
    /// per-provider auto-revive card on MacUsageView's hero column.
    private var autoReviveBinding: Binding<Bool> {
        Binding(
            get: {
                let providers = [claudeModel, codexModel, geminiModel]
                    .filter { $0.config.supportsAutoRevive }
                guard !providers.isEmpty else { return false }
                return providers.contains { $0.autoReviver.isEnabled }
            },
            set: { newValue in
                for model in [claudeModel, codexModel, geminiModel]
                    where model.config.supportsAutoRevive {
                    model.setAutoReviveEnabled(newValue)
                }
            }
        )
    }

    private var supportsAnyAutoRevive: Bool {
        [claudeModel, codexModel, geminiModel].contains { $0.config.supportsAutoRevive }
    }

    public var body: some View {
        VStack(spacing: 18) {
            SettingsHeader(search: $settingsSearch, onReset: { theme.resetToDefaults() })

            HStack(alignment: .top, spacing: 18) {
                SettingsSidebar(
                    selection: displayedSection ?? selectedSection,
                    query: settingsSearch,
                    onSelect: { selectedSectionRaw = $0.rawValue }
                )
                .frame(width: 220)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let displayedSection {
                            SettingsSectionHeader(section: displayedSection)
                            selectedSectionContent(for: displayedSection)
                        } else {
                            noMatchingSettings
                        }
                    }
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 6).padding(.bottom, 20).padding(.top, 20)
        .onChange(of: settingsSearch) { _, _ in
            syncSelectedSectionToSearch()
        }
        .onAppear(perform: applyRequestedSection)
        .onChange(of: requestedSection) { _, _ in
            applyRequestedSection()
        }
    }

    private var selectedSection: SettingsSection {
        SettingsSection(rawValue: selectedSectionRaw) ?? .visual
    }

    private var matchingSections: [SettingsSection] {
        SettingsSection.matching(query: settingsSearch)
    }

    private var displayedSection: SettingsSection? {
        let matches = matchingSections
        guard !matches.isEmpty else { return nil }
        return matches.contains(selectedSection) ? selectedSection : matches[0]
    }

    private func syncSelectedSectionToSearch() {
        let matches = matchingSections
        guard !matches.isEmpty, !matches.contains(selectedSection) else { return }
        selectedSectionRaw = matches[0].rawValue
    }

    private func applyRequestedSection() {
        guard let requestedSection,
              let section = SettingsSection(rawValue: requestedSection)
        else { return }
        settingsSearch = ""
        selectedSectionRaw = section.rawValue
        self.requestedSection = nil
    }

    @ViewBuilder
    private func selectedSectionContent(for section: SettingsSection) -> some View {
        switch section {
        case .visual:
            visualSettings
        case .providers:
            providerSettings
        case .workspaces:
            workspaceSettings
        case .envVariables:
            envVariablesSettings
        case .advanced:
            advancedSettings
        case .devices:
            deviceSettings
        case .diagnostics:
            diagnosticsSettings
        case .notifications:
            notificationSettings
        case .externalTools:
            externalToolSettings
        case .shortcuts:
            shortcutSettings
        case .updates:
            updatesSettings
        }
    }

    private var noMatchingSettings: some View {
        SettingsCard(title: "No settings found",
                     sub: "Try a different search term or clear the field.") {
            Text("No matching settings sections.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
        }
    }

    @ViewBuilder
    private var visualSettings: some View {
        // Dark-only v1 (Quiet Black Workbench). The appearance / surface /
        // wallpaper / accent knobs are gone — the palette is a single fixed
        // dark instrument. A calibrated light variant is a deliberate later
        // addition (DESIGN.md §Aesthetic Direction).
        SettingsCard(title: "Appearance",
                     sub: "Continuum is dark-only in v1 — the Quiet Black Workbench palette.") {
            SettingsRow(label: "Theme", hint: "A calibrated light variant is a deliberate later addition.") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(ContinuumTokens.live)
                        .frame(width: 6, height: 6)
                    Text("Quiet Black · Dark")
                        .font(ContinuumFont.mono(12, weight: .medium))
                        .foregroundStyle(ContinuumTokens.fg2)
                }
            }
        }

        SettingsCard(title: "Code and diff themes",
                     sub: "Shared presentation defaults for code blocks, diffs, and review panes.") {
            SettingsRow(label: "Syntax theme", hint: "Changes code/diff contrast without changing the global app theme.") {
                Picker("Syntax theme", selection: syntaxThemeBinding) {
                    ForEach(CodeSyntaxTheme.allCases, id: \.self) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Diff layout", hint: "Unified is dense; split keeps additions and deletions in separate columns.") {
                Picker("Diff layout", selection: diffDisplayModeBinding) {
                    ForEach(DiffDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            TahoeHair().padding(.vertical, 14)
            SyntaxThemePreview(
                theme: presentationStore.snapshot.syntaxTheme,
                diffMode: presentationStore.snapshot.diffDisplayMode
            )
        }
    }

    @ViewBuilder
    private var providerSettings: some View {
        SettingsCard(title: "Providers", sub: nil) {
            ProviderPreferenceRows(client: runtime?.loopbackClient, runtime: runtime)
        }

        // One-time Full Disk Access opt-in. Continuum reads other tools' usage
        // (~/.codex, ~/.gemini, OpenCode); without access macOS re-prompts every
        // few minutes. The Release build is non-sandboxed (#230), so FDA durably
        // stops the "access data from other apps" prompt for the shipped app.
        if FullDiskAccessBanner.shouldShow() {
            FullDiskAccessBanner()
        }
    }

    @ViewBuilder
    private var workspaceSettings: some View {
        SettingsCard(title: "Files to copy",
                     sub: "Effective ignored-file patterns copied into new worktrees.") {
            WorkspaceFilesToCopySettingsRows(store: runtime?.workspaceStore)
        }
    }

    @ViewBuilder
    private var envVariablesSettings: some View {
        RepoEnvVariablesSettingsView(
            workspaceStore: runtime?.workspaceStore,
            envStore: runtime?.repoEnvStore,
            resolver: runtime?.repoEnvRuntimeResolver
        )
    }

    @ViewBuilder
    private var advancedSettings: some View {
        // The "Codex SDK" runtime toggle was removed — Codex chat + code now
        // both drive `codex app-server` directly (no Node sidecar), and the
        // ChatGPT provider toggle is the single control.
        VendorProvisioningSettingsView(
            service: runtime?.vendorProvisioningService,
            workspaceStore: runtime?.workspaceStore,
            envStore: runtime?.repoEnvStore
        )
    }

    @ViewBuilder
    private var deviceSettings: some View {
        if supportsAnyAutoRevive {
            SettingsCard(title: "Quota & sync",
                         sub: "Behavior that affects the menu-bar agent and the paired iPhone.") {
                SettingsRow(label: "Auto-revive 5h timer",
                            hint: "Keeps rolling quota windows warm for providers that support a non-consuming keepalive.") {
                    TahoeToggleView(on: autoReviveBinding)
                }
            }
        }

        SettingsCard(title: "Live Activities",
                     sub: "Real-time iPhone Lock Screen + Dynamic Island state for each running session.") {
            LiveActivitySetupView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let runtime {
            SettingsCard(title: "Pairing",
                         sub: "Pair an iPhone over Tailscale so the iPhone app + widgets see live quota + sessions.") {
                PairingSettingsView(runtime: runtime)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSettings: some View {
        SettingsCard(title: "Diagnostics",
                     sub: "Diagnose data sources, copy debug bundles, force refresh, and explore the on-disk cache.") {
            DiagnosticsSettingsView()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var notificationSettings: some View {
        SettingsCard(title: "Notifications",
                     sub: "Client-local banner, chime, DND, batching, and preview behavior.") {
            SettingsRow(label: "Do Not Disturb", hint: "Suppresses banners and sounds. Sidebar badges and unread state remain visible.") {
                TahoeToggleView(on: notificationPreferenceBinding(\.dndEnabled))
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Batch banners", hint: "Group rapid session events into fewer notifications.") {
                TahoeToggleView(on: notificationPreferenceBinding(\.batchBanners))
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Play chimes", hint: "Audible completion and attention cues when DND is off.") {
                TahoeToggleView(on: notificationPreferenceBinding(\.playChimes))
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Chime pack", hint: "Choose the completion sound used by in-app chimes.") {
                Picker("Chime pack", selection: chimePackBinding) {
                    ForEach(ChimePack.allCases, id: \.self) { pack in
                        Text(pack.displayName).tag(pack)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Show sensitive previews", hint: "Include prompt and transcript snippets in notification previews.") {
                TahoeToggleView(on: notificationPreferenceBinding(\.sensitivePreviews))
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Test chime", hint: "Plays the configured in-app chime without sending a banner.") {
                Button("Play") {
                    ChimeAudioPlayer.shared.playCompletion()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var chimePackBinding: Binding<ChimePack> {
        Binding(
            get: { chimePlayer.settings.pack },
            set: { chimePlayer.settings.pack = $0 }
        )
    }

    @ViewBuilder
    private var externalToolSettings: some View {
        SettingsCard(title: "External tools",
                     sub: "Configure where file, PR, and terminal actions open.") {
            SettingsRow(label: "Editor", hint: "Used by transcript and diff file-line actions before falling back to Finder.") {
                Picker("Editor", selection: externalEditorBinding) {
                    Text("Xcode").tag("xed")
                    Text("Finder").tag("finder")
                    Text("System default").tag("default")
                }
                .labelsHidden()
                .frame(width: 170)
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Recent file actions", hint: "Paths opened from transcript or diff chips stay local on this Mac.") {
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(presentationStore.snapshot.recentPathActions.prefix(3), id: \.self) { path in
                        Text(path)
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if presentationStore.snapshot.recentPathActions.isEmpty {
                        Text("No file actions yet")
                            .font(TahoeFont.body(11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 260, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var shortcutSettings: some View {
        SettingsCard(title: "Keyboard shortcuts",
                     sub: "Client-local overrides apply immediately to the command palette and global shortcut dispatcher.") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ClawdmeterShortcutRegistry.defaults) { shortcut in
                    SettingsRow(label: shortcut.label, hint: "\(shortcut.scope.rawValue.capitalized) · default \(shortcut.displayChord)") {
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 8) {
                                TextField(shortcut.displayChord, text: shortcutOverrideBinding(shortcut.id))
                                    .textFieldStyle(.roundedBorder)
                                    .font(TahoeFont.mono(11))
                                    .frame(width: 96)
                                Button("Reset") {
                                    try? presentationStore.setShortcutOverride(id: shortcut.id, chord: nil)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(presentationStore.snapshot.shortcutOverrides[shortcut.id] == nil)
                            }
                            if let conflict = shortcutConflict(for: shortcut) {
                                Text(conflict)
                                    .font(TahoeFont.body(10.5, weight: .semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    if shortcut.id != ClawdmeterShortcutRegistry.defaults.last?.id {
                        TahoeHair().padding(.vertical, 10)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var updatesSettings: some View {
        SettingsCard(title: "Updates",
                     sub: "Sparkle appcast status, release notes, and manual recovery.") {
            UpdateSettingsPanel(coordinator: runtime?.updateCoordinator)
        }
    }

    private func notificationPreferenceBinding(_ keyPath: WritableKeyPath<NotificationPresentationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { presentationStore.snapshot.notificationPreferences[keyPath: keyPath] },
            set: { newValue in
                var prefs = presentationStore.snapshot.notificationPreferences
                prefs[keyPath: keyPath] = newValue
                try? presentationStore.setNotificationPreferences(prefs)
            }
        )
    }

    private var externalEditorBinding: Binding<String> {
        Binding(
            get: { presentationStore.snapshot.externalEditorIdentifier ?? "xed" },
            set: { try? presentationStore.setExternalEditorIdentifier($0) }
        )
    }

    private var syntaxThemeBinding: Binding<CodeSyntaxTheme> {
        Binding(
            get: { presentationStore.snapshot.syntaxTheme },
            set: { try? presentationStore.setSyntaxTheme($0) }
        )
    }

    private func shortcutConflict(for shortcut: ClawdmeterShortcut) -> String? {
        let registry = ClawdmeterShortcutRegistry()
        let candidate = registry.displayChord(for: shortcut, overrides: presentationStore.snapshot.shortcutOverrides)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        let normalized = normalizeShortcutChord(candidate)
        let conflicts = ClawdmeterShortcutRegistry.defaults.filter { other in
            other.id != shortcut.id
                && normalizeShortcutChord(registry.displayChord(for: other, overrides: presentationStore.snapshot.shortcutOverrides)) == normalized
        }
        guard let first = conflicts.first else { return nil }
        return "Conflicts with \(first.label)"
    }

    private func normalizeShortcutChord(_ chord: String) -> String {
        let canonical = chord
            .replacingOccurrences(of: "Command", with: "⌘")
            .replacingOccurrences(of: "Cmd", with: "⌘")
            .replacingOccurrences(of: "Shift", with: "⇧")
            .replacingOccurrences(of: "Option", with: "⌥")
            .replacingOccurrences(of: "Alt", with: "⌥")
            .replacingOccurrences(of: "Control", with: "⌃")
            .replacingOccurrences(of: "Ctrl", with: "⌃")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        let hasCommand = canonical.contains("⌘")
        let hasShift = canonical.contains("⇧")
        let hasOption = canonical.contains("⌥")
        let hasControl = canonical.contains("⌃")
        let key = canonical
            .replacingOccurrences(of: "⌘", with: "")
            .replacingOccurrences(of: "⇧", with: "")
            .replacingOccurrences(of: "⌥", with: "")
            .replacingOccurrences(of: "⌃", with: "")
        return [
            hasCommand ? "⌘" : "",
            hasShift ? "⇧" : "",
            hasOption ? "⌥" : "",
            hasControl ? "⌃" : ""
        ].joined() + key
    }

    private var diffDisplayModeBinding: Binding<DiffDisplayMode> {
        Binding(
            get: { presentationStore.snapshot.diffDisplayMode },
            set: { try? presentationStore.setDiffDisplayMode($0) }
        )
    }

    private func shortcutOverrideBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { presentationStore.snapshot.shortcutOverrides[id] ?? "" },
            set: { try? presentationStore.setShortcutOverride(id: id, chord: $0) }
        )
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case visual
    case providers
    case workspaces
    case envVariables
    case advanced
    case devices
    case diagnostics
    case notifications
    case externalTools
    case shortcuts
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visual: return "Visual"
        case .providers: return "Providers"
        case .workspaces: return "Workspaces"
        case .envVariables: return "Env Variables"
        case .advanced: return "Advanced"
        case .devices: return "Devices"
        case .diagnostics: return "Diagnostics"
        case .notifications: return "Notifications"
        case .externalTools: return "External Tools"
        case .shortcuts: return "Shortcuts"
        case .updates: return "Updates"
        }
    }

    var subtitle: String {
        switch self {
        case .visual:
            return "Theme, glass surface, wallpaper, and accent color."
        case .providers:
            return "Choose providers and default models."
        case .workspaces:
            return "Worktree setup, copied local files, and branch isolation."
        case .envVariables:
            return "Named repo env sets, shared variables, and .env.local materialization."
        case .advanced:
            return "Vendor CLI, MCP, hosting, storage, and domain provisioning."
        case .devices:
            return "Quota behavior, iPhone mirroring, Live Activities, and pairing."
        case .diagnostics:
            return "Debug bundles, source checks, cache tools, and wire inspection."
        case .notifications:
            return "DND, batching, chimes, previews, and event toggles."
        case .externalTools:
            return "Editor, Finder, terminal, GitHub, and file action preferences."
        case .shortcuts:
            return "Searchable shortcut overrides and reset controls."
        case .updates:
            return "Appcast checks, automatic downloads, release notes, and fallback links."
        }
    }

    var icon: String {
        switch self {
        case .visual: return "sparkles"
        case .providers: return "terminal"
        case .workspaces: return "folder"
        case .envVariables: return "command"
        case .advanced: return "bolt"
        case .devices: return "link"
        case .diagnostics: return "gear"
        case .notifications: return "bell"
        case .externalTools: return "external"
        case .shortcuts: return "command"
        case .updates: return "arrow.down.circle"
        }
    }

    static func matching(query: String) -> [SettingsSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            section.title.lowercased().contains(needle)
                || section.subtitle.lowercased().contains(needle)
                || section.rawValue.lowercased().contains(needle)
        }
    }
}

private struct SettingsSidebar: View {
    @Environment(\.tahoe) private var t
    var selection: SettingsSection
    var query: String
    var onSelect: (SettingsSection) -> Void

    private var visibleSections: [SettingsSection] {
        SettingsSection.matching(query: query)
    }

    var body: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(alignment: .leading, spacing: 6) {
                Text("GROUPS")
                    .font(TahoeFont.body(10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(t.fg4)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)

                ForEach(visibleSections) { section in
                    SettingsSidebarRow(
                        section: section,
                        isSelected: section == selection,
                        onSelect: { onSelect(section) }
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
        }
    }
}

private struct SettingsSidebarRow: View {
    @Environment(\.tahoe) private var t
    var section: SettingsSection
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                TahoeIcon(section.icon, size: 13, weight: .semibold)
                    .foregroundStyle(isSelected ? t.accent : t.fg3)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(isSelected ? t.fg : t.fg2)
                        .lineLimit(1)
                    Text(section.subtitle)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg4)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? t.accentAlpha(t.dark ? 0.16 : 0.09) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? t.accentAlpha(0.55) : Color.clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.section.\(section.rawValue)")
    }
}

private struct SettingsSectionHeader: View {
    @Environment(\.tahoe) private var t
    var section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TahoeIcon(section.icon, size: 13, weight: .semibold)
                    .foregroundStyle(t.accent)
                Text(section.title)
                    .font(TahoeFont.body(18, weight: .bold))
                    .foregroundStyle(t.fg)
            }
            Text(section.subtitle)
                .font(TahoeFont.body(12.5))
                .foregroundStyle(t.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}

// MARK: - Header

private struct SettingsHeader: View {
    @Environment(\.tahoe) private var t
    @Binding var search: String
    var onReset: () -> Void
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(TahoeFont.body(28, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(t.fg)
                Text("Tweak the look of the app and how it talks to your devices.")
                    .font(TahoeFont.body(13))
                    .foregroundStyle(t.fg3)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(t.fg3)
                TextField("Search settings", text: $search)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                if !search.isEmpty {
                    Button(action: { search = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(t.fg3)
                    }
                    .buttonStyle(.plain)
                    .help("Clear settings search")
                }
            }
            .font(TahoeFont.body(12))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(t.hair2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            TahoeGhostButton(size: .s, action: onReset) {
                HStack(spacing: 5) {
                    TahoeIcon("refresh", size: 10)
                    Text("Reset to defaults")
                }
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 4)
    }
}

// MARK: - Card / row

private struct SettingsCard<Content: View>: View {
    @Environment(\.tahoe) private var t
    var title: String
    var sub: String?
    @ViewBuilder var content: Content

    var body: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased())
                        .font(TahoeFont.body(11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(t.fg3)
                    if let sub {
                        Text(sub).font(TahoeFont.body(12.5)).foregroundStyle(t.fg3)
                    }
                }
                .padding(.bottom, 18)
                content
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsRow<Control: View>: View {
    @Environment(\.tahoe) private var t
    var label: String
    var hint: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(TahoeFont.body(14, weight: .semibold)).foregroundStyle(t.fg)
                if let hint {
                    Text(hint)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                        .frame(maxWidth: 460, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

private struct SyntaxThemePreview: View {
    let theme: CodeSyntaxTheme
    let diffMode: DiffDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PREVIEW")
                    .font(ContinuumFont.etched(10))
                    .tracking(0.6)
                    .foregroundStyle(ContinuumTokens.fg3)
                Spacer()
                Text("\(theme.label) · \(diffMode.label)")
                    .font(ContinuumFont.mono(11, weight: .semibold))
                    .foregroundStyle(previewForeground)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("func restyleUpdaterSurface() {")
                    .font(ContinuumFont.mono(12, weight: .medium))
                    .foregroundStyle(previewForeground)
                Text("    settings.preview = .live")
                    .font(ContinuumFont.mono(12, weight: .medium))
                    .foregroundStyle(accentForeground)
                Text("}")
                    .font(ContinuumFont.mono(12, weight: .medium))
                    .foregroundStyle(previewForeground)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(previewBackground, in: RoundedRectangle(cornerRadius: ContinuumTokens.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ContinuumTokens.Radius.card, style: .continuous)
                    .strokeBorder(previewBorder, lineWidth: 0.5)
            }

            diffPreview
        }
    }

    @ViewBuilder
    private var diffPreview: some View {
        switch diffMode {
        case .unified:
            VStack(alignment: .leading, spacing: 4) {
                diffLine("- native setting looked unchanged", foreground: removalForeground, background: removalBackground)
                diffLine("+ live preview updates immediately", foreground: additionForeground, background: additionBackground)
            }
        case .split:
            HStack(alignment: .top, spacing: 8) {
                diffPane(title: "Before", text: "native setting looked unchanged", foreground: removalForeground, background: removalBackground)
                diffPane(title: "After", text: "live preview updates immediately", foreground: additionForeground, background: additionBackground)
            }
        }
    }

    private func diffLine(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(ContinuumFont.mono(11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: ContinuumTokens.Radius.row, style: .continuous))
    }

    private func diffPane(title: String, text: String, foreground: Color, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(ContinuumFont.etched(9.5))
                .tracking(0.5)
                .foregroundStyle(ContinuumTokens.fg3)
            Text(text)
                .font(ContinuumFont.mono(11, weight: .medium))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background, in: RoundedRectangle(cornerRadius: ContinuumTokens.Radius.row, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewBackground: Color {
        switch theme {
        case .tahoe:
            return Color(.sRGB, red: 0.05, green: 0.09, blue: 0.10, opacity: 0.55)
        case .graphite:
            return ContinuumTokens.surface2
        case .xcode:
            return Color(.sRGB, red: 0.05, green: 0.06, blue: 0.10, opacity: 0.68)
        }
    }

    private var previewForeground: Color {
        switch theme {
        case .tahoe:
            return Color(.sRGB, red: 0.78, green: 0.90, blue: 0.90)
        case .graphite:
            return ContinuumTokens.fg2
        case .xcode:
            return Color(.sRGB, red: 0.74, green: 0.80, blue: 0.94)
        }
    }

    private var accentForeground: Color {
        switch theme {
        case .tahoe:
            return Color(.sRGB, red: 0.32, green: 0.92, blue: 0.66)
        case .graphite:
            return ContinuumTokens.fg
        case .xcode:
            return Color(.sRGB, red: 0.46, green: 0.95, blue: 0.60)
        }
    }

    private var previewBorder: Color {
        switch theme {
        case .tahoe:
            return Color(.sRGB, red: 0.32, green: 0.92, blue: 0.66, opacity: 0.18)
        case .graphite:
            return ContinuumTokens.hairline
        case .xcode:
            return Color(.sRGB, red: 0.46, green: 0.62, blue: 0.95, opacity: 0.22)
        }
    }

    private var additionForeground: Color {
        switch theme {
        case .tahoe:
            return Color(.sRGB, red: 0.32, green: 0.92, blue: 0.66)
        case .graphite:
            return Color(.sRGB, red: 0.76, green: 0.88, blue: 0.76)
        case .xcode:
            return Color(.sRGB, red: 0.46, green: 0.95, blue: 0.60)
        }
    }

    private var removalForeground: Color {
        switch theme {
        case .tahoe:
            return Color(.sRGB, red: 1.0, green: 0.48, blue: 0.54)
        case .graphite:
            return Color(.sRGB, red: 0.92, green: 0.72, blue: 0.72)
        case .xcode:
            return Color(.sRGB, red: 1.0, green: 0.50, blue: 0.60)
        }
    }

    private var additionBackground: Color {
        switch theme {
        case .tahoe:
            return Color.green.opacity(0.16)
        case .graphite:
            return Color.gray.opacity(0.18)
        case .xcode:
            return Color(.sRGB, red: 0.18, green: 0.72, blue: 0.36, opacity: 0.18)
        }
    }

    private var removalBackground: Color {
        switch theme {
        case .tahoe:
            return Color.red.opacity(0.16)
        case .graphite:
            return Color.gray.opacity(0.16)
        case .xcode:
            return Color(.sRGB, red: 0.86, green: 0.12, blue: 0.20, opacity: 0.18)
        }
    }
}

private struct WorkspaceFilesToCopySettingsRows: View {
    @Environment(\.tahoe) private var t
    let store: WorkspaceStore?
    @State private var records: [CodeWorkspaceRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if records.isEmpty {
                Text("No repository workspaces have been recorded yet.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            } else {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    workspaceRow(record)
                    if index != records.count - 1 {
                        TahoeHair()
                    }
                }
            }
        }
        .task { refresh() }
    }

    @ViewBuilder
    private func workspaceRow(_ record: CodeWorkspaceRecord) -> some View {
        let effective = effectivePatterns(for: record)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.repoDisplayName)
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg)
                Text(effective.sourceLabel)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(effective.readOnly ? t.accent : t.fg3)
                Spacer(minLength: 0)
                Text("max \(record.filesToCopy.maxFiles) files")
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg4)
            }

            Text(effective.display)
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text("per file \(Self.bytes(record.filesToCopy.maxBytesPerFile)) · total \(Self.bytes(record.filesToCopy.maxTotalBytes)) · directories \(record.filesToCopy.allowDirectories ? "allowed" : "files only")")
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg4)
                .lineLimit(2)
        }
    }

    private func effectivePatterns(for record: CodeWorkspaceRecord) -> (sourceLabel: String, display: String, readOnly: Bool) {
        let includeURL = URL(fileURLWithPath: record.repoRoot, isDirectory: true)
            .appendingPathComponent(".worktreeinclude")
        if let text = try? String(contentsOf: includeURL, encoding: .utf8) {
            return (
                ".worktreeinclude read-only",
                text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).joined(separator: ", "),
                true
            )
        }
        if !record.filesToCopy.enabled {
            return ("disabled", "(disabled)", false)
        }
        let isDefault = record.filesToCopy.mode == .allIgnored
            && record.filesToCopy.patterns == WorkspaceFilesToCopySettings.defaultPatterns
            && record.filesToCopy.maxFiles == WorkspaceFilesToCopySettings.defaultMaxFiles
            && record.filesToCopy.maxBytesPerFile == WorkspaceFilesToCopySettings.defaultMaxBytesPerFile
            && record.filesToCopy.maxTotalBytes == WorkspaceFilesToCopySettings.defaultMaxTotalBytes
            && record.filesToCopy.allowDirectories == true
        let display = record.filesToCopy.mode == .allIgnored
            ? "all ignored files, directories, dependencies, build artifacts, and local databases"
            : record.filesToCopy.patterns.joined(separator: ", ")
        return (isDefault ? "default" : "settings", display, false)
    }

    private func refresh() {
        records = store?.all().sorted { $0.repoDisplayName.lowercased() < $1.repoDisplayName.lowercased() } ?? []
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

// MARK: - SwatchToggle

private struct SwatchToggle: View {
    @Environment(\.tahoe) private var t
    struct Option { var key: String; var label: String; var swatch: AnyView }
    var value: String
    var options: [Option]
    var onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.key) { opt in
                let on = opt.key == value
                Button { onChange(opt.key) } label: {
                    VStack(spacing: 6) {
                        opt.swatch
                            .frame(width: 92, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(t.hairline, lineWidth: 0.5)
                            }
                        Text(opt.label)
                            .font(TahoeFont.body(12, weight: on ? .bold : .semibold))
                            .foregroundStyle(on ? t.accent : t.fg2)
                    }
                    .padding(6)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(on ? t.accentAlpha(t.dark ? 0.16 : 0.08) : .clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(on ? t.accentAlpha(0.7) : t.hairline, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ThemeSwatch: View {
    var dark: Bool
    var body: some View {
        ZStack {
            (dark ? LinearGradient(colors: [
                Color(.sRGB, red: 10.0/255, green: 12.0/255, blue: 18.0/255),
                Color(.sRGB, red: 4.0/255,  green: 5.0/255,  blue: 10.0/255),
            ], startPoint: .top, endPoint: .bottom)
              : LinearGradient(colors: [
                Color(.sRGB, red: 244.0/255, green: 247.0/255, blue: 251.0/255),
                Color(.sRGB, red: 230.0/255, green: 235.0/255, blue: 243.0/255),
            ], startPoint: .top, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(dark ? Color.white.opacity(0.10) : Color.white.opacity(0.85))
                    .frame(height: 14)
                Capsule().fill(dark ? Color.white.opacity(0.55) : Color(.sRGB, white: 15.0/255, opacity: 0.55))
                    .frame(width: 36, height: 4)
                Capsule().fill((dark ? Color.white.opacity(0.55) : Color(.sRGB, white: 15.0/255, opacity: 0.55)).opacity(0.5))
                    .frame(width: 56, height: 4)
                Spacer(minLength: 0)
            }
            .padding(8)
        }
    }
}

private struct SurfaceSwatch: View {
    @Environment(\.tahoe) private var t
    var glass: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: [
                t.dark ? Color(.sRGB, red: 10.0/255, green: 12.0/255, blue: 18.0/255)
                       : Color(.sRGB, red: 238.0/255, green: 242.0/255, blue: 248.0/255),
                t.dark ? Color(.sRGB, red: 4.0/255, green: 5.0/255, blue: 10.0/255)
                       : Color(.sRGB, red: 221.0/255, green: 227.0/255, blue: 236.0/255),
            ], startPoint: .top, endPoint: .bottom)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(glass ? AnyShapeStyle(.regularMaterial)
                            : AnyShapeStyle(t.surfaceSolid))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(glass ? Color.white.opacity(0.4) : t.hairline, lineWidth: 0.5)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }
}

private struct WallSwatch: View {
    @Environment(\.tahoe) private var t
    var name: TahoeWallpaper

    var body: some View {
        // Quick inline gradient swatch based on the wallpaper kind (lightweight stand-in for TahoeWallpaperView).
        switch name {
        case .aurora:
            ZStack {
                LinearGradient(colors: [
                    t.dark ? Color(.sRGB, red: 6.0/255, green: 8.0/255, blue: 13.0/255)
                           : Color(.sRGB, red: 244.0/255, green: 247.0/255, blue: 251.0/255),
                    t.dark ? Color(.sRGB, red: 4.0/255, green: 3.0/255, blue: 10.0/255)
                           : Color(.sRGB, red: 238.0/255, green: 242.0/255, blue: 248.0/255),
                ], startPoint: .top, endPoint: .bottom)
                Ellipse().fill(OKLCH(l: 0.78, c: 0.16, h: 220).color.opacity(t.dark ? 0.45 : 0.55))
                    .frame(width: 60, height: 50).offset(x: -22, y: -14).blur(radius: 14)
                Ellipse().fill(OKLCH(l: 0.78, c: 0.16, h: 320).color.opacity(t.dark ? 0.35 : 0.45))
                    .frame(width: 50, height: 40).offset(x: 26, y: 16).blur(radius: 14)
            }
        case .graphite:
            LinearGradient(colors: [
                t.dark ? Color(.sRGB, white: 31.0/255) : Color.white,
                t.dark ? Color(.sRGB, white: 8.0/255)  : Color(.sRGB, white: 214.0/255),
            ], startPoint: .top, endPoint: .bottom)
        default:
            (t.dark ? Color.black : Color.white)
        }
    }
}

// MARK: - AccentPicker

private struct AccentPicker: View {
    @Environment(\.tahoe) private var t
    @Binding var value: TahoeAccent

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TahoeAccent.allCases) { a in
                let on = a == value
                Button { value = a } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(LinearGradient(colors: [a.glow.color, a.base.color, a.deep.color],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 32, height: 32)
                            .overlay {
                                Circle().stroke(on ? Color.white.opacity(0.001) : a.base.color(opacity: 0.5), lineWidth: 0.5)
                            }
                            .background {
                                if on {
                                    Circle()
                                        .stroke(t.dark ? Color.black : Color.white, lineWidth: 2)
                                        .padding(-2)
                                    Circle()
                                        .stroke(a.base.color, lineWidth: 2)
                                        .padding(-4)
                                }
                            }
                            .shadow(color: a.base.color(opacity: 0.5), radius: on ? 8 : 0, x: 0, y: 4)
                        Text(a.displayName)
                            .font(TahoeFont.body(11, weight: on ? .bold : .medium))
                            .foregroundStyle(on ? t.fg : t.fg3)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Providers

struct ProviderPreferenceRows: View {
    @Environment(\.tahoe) private var t
    let client: AgentControlClient?
    var runtime: AppRuntime?
    @StateObject private var localStore = ProviderDefaultsStore()
    @State private var snapshot: ProviderDefaultsSnapshot = .empty
    @State private var catalog: ModelCatalog = .bundled
    @State private var enabledByProviderId: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ChatV2Store.defaultChatVendorOrder, id: \.self) { vendor in
                ProviderPreferenceRow(
                    vendor: vendor,
                    isEnabled: enabledBinding(for: vendor),
                    snapshot: snapshot,
                    catalog: catalog,
                    onSelectModel: { entry in update(vendor: vendor, model: entry.id) },
                    onOpenModelMenu: { Task { await refreshCatalogIfAllowed(for: vendor) } }
                )
                if vendor != ChatV2Store.defaultChatVendorOrder.last {
                    TahoeHair()
                }
            }
        }
        .task { await refreshAll() }
    }

    private func refreshAll() async {
        refreshEnabledState()
        if let client {
            await client.refreshProviderDefaults()
            snapshot = client.providerDefaults
        } else {
            localStore.refresh()
            snapshot = localStore.snapshot
        }
        await refreshCatalogIfNeeded()
    }

    private func refreshEnabledState() {
        enabledByProviderId = Dictionary(
            uniqueKeysWithValues: ChatV2Store.defaultChatVendorOrder.map { vendor in
                let id = providerEnablementId(for: vendor)
                return (id, ProviderEnablement.isEnabled(id))
            }
        )
    }

    private func enabledBinding(for vendor: ChatVendor) -> Binding<Bool> {
        let id = providerEnablementId(for: vendor)
        return Binding(
            get: { enabledByProviderId[id] ?? ProviderEnablement.isEnabled(id) },
            set: { newValue in
                enabledByProviderId[id] = newValue
                if let runtime {
                    runtime.setProviderEnabled(id, newValue)
                } else {
                    ProviderEnablement.setEnabled(id, newValue)
                    Task { await invalidateProviderCaches(for: id) }
                }
                if newValue {
                    Task { await refreshCatalogIfAllowed(for: vendor) }
                    // Enabling Claude seeds Continuum's own usage token from
                    // Claude Code's keychain item (one Always-Allow prompt).
                    // Without this the live 5h/weekly gauge reads an empty
                    // token after a fresh install / re-signed build (the
                    // keychain ACL + prefs domain are per-signature) and shows
                    // 0% / "resets in —". Replaces the separate Authenticate
                    // button — turning the provider on IS the authenticate.
                    if id == "claude" {
                        // Seed the token, then force an immediate Claude poll.
                        // setProviderEnabled already started the poller, but it
                        // polled once with an empty token (0%); without this
                        // kick the gauge stays 0% until the next interval.
                        let claudeModel = runtime?.claudeModel
                        Self.seedClaudeTokenFromClaudeCode { claudeModel?.forcePoll() }
                    }
                }
            }
        )
    }

    /// Imports Claude Code's OAuth token into Continuum's own Keychain entry
    /// so the live usage gauge has a token to poll with. Reads Claude Code's
    /// third-party item with user interaction (macOS prompts once → Always
    /// Allow), mirrors it via `PastedAnthropicTokenProvider`, and opts the
    /// user into launch auto-refresh so it stays seeded across rotations.
    private static func seedClaudeTokenFromClaudeCode(onSeeded: @escaping @MainActor () -> Void = {}) {
        Task.detached(priority: .userInitiated) {
            guard let token = KeychainTokenProvider(allowsUserInteraction: true).currentAccessToken,
                  !token.isEmpty else { return }
            let ok = PastedAnthropicTokenProvider.shared().setToken(token)
            UserDefaults.standard.set(true, forKey: "clawdmeter.claude.autoImportFromClaudeCode")
            guard ok else { return }
            await MainActor.run { onSeeded() }
        }
    }

    private func providerEnablementId(for vendor: ChatVendor) -> String {
        vendor.backingProvider.rawValue
    }

    private func refreshCatalogIfNeeded() async {
        guard ProviderEnablement.isEnabled("cursor") || ProviderEnablement.isEnabled("opencode") else {
            catalog = .bundled
            return
        }
        await refreshCatalog()
    }

    private func refreshCatalogIfAllowed(for vendor: ChatVendor) async {
        let id = providerEnablementId(for: vendor)
        guard id == "cursor" || id == "opencode" else { return }
        guard ProviderEnablement.isEnabled(id) else { return }
        await refreshCatalog()
    }

    private func refreshCatalog() async {
        if let client {
            await client.refreshModelCatalog()
            catalog = client.modelCatalog
        } else {
            var next = ModelCatalog.bundled
            if ProviderEnablement.isEnabled("cursor") {
                next = next.replacingCursor(await CursorModelProbe.shared.currentModels())
            }
            if ProviderEnablement.isEnabled("opencode") {
                next = next.replacingOpenRouter(await OpenRouterModelProbe.shared.currentModels())
            }
            catalog = next
        }
    }

    private func invalidateProviderCaches(for id: String) async {
        await ChatProviderProbe.shared.invalidate()
        if id == "cursor" {
            await CursorModelProbe.shared.invalidate()
        } else if id == "opencode" {
            await OpenRouterModelProbe.shared.invalidate()
        }
    }

    private func update(vendor: ChatVendor, model: String) {
        Task {
            let normalizedEffort = ProviderModelPickerSupport.normalizedEffort(
                snapshot.effort(for: vendor),
                vendor: vendor,
                modelId: model,
                catalog: catalog
            )
            if let client {
                if let updated = await client.updateProviderDefault(
                    vendor: vendor,
                    model: model,
                    effort: normalizedEffort,
                    clearEffort: normalizedEffort == nil
                ) {
                    snapshot = updated
                }
            } else {
                snapshot = localStore.setDefault(
                    for: vendor,
                    model: model,
                    effort: normalizedEffort,
                    clearEffort: normalizedEffort == nil,
                    catalog: catalog
                )
            }
        }
    }
}

private struct ProviderPreferenceRow: View {
    @Environment(\.tahoe) private var t
    let vendor: ChatVendor
    @Binding var isEnabled: Bool
    let snapshot: ProviderDefaultsSnapshot
    let catalog: ModelCatalog
    let onSelectModel: (ModelCatalogEntry) -> Void
    let onOpenModelMenu: () -> Void

    private var selectedModelId: String? {
        snapshot.modelId(for: vendor, catalog: catalog)
    }

    private var selectedEntry: ModelCatalogEntry? {
        guard let selectedModelId else { return nil }
        return vendor.models(in: catalog).first { $0.id == selectedModelId || $0.cliAlias == selectedModelId }
    }

    private var providerId: String {
        vendor.backingProvider.rawValue
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TahoeProviderGlyph(provider: vendor.backingProvider.tahoeProvider, size: 28)
            Text(vendor.displayName)
                .font(TahoeFont.body(13.5, weight: .semibold))
                .foregroundStyle(t.fg)
            Spacer(minLength: 12)
            TahoeToggleView(on: $isEnabled)
                .help(isEnabled ? "Turn \(vendor.displayName) off" : "Turn \(vendor.displayName) on")
                .accessibilityIdentifier("settings.provider.\(providerId).enabled")
            modelMenu
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.provider.\(providerId)")
    }

    private var modelMenu: some View {
        Menu {
            let sections = ProviderModelPickerSupport.sections(for: vendor, catalog: catalog, query: "")
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        Button {
                            onSelectModel(entry)
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
        .simultaneousGesture(TapGesture().onEnded { onOpenModelMenu() })
        .accessibilityIdentifier("settings.provider.\(providerId).model")
    }
}

// MARK: - Full Disk Access opt-in (one-time)

/// One-time affordance that replaces the recurring macOS "access data from
/// other apps" prompt with a single, durable grant. Deep-links to System
/// Settings → Privacy & Security → Full Disk Access. Continuum's Release build
/// runs without the App Sandbox (#230), so FDA durably stops the prompt for the
/// shipped app (FDA overrides app-data container protection for non-sandboxed
/// apps). Shown only while a cross-app provider is enabled AND an FDA-gated read
/// currently fails — it auto-hides once access is granted.
private struct FullDiskAccessBanner: View {
    @Environment(\.tahoe) private var t

    /// FDA pane deep-link; NSWorkspace.open follows x-apple.systempreferences.
    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func shouldShow() -> Bool {
        let crossApp = ["codex", "gemini", "opencode"].contains { ProviderEnablement.isEnabled($0) }
            || ProviderEnablement.usageDataAccessGranted
        return crossApp && !hasFullDiskAccess()
    }

    /// Probe a path that genuinely requires FDA (NOT ~/.codex — that's the
    /// user's own home, readable without it). Only an explicit permission
    /// denial counts as "missing"; a not-found probe file (no Safari history)
    /// counts as "has access" so we don't nag on machines that lack the file.
    private static func hasFullDiskAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist")
        do { _ = try Data(contentsOf: probe); return true }
        catch let e as NSError {
            return !(e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError)
        }
    }

    var body: some View {
        SettingsCard(title: "Full Disk Access",
                     sub: "Stop the repeated “access data from other apps” prompt.") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 24))
                    .foregroundStyle(t.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grant once, never asked again")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text("Continuum reads your usage from other coding tools (Codex, Gemini/Antigravity, OpenCode). Full Disk Access lets it do that without macOS prompting every few minutes.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    NSWorkspace.shared.open(Self.settingsURL)
                } label: {
                    Text("Open Settings")
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
                .help("Opens System Settings → Privacy & Security → Full Disk Access. Add Continuum and toggle it on.")
            }
        }
    }
}
