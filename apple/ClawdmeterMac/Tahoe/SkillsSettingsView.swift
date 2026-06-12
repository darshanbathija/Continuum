import SwiftUI
import AppKit
import ClawdmeterShared

// MARK: - Plugin store

struct SkillPluginRecord: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var rootPath: String
    var sourceURL: String?

    init(id: String, title: String, rootPath: String, sourceURL: String? = nil) {
        self.id = id
        self.title = title
        self.rootPath = rootPath
        self.sourceURL = sourceURL
    }
}

enum SkillPluginStore {
    private static let key = "clawdmeter.skills.customPlugins"

    static func load() -> [SkillPluginRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([SkillPluginRecord].self, from: data)
        else { return [] }
        return records
    }

    static func save(_ records: [SkillPluginRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func customPluginRoots() -> [(id: String, root: URL)] {
        load().compactMap { record in
            let expanded = NSString(string: record.rootPath).expandingTildeInPath
            return (record.id, URL(fileURLWithPath: expanded, isDirectory: true))
        }
    }
}

// MARK: - Plugin groups

struct SkillPluginGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let isBuiltIn: Bool
    let isDisabled: Bool

    func matches(_ command: PaletteCommand) -> Bool {
        switch id {
        case "gstack":
            return command.source == .gstack
        case "claude":
            return command.source == .claudeGlobal || command.source == .claudeProject
        case "codex":
            return command.source == .codexBuiltin
        default:
            if case .customPlugin(let pluginID) = command.source {
                return pluginID == id
            }
            return false
        }
    }

    static func builtInGroups() -> [SkillPluginGroup] {
        [
            SkillPluginGroup(
                id: "gstack",
                title: "G stack",
                subtitle: "~/.agents/skills/gstack",
                isBuiltIn: true,
                isDisabled: false
            ),
            SkillPluginGroup(
                id: "codex",
                title: "Codex",
                subtitle: "Built-in slash commands",
                isBuiltIn: true,
                isDisabled: false
            ),
            SkillPluginGroup(
                id: "claude",
                title: "Claude Code",
                subtitle: "~/.claude/skills",
                isBuiltIn: true,
                isDisabled: !ProviderEnablement.isEnabled(AgentKind.claude)
            ),
        ]
    }

    static func allGroups() -> [SkillPluginGroup] {
        let custom = SkillPluginStore.load().map {
            SkillPluginGroup(
                id: $0.id,
                title: $0.title,
                subtitle: $0.rootPath,
                isBuiltIn: false,
                isDisabled: false
            )
        }
        return builtInGroups() + custom
    }
}

// MARK: - Settings view

struct SkillsSettingsView: View {
    @Environment(\.tahoe) private var t
    @ObservedObject private var catalog = SkillCatalog.shared

    @State private var groups: [SkillPluginGroup] = SkillPluginGroup.allGroups()
    @State private var selectedGroupID: String = "gstack"
    @State private var selectedSkillID: String?
    @State private var skillSearch = ""
    @State private var isSkillsExpanded = true
    @State private var expandedSkillIDs: Set<String> = []
    @State private var detail: SkillDetail?
    @State private var isAddPluginPresented = false
    @State private var importURL = ""
    @State private var importStatus: ImportStatus = .idle
    @State private var importError: String?

    private enum ImportStatus {
        case idle
        case importing
    }

    private var selectedGroup: SkillPluginGroup? {
        groups.first { $0.id == selectedGroupID }
    }

    private var filteredSkills: [PaletteCommand] {
        guard let group = selectedGroup else { return [] }
        let pool = catalog.commands.filter { group.matches($0) }
        let needle = skillSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return pool }
        return pool.filter {
            $0.label.lowercased().contains(needle) || $0.description.lowercased().contains(needle)
        }
    }

