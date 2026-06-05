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
        SettingsCard(title: "Quota & sync",
                     sub: "Behavior that affects the menu-bar agent and the paired iPhone.") {
            SettingsRow(label: "Auto-revive 5h timer",
                        hint: "Sends a no-op every ~4 hours so you don't lose your rolling session window. Applies to every provider that supports it.") {
                TahoeToggleView(on: autoReviveBinding)
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Sync with iPhone",
                        hint: "Live gauges sync through the pairing service when a phone is paired. No separate toggle exists yet.") {
                SettingsUnavailableBadge()
            }
            TahoeHair().padding(.vertical, 14)
            SettingsRow(label: "Notify at 90%",
                        hint: "Notification routing is not implemented in this settings surface yet.") {
                SettingsUnavailableBadge()
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

private struct SettingsUnavailableBadge: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        Text("Unavailable")
            .font(TahoeFont.body(11, weight: .bold))
            .foregroundStyle(t.fg3)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background { Capsule().fill(t.glassTintHi) }
            .overlay { Capsule().stroke(t.hairline, lineWidth: 0.5) }
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

/// Settings → Providers → OpenCode row.
///
/// v0.29.9 simplification: Clawdmeter no longer maintains its own
/// "paste an API key" affordance. The source of truth is the user's
/// `opencode` CLI auth (`opencode auth login`), which writes to
/// `~/.local/share/opencode/auth.json`. This row reads that file via
/// `OpencodeAuthFile.enumeratedProviders()` and surfaces what the CLI
/// already knows about:
///
///   - Auth populated → "Using opencode CLI auth — N upstream providers
///     available" + a list of provider chips. No edit affordance; the
///     CLI owns the lifecycle.
///   - Auth empty / file missing → "Auth via CLI" button that opens
///     Terminal pre-typed with `opencode auth login` (with the same
///     AppleScript+clipboard fallback the Claude row uses).
///   - Binary missing → same "Auth via CLI" button, but the shell
///     command also covers installing the CLI first.
private struct OpencodeProviderRow: View {
    @Environment(\.tahoe) private var t
    @State private var providers: [OpencodeAuthFile.UpstreamProvider] = []
    @State private var hasBinary: Bool = false
    @State private var loaded: Bool = false

    private var isSignedIn: Bool { !providers.isEmpty }

    private var detailLine: String {
        if !loaded {
            return "Probing the opencode CLI and ~/.local/share/opencode/auth.json…"
        }
        if isSignedIn {
            return "Using opencode CLI auth — \(providers.count) upstream provider\(providers.count == 1 ? "" : "s") available."
        }
        if !hasBinary {
            return "OpenCode CLI not detected. Click Auth via CLI to install it and run `opencode auth login`."
        }
        return "No upstream providers yet. Click Auth via CLI to run `opencode auth login` in Terminal."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TahoeProviderGlyph(provider: .opencode, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                // v0.29.11: title→pill spacing is 8 to match Claude Code
                // (line ~1788) + Cursor SDK (line ~1639) rows. v0.29.10
                // shipped spacing:6 which the design critique flagged as
                // a 2pt visible-parity bug between adjacent rows.
                HStack(spacing: 8) {
                    Text("OpenCode")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg)
                    // v0.29.10: status pill mirrors Claude Code + Cursor SDK
                    // rows. Verifier surfaced that the OpenCode row was the
                    // only authenticated provider without an at-a-glance
                    // state indicator — the row's subtitle had the info
                    // but you had to read 8 words to know whether OpenCode
                    // was ready or needed sign-in. The pill fixes that.
                    statePill
                }
                Text(detailLine)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                if isSignedIn {
                    providerChips
                }
            }
            Spacer(minLength: 12)
            trailingControl
        }
        .task { await refreshState() }
    }

    @ViewBuilder
    private var statePill: some View {
        let (label, color): (String, Color) = {
            if !loaded { return ("Checking…", t.fg4) }
            if isSignedIn { return ("Ready", Color.green) }
            if !hasBinary { return ("Not installed", Color.orange) }
            return ("Sign-in pending", Color.yellow)
        }()
        Text(label)
            .font(TahoeFont.body(10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background { Capsule().fill(color.opacity(0.15)) }
            .overlay { Capsule().stroke(color.opacity(0.35), lineWidth: 0.5) }
    }

    private var providerChips: some View {
        // Wrap chips in an HStack — the provider count is small (≤10)
        // and the Settings column is fixed width, so a single line of
        // chips fits without a flow layout. If new providers push the
        // count higher this should be revisited.
        // v0.29.11 design fixes:
        //   - tracking 0.2 → 0.3 to match the adjacent status pill
        //     (same font size, same row — was a visible typographic
        //     mismatch).
        //   - fill/stroke pulled from t.hair2/t.hairline tokens instead
        //     of t.fg.opacity(…) literals. In light mode `t.fg` is
        //     near-black so the alpha math was producing an unintended
        //     fill; the hairline tokens are exactly the values the
        //     theme designed for this.
        //   - dropped `.padding(.top, 2)` so the VStack(spacing: 4) parent
        //     keeps its 4pt vertical rhythm with the detail line above.
        HStack(spacing: 6) {
            ForEach(providers, id: \.id) { provider in
                Text(provider.displayName)
                    .font(TahoeFont.body(10, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(t.fg2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background { Capsule().fill(t.hair2) }
                    .overlay { Capsule().stroke(t.hairline, lineWidth: 0.5) }
                    .help("\(provider.displayName) · \(provider.type)")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isSignedIn {
            Button {
                openTerminalForOpencodeAuth(installIfMissing: !hasBinary)
                scheduleReprobe()
            } label: {
                Text("Re-auth")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
            .help("Open Terminal and run `opencode auth login` to add or replace a provider.")
        } else {
            Button {
                openTerminalForOpencodeAuth(installIfMissing: !hasBinary)
                scheduleReprobe()
            } label: {
                Text("Auth via CLI")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
            .help(hasBinary
                ? "Open Terminal and run `opencode auth login`."
                : "Open Terminal to install opencode and run `opencode auth login`.")
        }
    }

    // MARK: - Actions

    private func refreshState() async {
        await OpencodeProcessManager.shared.reprobe()
        let enumerated = await OpencodeAuthFile.shared.enumeratedProviders()
        await MainActor.run {
            providers = enumerated
            hasBinary = OpencodeProcessManager.shared.binaryPath != nil
            loaded = true
        }
    }

    private func scheduleReprobe() {
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await refreshState()
        }
    }

    /// AppleScript a Terminal window running `opencode auth login`.
    /// Mirrors `ClaudeCLIProviderRow.openTerminalForClaudeAuth` —
    /// including the v0.29.4 fallback that copies the command to the
    /// clipboard and surfaces an alert if the AppleScript bridge is
    /// denied (sandboxed builds without apple-events entitlement).
    private func openTerminalForOpencodeAuth(installIfMissing: Bool) {
        let command = opencodeAuthCommand(installIfMissing: installIfMissing)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)
        if result == nil || error != nil {
            let detail = (error?["NSAppleScriptErrorMessage"] as? String)
                ?? (error?["NSAppleScriptErrorBriefMessage"] as? String)
                ?? "unknown error"
            NSLog("[Clawdmeter] opencode auth AppleScript failed: \(detail)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            let alert = NSAlert()
            alert.messageText = "Open Terminal manually"
            alert.informativeText = """
            Couldn't drive Terminal from Continuum (\(detail)).

            The opencode auth command has been copied to your clipboard. Open Terminal yourself and paste it (⌘V) to finish authentication.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Terminal")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                if let terminal = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.apple.Terminal"
                ) {
                    NSWorkspace.shared.open(terminal)
                }
            }
        }
    }

    private func opencodeAuthCommand(installIfMissing: Bool) -> String {
        if !installIfMissing {
            return "opencode auth login"
        }
        let installSteps = """
        if command -v opencode >/dev/null 2>&1; then
          opencode auth login
        elif command -v brew >/dev/null 2>&1; then
          brew install sst/tap/opencode && opencode auth login
        elif command -v npm >/dev/null 2>&1; then
          npm i -g opencode-ai && opencode auth login
        else
          echo "Install opencode first: see https://opencode.ai, then run: opencode auth login"
        fi
        """
        return "/bin/zsh -lc \(shellQuotedOpencode(installSteps))"
    }

    private func shellQuotedOpencode(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

// MARK: - Codex SDK row


// MARK: - Cursor SDK provider row

private struct CursorSDKProviderRow: View {
    @Environment(\.tahoe) private var t
    @State private var state: CursorModelProbeState?
    @State private var hasKeychainToken: Bool = false
    @State private var isRefreshing: Bool = false
    /// v0.29.34: reactive mirror of the Cursor opt-in. The status probe
    /// (cursor-agent shell + cursor-access-token keychain read) must not run
    /// for a disabled provider — that was firing a keychain prompt just from
    /// this row appearing. Re-probes when the user enables Cursor.
    @AppStorage("clawdmeter.provider.cursor.enabled") private var cursorEnabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TahoeProviderGlyph(provider: .cursor, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Cursor SDK")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg)
                    statePill
                }
                Text(detailLine)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                if let binaryPath = state?.binaryPath {
                    Text("Binary: \(binaryPath)")
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            actionButton
        }
        .task { await refresh() }
        .onChange(of: cursorEnabled) { _, on in
            if on { Task { await refresh() } }
        }
    }

    @ViewBuilder
    private var statePill: some View {
        let (label, color): (String, Color) = {
            if !cursorEnabled { return ("Disabled", t.fg4) }
            if isRefreshing || state == nil { return ("Checking…", t.fg4) }
            guard let state else { return ("Checking…", t.fg4) }
            if state.binaryPath == nil { return ("Not installed", Color.orange) }
            if state.authenticated || hasKeychainToken { return ("Ready", Color.green) }
            return ("Sign-in pending", Color.yellow)
        }()
        Text(label)
            .font(TahoeFont.body(10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background { Capsule().fill(color.opacity(0.15)) }
            .overlay { Capsule().stroke(color.opacity(0.35), lineWidth: 0.5) }
    }

    private var detailLine: String {
        if !cursorEnabled { return "Enable Cursor in Providers above to check sign-in and model access." }
        guard let state else { return "Probing cursor-agent auth and model access…" }
        if state.binaryPath == nil {
            return "Cursor Agent CLI not found. Install cursor-agent so Clawdmeter can start and resume Cursor-backed sessions."
        }
        if state.authenticated || hasKeychainToken {
            let count = max(0, state.models.count)
            return count > 1
                ? "Signed in via cursor-agent. \(count) account models are available in the picker."
                : "Signed in via cursor-agent. Model access will be discovered when Cursor reports account models."
        }
        return state.reason ?? "Run `cursor-agent login` to connect Cursor auth."
    }

    @ViewBuilder
    private var actionButton: some View {
        if isRefreshing {
            ProgressView().controlSize(.small)
        } else if state?.binaryPath == nil {
            Button {
                if let url = URL(string: "https://docs.cursor.com/en/cli") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Install docs")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
        } else if state?.authenticated == true || hasKeychainToken {
            Button {
                Task { await refresh(force: true) }
            } label: {
                Text("Refresh")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                openTerminalRunningCursorLogin()
            } label: {
                Text("Sign in")
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
            .help("Open Terminal and run `cursor-agent login`.")
        }
    }

    private func refresh(force: Bool = false) async {
        // v0.29.34: don't shell cursor-agent or read the cursor-access-token
        // keychain until the user has enabled Cursor. Probing a disabled
        // provider was firing a keychain prompt just from this row appearing.
        guard ProviderEnablement.isEnabled("cursor") else {
            state = nil
            hasKeychainToken = false
            isRefreshing = false
            return
        }
        isRefreshing = true
        if force {
            await CursorModelProbe.shared.invalidate()
        }
        let nextState = await CursorModelProbe.shared.currentState()
        let token = await Task.detached(priority: .utility) {
            CursorTokenProvider().hasToken
        }.value
        state = nextState
        hasKeychainToken = token
        isRefreshing = false
    }

    private func openTerminalRunningCursorLogin() {
        let command = state?.binaryPath ?? "cursor-agent"
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped) login"
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        _ = appleScript?.executeAndReturnError(&error)
    }
}

// MARK: - Claude Code CLI provider row (v0.22.23)

/// Mirrors `OpencodeProviderRow`'s shape — install + auth status for the
/// Claude Code CLI. Uses the same real-home binary resolver as session
/// spawning and Continuum's own imported Keychain token. Claude Code's
/// third-party Keychain item is only read when the user clicks Authenticate.
private struct ClaudeCLIProviderRow: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var claudeModel: AppModel
    @State private var probe: ProbeState = .pending
    @State private var version: String?
    @State private var binaryPath: String?
    @State private var hasUsedClaude: Bool = false
    @State private var hasClawdmeterToken: Bool = false
    @State private var isAuthenticating: Bool = false
    @State private var authMessage: String?
    @State private var authFailed: Bool = false
    @State private var pastedTokenDraft: String = ""
    /// Mirrors `clawdmeter.codex.sdkMode`'s shape. Default OFF; flips ON
    /// automatically the first time the user successfully clicks
    /// Authenticate so subsequent launches re-import silently. When ON,
    /// `AppRuntime.init` reads Claude Code's third-party Keychain item at
    /// every launch and mirrors the latest refresh token into Continuum's
    /// own shared Keychain entry. macOS may show a one-time password
    /// prompt the first time the app accesses that Keychain item; once
    /// "Always Allow" is granted, subsequent launches are silent.
    @AppStorage("clawdmeter.claude.autoImportFromClaudeCode") private var autoImportAtLaunch: Bool = false
    /// v0.29.34: reactive mirror of the Claude opt-in. The status probe
    /// (`ClaudeCLIProbe.run()` → `PastedAnthropicTokenProvider.hasToken`) must
    /// not read Continuum's Anthropic-token keychain entry for a disabled
    /// provider — that was firing a keychain prompt on row appearance.
    @AppStorage("clawdmeter.provider.claude.enabled") private var claudeEnabled: Bool = false

    enum ProbeState: Equatable {
        case pending
        case notInstalled
        case authenticatedNoCLI
        case installedNeedsLogin
        case ready
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TahoeProviderGlyph(provider: .claude, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Claude Code")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg)
                    statePill
                }
                Text(detailLine)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                if let authMessage {
                    Text(authMessage)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(authFailed ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsPasteFallback {
                    HStack(spacing: 8) {
                        SecureField("Paste token or Claude Code JSON", text: $pastedTokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                        Button {
                            savePastedClaudeToken()
                        } label: {
                            Text("Save token")
                                .font(TahoeFont.body(12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(pastedTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let binaryPath, probe == .ready || probe == .installedNeedsLogin {
                    Text("Binary: \(binaryPath)\(version.map { "  ·  \($0)" } ?? "")")
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg2)
                }
                HStack(spacing: 8) {
                    Toggle(isOn: $autoImportAtLaunch) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-import from Claude Code at launch")
                                .font(TahoeFont.body(12, weight: .semibold))
                                .foregroundStyle(t.fg)
                            Text("Mirrors Claude Code's refreshed token into Continuum's Keychain every launch. macOS may ask for your password the first time; click \"Always Allow\".")
                                .font(TahoeFont.body(11))
                                .foregroundStyle(t.fg3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            Spacer()
            actionButton
        }
        .task { await refreshProbe() }
        .onChange(of: claudeEnabled) { _, on in
            if on { Task { await refreshProbe() } }
        }
    }

    private var showsPasteFallback: Bool {
        probe == .installedNeedsLogin || authFailed || claudeModel.needsReauth
    }

    @ViewBuilder
    private var statePill: some View {
        let (label, color): (String, Color) = {
            if !claudeEnabled { return ("Disabled", t.fg4) }
            switch probe {
            case .pending:           return ("Checking…", t.fg4)
            case .notInstalled:      return ("Not installed", Color.orange)
            case .authenticatedNoCLI: return ("Auth found", Color.yellow)
            case .installedNeedsLogin: return ("Sign-in pending", Color.yellow)
            case .ready:             return ("Ready", Color.green)
            }
        }()
        Text(label)
            .font(TahoeFont.body(10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background { Capsule().fill(color.opacity(0.15)) }
            .overlay { Capsule().stroke(color.opacity(0.35), lineWidth: 0.5) }
    }

    private var detailLine: String {
        if !claudeEnabled { return "Enable Claude in Providers above to check status and import auth." }
        switch probe {
        case .pending:
            return "Probing the `claude` binary, Continuum Keychain token, and activity history…"
        case .notInstalled:
            return "Claude Code CLI is not installed. Install it and run `claude /login`, then authenticate here once."
        case .authenticatedNoCLI:
            return "Continuum has Claude auth, but the `claude` CLI binary is not on the standard paths. Install or expose the CLI before starting sessions."
        case .installedNeedsLogin:
            return hasUsedClaude
                ? "Claude Code activity exists, but Continuum has not imported auth yet. Click Authenticate to read Claude Code credentials once."
                : "CLI installed, but Continuum has no Claude auth. Run `claude /login`, then click Authenticate once."
        case .ready:
            if claudeModel.needsReauth {
                return "Stored Claude auth was rejected. Click Refresh auth to import the latest Claude Code token."
            }
            return "Installed and authenticated via Continuum Keychain. Sessions still run with the `claude` CLI."
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isAuthenticating {
            ProgressView().controlSize(.small)
        } else {
            switch probe {
            case .pending:
                EmptyView()
            case .notInstalled:
                Button {
                    openTerminalForClaudeAuth(installIfMissing: true)
                    scheduleAuthReprobe()
                } label: {
                    Text("Install / login")
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
                .help("Open Terminal to install Claude Code if needed, then run `claude /login`.")
            case .authenticatedNoCLI:
                Button {
                    openTerminalForClaudeAuth(installIfMissing: true)
                    scheduleAuthReprobe()
                } label: {
                    Text("Install CLI")
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
                .help("Open Terminal to install or expose the Claude Code CLI.")
            case .installedNeedsLogin:
                Button {
                    authenticateFromClaudeCode()
                } label: {
                    Text("Authenticate")
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
                .help("Read Claude Code's Keychain token once and store it in Continuum's Keychain.")
            case .ready:
                Button {
                    authenticateFromClaudeCode()
                } label: {
                    Text("Refresh auth")
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
                .help("Explicitly import the latest Claude Code token into Continuum's Keychain.")
            }
        }
    }

    /// Probe is cheap — single file existence + one `claude --version`
    /// invocation. Run off the main actor to avoid janking the
    /// Settings tab on first appear.
    private func refreshProbe() async {
        // v0.29.34: skip the probe (which reads Continuum's Anthropic-token
        // keychain entry via ClaudeCLIProbe) until Claude is enabled, so a
        // disabled provider never triggers a keychain prompt on appearance.
        guard ProviderEnablement.isEnabled("claude") else {
            self.hasClawdmeterToken = false
            self.probe = .pending
            return
        }
        let detected = await Task.detached(priority: .userInitiated) {
            ClaudeCLIProbe.run()
        }.value
        self.binaryPath = detected.binaryPath
        self.version = detected.version
        self.hasUsedClaude = detected.hasActivity
        self.hasClawdmeterToken = detected.hasClawdmeterToken
        if detected.binaryPath == nil && detected.hasClawdmeterToken {
            self.probe = .authenticatedNoCLI
        } else if detected.binaryPath == nil {
            self.probe = .notInstalled
        } else if detected.hasClawdmeterToken {
            self.probe = .ready
        } else {
            self.probe = .installedNeedsLogin
        }
    }

    private func authenticateFromClaudeCode() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        authMessage = nil
        authFailed = false

        Task { @MainActor in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let token = KeychainTokenProvider(allowsUserInteraction: true).currentAccessToken else {
                    return "No Claude Code token was available. Run `claude /login`, then click Authenticate again."
                }
                guard PastedAnthropicTokenProvider.shared().setToken(token) else {
                    return "Claude Code auth was found, but Continuum could not save it to its own Keychain entry."
                }
                return nil
            }.value

            isAuthenticating = false
            if let failure {
                authFailed = true
                authMessage = failure
                return
            }

            authFailed = false
            authMessage = "Authenticated. Continuum will use its own Keychain copy from now on."
            // Successful read of Claude Code's Keychain means macOS granted
            // (or the user "Always Allowed") access; opt the user into
            // silent auto-import at every launch from here on. They can
            // flip the toggle back off in Settings if they prefer manual.
            autoImportAtLaunch = true
            await refreshProbe()
            claudeModel.forcePoll()
        }
    }

    private func savePastedClaudeToken() {
        guard !isAuthenticating else { return }
        let extracted = Self.extractAccessToken(from: pastedTokenDraft)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeValidToken(extracted) else {
            authFailed = true
            authMessage = "Couldn't find a Claude OAuth token. Paste the bare `sk-ant-…` value or Claude Code's Keychain JSON."
            return
        }
        // Snapshot the draft we're saving so a race-against-paste doesn't
        // wipe a fresh token the user typed while this save was in flight.
        let draftAtSubmit = pastedTokenDraft
        isAuthenticating = true
        authMessage = nil
        authFailed = false

        Task { @MainActor in
            let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
                PastedAnthropicTokenProvider.shared().setToken(extracted)
            }.value
            isAuthenticating = false
            guard saved else {
                authFailed = true
                authMessage = "Continuum could not save the token to its own Keychain entry."
                return
            }
            if pastedTokenDraft == draftAtSubmit {
                pastedTokenDraft = ""
            }
            authFailed = false
            authMessage = "Authenticated. Continuum will use its own Keychain copy from now on."
            await refreshProbe()
            claudeModel.forcePoll()
        }
    }

    private static func looksLikeValidToken(_ token: String) -> Bool {
        token.hasPrefix("sk-ant-") && token.count <= 4096 && !token.contains("\n")
    }

    private static func extractAccessToken(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sk-ant-") { return trimmed }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let token = findAccessToken(in: obj) {
            return token
        }
        return trimmed
    }

    private static func findAccessToken(in obj: Any) -> String? {
        if let s = obj as? String, s.hasPrefix("sk-ant-") { return s }
        if let dict = obj as? [String: Any] {
            if let s = dict["accessToken"] as? String, s.hasPrefix("sk-ant-") {
                return s
            }
            if let s = dict["access_token"] as? String, s.hasPrefix("sk-ant-") {
                return s
            }
            for value in dict.values {
                if let nested = findAccessToken(in: value) { return nested }
            }
        }
        if let arr = obj as? [Any] {
            for value in arr {
                if let nested = findAccessToken(in: value) { return nested }
            }
        }
        return nil
    }

    private func scheduleAuthReprobe() {
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await refreshProbe()
        }
    }

    /// AppleScript a Terminal window that runs `claude` so the user
    /// can complete the OAuth handshake inline. v0.29.4: if the
    /// AppleScript bridge is denied (sandbox without the apple-events
    /// entitlement, or the user denied the automation prompt), fall
    /// back to copying the shell command to the clipboard and showing
    /// an alert so the user can paste it into Terminal manually —
    /// previously the click was a silent no-op.
    private func openTerminalForClaudeAuth(installIfMissing: Bool) {
        let command = claudeAuthCommand(installIfMissing: installIfMissing)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)
        if result == nil || error != nil {
            // AppleScript failed — typically because the sandbox blocks
            // automation events or the user denied the prompt. Surface
            // a usable fallback instead of pretending nothing happened.
            let detail = (error?["NSAppleScriptErrorMessage"] as? String)
                ?? (error?["NSAppleScriptErrorBriefMessage"] as? String)
                ?? "unknown error"
            NSLog("[Clawdmeter] Claude auth AppleScript failed: \(detail)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            let alert = NSAlert()
            alert.messageText = "Open Terminal manually"
            alert.informativeText = """
            Couldn't drive Terminal from Continuum (\(detail)).

            The install + login command has been copied to your clipboard. Open Terminal yourself and paste it (⌘V) to finish authentication.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Terminal")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                if let terminal = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.apple.Terminal"
                ) {
                    NSWorkspace.shared.open(terminal)
                }
            }
        }
    }

    private func claudeAuthCommand(installIfMissing: Bool) -> String {
        if !installIfMissing, let binaryPath {
            return "\(shellQuoted(binaryPath)) /login"
        }
        let installSteps = """
        if command -v claude >/dev/null 2>&1; then
          claude /login
        elif command -v npm >/dev/null 2>&1; then
          npm i -g @anthropic-ai/claude-code && claude /login
        elif command -v brew >/dev/null 2>&1; then
          brew install anthropic/claude/claude && claude /login
        else
          echo "Install npm or Homebrew, then run: npm i -g @anthropic-ai/claude-code && claude /login"
        fi
        """
        return "/bin/zsh -lc \(shellQuoted(installSteps))"
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Static probe helper that walks the standard install locations,
/// runs `--version`, and counts `~/.claude/projects/` children. Kept
/// out of the View struct so it can be called off the main actor
/// without touching SwiftUI state. It only checks Continuum's own
/// Keychain entry; Claude Code's third-party item is read exclusively
/// by the explicit Authenticate button above.
private enum ClaudeCLIProbe {
    struct Result {
        let binaryPath: String?
        let version: String?
        let hasActivity: Bool
        let hasClawdmeterToken: Bool
    }

    nonisolated static func run() -> Result {
        let path = locateBinary()
        let version: String? = path.flatMap { runVersion(binary: $0) }
        let activity = projectsDirHasEntries()
        let token = PastedAnthropicTokenProvider.shared().hasToken
        return Result(binaryPath: path, version: version, hasActivity: activity, hasClawdmeterToken: token)
    }

    private nonisolated static func locateBinary() -> String? {
        ShellRunner.locateBinary("claude")
    }

    private nonisolated static func runVersion(binary: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let raw = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        } catch {
            return nil
        }
    }

    private nonisolated static func projectsDirHasEntries() -> Bool {
        let url = URL(fileURLWithPath: ClawdmeterRealHome.path())
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let kids = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return !kids.isEmpty
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