    var body: some View {
        settingsPanel(
            title: "Skills",
            subtitle: "Browse skill plugins, search commands, and read their instructions."
        ) {
            HStack(alignment: .top, spacing: 16) {
                pluginSidebar
                    .frame(width: 200)
                TahoeHair(vertical: true)
                skillsListPane
                    .frame(width: 240)
                TahoeHair(vertical: true)
                skillDetailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 480)
        }
        .onAppear {
            reloadGroups()
            catalog.refreshIfStale()
            selectFirstSkillIfNeeded()
        }
        .onChange(of: catalog.commands) { _, _ in
            selectFirstSkillIfNeeded()
        }
        .onChange(of: selectedGroupID) { _, _ in
            selectedSkillID = nil
            detail = nil
            selectFirstSkillIfNeeded()
        }
        .onChange(of: selectedSkillID) { _, newValue in
            loadDetail(for: newValue)
        }
        .sheet(isPresented: $isAddPluginPresented) {
            addPluginSheet
        }
    }

    private func settingsPanel<Content: View>(
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

    // MARK: Left — plugin groups

    private var pluginSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("PLUGINS")
                    .font(TahoeFont.body(10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(t.fg4)
                Spacer()
                Button(action: { isAddPluginPresented = true }) {
                    HStack(spacing: 5) {
                        TahoeIcon("plus", size: 9, weight: .bold)
                        Text("Add plugin")
                            .font(TahoeFont.body(11, weight: .semibold))
                    }
                    .foregroundStyle(t.fg2)
                }
                .buttonStyle(.plain)
                .help("Add a custom skills plugin folder")
                .accessibilityIdentifier("settings.skills.addPlugin")
            }
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        pluginRow(group)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.trailing, 4)
    }

    private func pluginRow(_ group: SkillPluginGroup) -> some View {
        let isSelected = group.id == selectedGroupID
        return Button {
            selectedGroupID = group.id
        } label: {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(TahoeFont.body(13, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? t.fg : t.fg2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if group.isDisabled {
                    Text("Disabled")
                        .font(TahoeFont.body(10, weight: .bold))
                        .foregroundStyle(t.fg3)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(t.glassTintHi.opacity(0.5), in: Capsule(style: .continuous))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                        .fill(t.segmentActiveFill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.skills.plugin.\(group.id)")
    }

    // MARK: Middle — skills list

    private var skillsListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("COMMANDS")
                    .font(TahoeFont.body(10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(t.fg4)
                Spacer()
                Button(action: { catalog.refreshIfStale() }) {
                    HStack(spacing: 5) {
                        TahoeIcon("refresh", size: 10)
                        Text("Refresh")
                            .font(TahoeFont.body(11, weight: .semibold))
                    }
                    .foregroundStyle(t.fg2)
                }
                .buttonStyle(.plain)
                .help("Refresh skills")
            }
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(t.fg3)
                TextField("Search skills", text: $skillSearch)
                    .textFieldStyle(.plain)
            }
            .font(TahoeFont.body(12))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(t.hair2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, 10)

            Button {
                withAnimation(.easeOut(duration: 0.15)) { isSkillsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    TahoeIcon(isSkillsExpanded ? "chevD" : "chevR", size: 9)
                    Text("Personal skills")
                        .font(TahoeFont.mono(10, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(t.fg3)
                    Spacer()
                    Text("\(filteredSkills.count)")
                        .font(TahoeFont.mono(10, weight: .semibold))
                        .foregroundStyle(t.fg4)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isSkillsExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if filteredSkills.isEmpty {
                            Text(emptySkillsMessage)
                                .font(TahoeFont.body(12))
                                .foregroundStyle(t.fg3)
                                .padding(.vertical, 16)
                        } else {
                            ForEach(filteredSkills) { skill in
                                skillRow(skill)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var emptySkillsMessage: String {
        guard let group = selectedGroup else { return "Select a plugin." }
        if group.isDisabled {
            return "Enable \(group.title) in Providers to use its skills."
        }
        return "No skills found for \(group.title)."
    }

    private func skillRow(_ skill: PaletteCommand) -> some View {
        let isSelected = selectedSkillID == skill.id
        let isExpanded = expandedSkillIDs.contains(skill.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedSkillID = skill.id
                if skill.filePath != nil {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if isExpanded {
                            expandedSkillIDs.remove(skill.id)
                        } else {
                            expandedSkillIDs.insert(skill.id)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if skill.filePath != nil {
                        TahoeIcon(isExpanded ? "chevD" : "chevR", size: 8)
                            .foregroundStyle(t.fg4)
                    } else {
                        Color.clear.frame(width: 10)
                    }
                    Text(skill.label)
                        .font(TahoeFont.body(13, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? t.fg : t.fg2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                            .fill(t.segmentActiveFill)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.skills.skill.\(skill.id)")

            if isExpanded, let detail, detail.command.id == skill.id {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(detail.children) { child in
                        HStack(spacing: 6) {
                            TahoeIcon(child.isDirectory ? "folder" : "doc", size: 9)
                                .foregroundStyle(t.fg4)
                            Text(child.name)
                                .font(TahoeFont.mono(10.5))
                                .foregroundStyle(t.fg3)
                        }
                        .padding(.leading, 30)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: Right — detail

    private var skillDetailPane: some View {
        Group {
            if let detail {
                SkillDetailPane(detail: detail)
            } else {
                VStack(spacing: 8) {
                    TahoeIcon("doc", size: 28)
                        .foregroundStyle(t.fg4)
                    Text("Select a skill")
                        .font(TahoeFont.body(14, weight: .semibold))
                        .foregroundStyle(t.fg3)
                    Text("Choose a plugin on the left, then pick a skill to read its instructions.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg4)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12)
    }

    private var addPluginSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add skills plugin")
                .font(TahoeFont.body(16, weight: .bold))
            Text("Paste a GitHub link or skills.sh URL. Continuum clones the repo into ~/.clawdmeter/skills/plugins/ and indexes its SKILL.md files.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .fixedSize(horizontal: false, vertical: true)

            TextField("GitHub or skills.sh URL", text: $importURL, prompt: Text("https://skills.sh/vercel-labs/agent-skills"))
                .textFieldStyle(.roundedBorder)
                .disabled(importStatus == .importing)

            if let parsed = parsedImportSource {
                HStack(spacing: 6) {
                    TahoeIcon("check", size: 10, weight: .bold)
                        .foregroundStyle(t.accent)
                    Text(parsed.title)
                        .font(TahoeFont.body(11.5, weight: .semibold))
                        .foregroundStyle(t.fg2)
                }
            }

            if importStatus == .importing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Cloning and indexing skills…")
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                }
            }

            if let importError {
                Text(importError)
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { closeImportSheet() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(importStatus == .importing)
                Button(importStatus == .importing ? "Importing…" : "Import") {
                    Task { await importPluginFromURL() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsedImportSource == nil || importStatus == .importing)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            if let pasted = NSPasteboard.general.string(forType: .string),
               looksLikeImportURL(pasted),
               importURL.isEmpty {
                importURL = pasted
            }
        }
    }

    private var parsedImportSource: SkillPluginImportSource? {
        try? SkillPluginImporter.parse(importURL)
    }

    private func looksLikeImportURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("github.com")
            || trimmed.contains("skills.sh")
            || trimmed.contains("/")
            || trimmed.contains("@")
    }

    private func closeImportSheet() {
        isAddPluginPresented = false
        importURL = ""
        importError = nil
        importStatus = .idle
    }

    // MARK: Actions

    private func reloadGroups() {
        groups = SkillPluginGroup.allGroups()
        if !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = groups.first?.id ?? "gstack"
        }
    }

    private func selectFirstSkillIfNeeded() {
        guard selectedSkillID == nil, let first = filteredSkills.first else { return }
        selectedSkillID = first.id
    }

    private func loadDetail(for skillID: String?) {
        guard let skillID,
              let command = catalog.commands.first(where: { $0.id == skillID })
        else {
            detail = nil
            return
        }
        Task {
            let loaded = await Task.detached(priority: .utility) {
                SkillCatalog.loadDetail(for: command)
            }.value
            await MainActor.run {
                if selectedSkillID == skillID {
                    detail = loaded
                }
            }
        }
    }

    private func importPluginFromURL() async {
        importError = nil
        importStatus = .importing
        do {
            let record = try await SkillPluginImporter.importPlugin(from: importURL)
            var records = SkillPluginStore.load()
            records.append(record)
            SkillPluginStore.save(records)
            closeImportSheet()
            reloadGroups()
            selectedGroupID = record.id
            catalog.invalidateCache()
            catalog.refreshIfStale()
        } catch {
            importError = error.localizedDescription
            importStatus = .idle
        }
    }
}

// MARK: - Detail pane

private struct SkillDetailPane: View {
    @Environment(\.tahoe) private var t
    let detail: SkillDetail
    // Parse once per pane instance; the parent recreates the pane when
    // `detail` changes, so toggling the source view doesn't re-parse.
    private let document: MarkdownDocumentContent

    @State private var showSource = false

    init(detail: SkillDetail) {
        self.detail = detail
        self.document = MarkdownDocumentContent.parse(detail.bodyMarkdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader
            TahoeHair().padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !detail.command.description.isEmpty {
                        Text(detail.command.description)
                            .font(TahoeFont.body(12))
                            .foregroundStyle(t.fg3)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    if showSource {
                        Text(detail.bodyMarkdown)
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(t.fg)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        SkillMarkdownBody(document: document)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(detail.command.label)
                    .font(TahoeFont.body(13.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                Spacer()
                Button {
                    showSource.toggle()
                } label: {
                    HStack(spacing: 5) {
                        TahoeIcon(showSource ? "doc" : "code", size: 10)
                        Text(showSource ? "Rendered" : "Source")
                            .font(TahoeFont.body(11, weight: .semibold))
                    }
                    .foregroundStyle(t.fg2)
                }
                .buttonStyle(.plain)
                .help(showSource ? "Show rendered view" : "Show source")
            }

            HStack(spacing: 16) {
                metadataItem(label: "Added by", value: addedByLabel)
                if let mtime = detail.lastModified {
                    metadataItem(label: "Last updated", value: formattedDate(mtime))
                }
                metadataItem(label: "Trigger", value: triggerLabel)
            }
        }
        .padding(.vertical, 4)
    }

    private func metadataItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(TahoeFont.body(10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(t.fg4)
            Text(value)
                .font(TahoeFont.body(12, weight: .medium))
                .foregroundStyle(t.fg2)
        }
    }

    private var addedByLabel: String {
        switch detail.command.source {
        case .codexBuiltin: return "Built-in"
        default: return "You"
        }
    }

    private var triggerLabel: String {
        detail.command.source == .codexBuiltin ? "Slash command" : "Slash command + auto"
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct SkillMarkdownBody: View {
    @Environment(\.tahoe) private var t
    let document: MarkdownDocumentContent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockView(_ block: MarkdownDocumentBlock) -> AnyView {
        switch block {
        case .heading(let level, let text):
            return AnyView(Text(text)
                .font(headingFont(level))
                .foregroundStyle(t.fg)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 6 : 2))
        case .paragraph(let text):
            return AnyView(Text(text)
                .font(TahoeFont.body(13.5))
                .lineSpacing(5)
                .foregroundStyle(t.fg)
                .textSelection(.enabled))
        case .list(let ordered, let items):
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(TahoeFont.body(12, weight: .semibold))
                            .foregroundStyle(t.fg3)
                            .frame(width: 20, alignment: .trailing)
                        Text(item.text)
                            .font(TahoeFont.body(13))
                            .foregroundStyle(t.fg)
                            .textSelection(.enabled)
                    }
                }
            })
        case .codeBlock(_, let code):
            return AnyView(Text(code)
                .font(TahoeFont.mono(11))
                .foregroundStyle(t.fg)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(t.hair2, in: RoundedRectangle(cornerRadius: 6)))
        case .blockQuote(let blocks):
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                        blockView(child)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(t.accent.opacity(0.45)).frame(width: 3)
                }
            )
        case .thematicBreak:
            return AnyView(Rectangle().fill(t.hairline).frame(height: 1))
        case .unsupported(let message):
            return AnyView(Text(message)
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return TahoeFont.body(22, weight: .bold)
        case 2: return TahoeFont.body(17, weight: .semibold)
        default: return TahoeFont.body(15, weight: .semibold)
        }
    }
}
