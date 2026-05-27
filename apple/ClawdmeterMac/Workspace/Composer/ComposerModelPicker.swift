// ComposerModelPicker.swift
// v0.29.8 — in-composer model picker (replaces the per-vendor menu popover).
//
// Layout (matches reference mockup):
//   ┌──┬───────────────────────────────────┐
//   │★ │ 🔍 Search models…                 │
//   │∗ │ ☆ GPT-5.5             ⌘1          │
//   │◉ │ ☆ GPT-5.4             ⌘2  ← active│
//   │∎ │ ☆ GPT-5.4-Mini        ⌘3          │
//   │…│ …                                  │
//   ├──┴───────────────────────────────────┤
//   │ ◉ GPT-5.4   Medium · Normal   Build  │
//   └──────────────────────────────────────┘
//
// Left rail: 32×32 provider icons + a "Starred" pseudo-entry at the top.
// Active rail row gets a 3pt blue stripe on its trailing edge.
//
// Right pane: focused search field + scrollable list of model rows.
// Search filters across ALL providers; rail dims providers with no matches.
// ⌘1…⌘9 selects the Nth model row when search is EMPTY (i.e. when the
// list is scoped to the active rail entry). When the user is searching,
// shortcuts are suppressed so they aren't bound to surprising cross-
// provider rows.
//
// Bottom bar (v1): visual-only summary of the current selection (model,
// effort, mode, permission). No chevrons rendered — those would be
// affordance lies until v0.29.9 wires real mutation here. Today, mutation
// continues to flow through the existing composer chips outside this
// picker.
//
// Deferred to v0.29.9 (intentionally out of scope, called out in PR body):
//   • Bottom-bar chips become interactive (drive effort/mode/permission)
//   • Per-vendor clock-overlay "recent" badges on rail cells
//   • "Cursor variants" rail sub-entries
//   • A real Settings → Providers "enabled" toggle that the picker reads

#if canImport(SwiftUI)
import SwiftUI
import ClawdmeterShared

@MainActor
public struct ComposerModelPicker: View {
    // MARK: - Public API

    /// Vendor that should be active in the rail when the picker opens.
    public let initialVendor: ChatVendor

    /// Vendors the picker should expose in the rail. Caller filters by any
    /// Settings → Providers gate. Defaults to all `ChatVendor.allCases`.
    public let enabledVendors: [ChatVendor]

    /// Model catalog. Defaults to the bundled catalog.
    public let catalog: ModelCatalog

    @ObservedObject public var store: ChatV2Store
    @ObservedObject public var defaultsStore: ProviderDefaultsStore

    public var onClose: () -> Void

    /// Optional sink for callers (Code composer) that own their own
    /// model/effort state outside ChatV2Store. When set, `select(...)`
    /// fires this in addition to the regular ChatV2Store write so the
    /// host can mirror the change into the running session via
    /// SessionConfigChanger / ComposerStore. Chat-side leaves this nil
    /// since `selectedModelByVendor` already drives the Chat composer.
    public var onSelectModel: ((ChatVendor, String, ReasoningEffort?) -> Void)? = nil

    // MARK: - Theme

    @Environment(\.tahoe) private var t

    // MARK: - State

    @State private var activeRail: RailKey
    @State private var searchQuery: String = ""
    @State private var focusedRowIndex: Int? = nil
    @FocusState private var searchFocused: Bool

    public init(
        initialVendor: ChatVendor,
        store: ChatV2Store,
        defaultsStore: ProviderDefaultsStore,
        catalog: ModelCatalog = .bundled,
        enabledVendors: [ChatVendor] = ChatVendor.allCases,
        onClose: @escaping () -> Void,
        onSelectModel: ((ChatVendor, String, ReasoningEffort?) -> Void)? = nil
    ) {
        self.initialVendor = initialVendor
        self.store = store
        self.defaultsStore = defaultsStore
        self.catalog = catalog
        self.enabledVendors = enabledVendors
        self.onClose = onClose
        self.onSelectModel = onSelectModel
        self._activeRail = State(initialValue: .vendor(initialVendor))
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 0) {
            rail
            // Plain Rectangle hairline avoids `Divider().overlay(t.hairline)`
            // double-painting against SwiftUI Divider's built-in color.
            Rectangle()
                .fill(t.hairline)
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
            rightPane
        }
        .frame(width: 520, height: 440)
        .background(t.surfaceSolid)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        )
        // Elevated-panel shadow so the picker reads as floating above the
        // chat workspace, not cut into it.
        .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 12)
        .onAppear {
            searchFocused = true
            focusedRowIndex = currentlySelectedRowIndex()
        }
        .onChange(of: searchQuery) { _ in
            focusedRowIndex = visibleEntries.isEmpty ? nil : 0
        }
        .onChange(of: activeRail) { _ in
            focusedRowIndex = currentlySelectedRowIndex()
        }
    }

    // MARK: - Left rail

    private var rail: some View {
        VStack(spacing: 6) {
            ForEach(railEntries) { entry in
                railCell(entry: entry)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .frame(width: 52)
    }

    @ViewBuilder
    private func railCell(entry: RailEntry) -> some View {
        let active = (entry.key == activeRail)
        let dimmed = isRailDimmed(entry.key)

        Button {
            activeRail = entry.key
        } label: {
            ZStack {
                // No active-state cell fill — the mockup uses stripe-only.
                // Adding a fill flattens the brand glyph behind it.
                // The dim treatment applies ONLY to the glyph, not the
                // whole cell, so the accent stripe stays at full opacity
                // and continues to anchor "you are here" during search.
                railGlyph(entry: entry)
                    .frame(width: 32, height: 32)
                    .opacity(dimmed ? 0.38 : 1.0)
            }
            .frame(width: 44, height: 40)
            .overlay(alignment: .trailing) {
                if active {
                    Rectangle()
                        .fill(t.accent)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.tooltip)
    }

    @ViewBuilder
    private func railGlyph(entry: RailEntry) -> some View {
        switch entry.key {
        case .favorites:
            // Solid SF star — TahoeIcon's map does not yet cover "star.fill".
            Image(systemName: "star.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(t.fg2)
        case .vendor(let vendor):
            TahoeProviderGlyph(provider: vendor.backingProvider.tahoeProvider, size: 22)
        }
    }

    // MARK: - Right pane

    private var rightPane: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            modelList

            Rectangle()
                .fill(t.hairline)
                .frame(height: 0.5)
            bottomBar
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TahoeIcon("search", size: 12)
                .foregroundStyle(t.fg4)
            TextField("Search models…", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(TahoeFont.body(12.5))
                .foregroundStyle(t.fg)
                .onSubmit { confirmFocusedSelection() }
                // Arrow-key navigation has to live ON the focused TextField:
                // `.onKeyPress` only fires on the focused view, and the search
                // field holds focus through the entire picker session. Placed
                // on a sibling ScrollView, these never fired.
                .onKeyPress(.downArrow) {
                    moveFocus(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveFocus(by: -1)
                    return .handled
                }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    searchFocused = true
                } label: {
                    TahoeIcon("x", size: 11)
                        .foregroundStyle(t.fg4)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(searchFocused ? t.accent.opacity(0.7) : t.hairline, lineWidth: searchFocused ? 1.5 : 0.5)
        )
    }

    private var modelList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(visibleEntries.enumerated()), id: \.element.compositeId) { index, entry in
                    modelRow(entry: entry, index: index)
                }
                if visibleEntries.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        // Arrow keys + Return are bound on the focused TextField in
        // `searchField`. SwiftUI's `.onKeyPress` only fires on the
        // first-responder view, so attaching them here on the ScrollView
        // never fired in practice (round-2 design critique P0).
    }

    @ViewBuilder
    private func modelRow(entry: VisibleRowEntry, index: Int) -> some View {
        let isSelected = isCurrentlySelected(entry: entry)
        let isFav = defaultsStore.isFavorite(modelId: entry.model.id, vendor: entry.vendor)
        // ⌘N is suppressed during search to avoid binding shortcuts to a
        // cross-provider list (would be surprising for the user).
        let shortcut: Character? = (searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && index < 9)
            ? Character("\(index + 1)") : nil
        let isFocused = (focusedRowIndex == index)

        Button {
            select(entry: entry)
        } label: {
            HStack(spacing: 10) {
                Button {
                    defaultsStore.toggleFavoriteModel(entry.model.id, for: entry.vendor)
                } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isFav ? t.accent : t.fg4)
                }
                .buttonStyle(.plain)
                .help(isFav ? "Unstar" : "Star")

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.model.displayName)
                        .font(TahoeFont.body(12.5, weight: .semibold))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        TahoeProviderGlyph(provider: entry.vendor.backingProvider.tahoeProvider, size: 12)
                        Text(entry.vendor.displayName)
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg4)
                    }
                }

                Spacer(minLength: 8)

                if let shortcut {
                    shortcutBadge(digit: shortcut)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isFocused ? t.accent.opacity(0.55)
                        : (isSelected ? t.accent.opacity(0.30) : Color.clear),
                        lineWidth: isFocused ? 1.0 : 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
    }

    @ViewBuilder
    private func shortcutBadge(digit: Character) -> some View {
        // Single Text run so ⌘ and digit share one baseline + tracking
        // (round-2 design critique flagged uneven kerning when these
        // were two adjacent Text views in an HStack).
        Text("⌘\(digit)")
            .font(TahoeFont.mono(11))
            .tracking(0.5)
            .foregroundStyle(t.fg4)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.5)
            )
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            TahoeIcon("search", size: 20).foregroundStyle(t.fg4)
            Text(emptyStateMessage)
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var emptyStateMessage: String {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return "No models match \u{201C}\(trimmed)\u{201D}"
        }
        switch activeRail {
        case .favorites:
            return "No starred models yet.\nTap ☆ on any row to add it here."
        case .vendor(let vendor):
            return "No models available for \(vendor.displayName)."
        }
    }

    // MARK: - Bottom bar (visual-only chips, no chevrons; v0.29.9 wires interaction)

    private var bottomBar: some View {
        HStack(spacing: 6) {
            bottomChip {
                selectedModelChipContent
            }
            bottomChip {
                effortChipContent
            }
            bottomChip {
                modeChipContent
            }
            bottomChip {
                permissionChipContent
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func bottomChip<C: View>(@ViewBuilder content: () -> C) -> some View {
        // Height 26 (up from 24) puts the chip in the macOS comfortable
        // hit-target range and matches the cadence of the existing
        // composer chips in MacChatV2View (32pt) better when interaction
        // lands in v0.29.9.
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.5)
            )
    }

    /// Bottom-bar preview state. When a row is focused, the model + vendor
    /// chip mirrors that focused row (so the bar previews what ⌘1 / Return
    /// would pick). When nothing is focused, falls back to the active rail
    /// entry's vendor + its saved default model.
    private struct BottomBarPreview {
        let vendor: ChatVendor?
        let modelDisplay: String
    }

    private var bottomBarPreview: BottomBarPreview {
        if let idx = focusedRowIndex, visibleEntries.indices.contains(idx) {
            let row = visibleEntries[idx]
            return BottomBarPreview(vendor: row.vendor, modelDisplay: row.model.displayName)
        }
        let fallbackVendor: ChatVendor? = {
            switch activeRail {
            case .favorites: return initialVendor
            case .vendor(let v): return v
            }
        }()
        let modelDisplay: String = {
            guard let v = fallbackVendor,
                  let id = defaultsStore.modelId(for: v, catalog: catalog),
                  let entry = catalog.entry(forId: id) else {
                return "Select model"
            }
            return entry.displayName
        }()
        return BottomBarPreview(vendor: fallbackVendor, modelDisplay: modelDisplay)
    }

    private var selectedModelChipContent: some View {
        let preview = bottomBarPreview
        return HStack(spacing: 5) {
            if let vendor = preview.vendor {
                TahoeProviderGlyph(provider: vendor.backingProvider.tahoeProvider, size: 12)
            }
            Text(preview.modelDisplay)
                .font(TahoeFont.body(11.5, weight: .semibold))
                .foregroundStyle(t.fg2)
        }
    }

    private var effortChipContent: some View {
        let vendor = bottomBarPreview.vendor
        let effort = vendor.flatMap { defaultsStore.effort(for: $0, catalog: catalog) }
        let label = effort.map { $0.displayLabel } ?? "Default"
        return Text(label)
            .font(TahoeFont.body(11))
            .foregroundStyle(t.fg3)
    }

    private var modeChipContent: some View {
        HStack(spacing: 5) {
            Image(systemName: "hammer")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(t.fg3)
            Text("Build")
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg3)
        }
    }

    private var permissionChipContent: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(t.fg3)
            Text("Full access")
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg3)
        }
    }

    // MARK: - Keyboard nav helpers

    private func moveFocus(by delta: Int) {
        guard !visibleEntries.isEmpty else {
            focusedRowIndex = nil
            return
        }
        let cur = focusedRowIndex ?? -1
        let next = max(0, min(visibleEntries.count - 1, cur + delta))
        focusedRowIndex = next
    }

    private func confirmFocusedSelection() {
        guard let idx = focusedRowIndex,
              visibleEntries.indices.contains(idx) else { return }
        select(entry: visibleEntries[idx])
    }

    private func currentlySelectedRowIndex() -> Int? {
        guard !visibleEntries.isEmpty else { return nil }
        if let i = visibleEntries.firstIndex(where: { isCurrentlySelected(entry: $0) }) {
            return i
        }
        return 0
    }

    // MARK: - Selection

    private func select(entry: VisibleRowEntry) {
        let vendor = entry.vendor
        // Persist the new default. Normalize effort so a model that
        // doesn't support an effort level clears any stale effort that
        // was carried over from the previously-selected model.
        let normalizedEffort = ProviderModelPickerSupport.normalizedEffort(
            defaultsStore.effort(for: vendor, catalog: catalog),
            vendor: vendor,
            modelId: entry.model.id,
            catalog: catalog
        )
        store.selectedModelByVendor[vendor] = entry.model.id
        defaultsStore.setDefault(
            for: vendor,
            model: entry.model.id,
            effort: normalizedEffort,
            clearEffort: normalizedEffort == nil,
            catalog: catalog
        )
        onSelectModel?(vendor, entry.model.id, normalizedEffort)
        onClose()
    }

    private func isCurrentlySelected(entry: VisibleRowEntry) -> Bool {
        let active = defaultsStore.modelId(for: entry.vendor, catalog: catalog)
            ?? store.selectedModelByVendor[entry.vendor]
        return active == entry.model.id
    }

    // MARK: - Data: rail + filtered model list

    private var railEntries: [RailEntry] {
        var entries: [RailEntry] = [
            RailEntry(key: .favorites, tooltip: "Starred / recent")
        ]
        for vendor in enabledVendors {
            entries.append(
                RailEntry(key: .vendor(vendor), tooltip: vendor.displayName)
            )
        }
        return entries
    }

    /// Visible model rows for the right pane. When the search query is
    /// non-empty we expand to ALL providers (search is cross-provider).
    /// When empty, we show the active rail entry's models.
    private var visibleEntries: [VisibleRowEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return entries(for: activeRail)
        }
        var seen = Set<String>()
        var out: [VisibleRowEntry] = []
        for vendor in enabledVendors {
            for model in ProviderModelPickerSupport.entries(for: vendor, catalog: catalog, query: trimmed) {
                let row = VisibleRowEntry(vendor: vendor, model: model)
                if seen.insert(row.compositeId).inserted {
                    out.append(row)
                }
            }
        }
        return out
    }

    private func entries(for key: RailKey) -> [VisibleRowEntry] {
        switch key {
        case .favorites:
            var seen = Set<String>()
            var out: [VisibleRowEntry] = []
            for vendor in enabledVendors {
                for id in defaultsStore.favoriteModelIds(for: vendor) {
                    guard let model = catalog.entry(forId: id) else { continue }
                    let row = VisibleRowEntry(vendor: vendor, model: model)
                    if seen.insert(row.compositeId).inserted {
                        out.append(row)
                    }
                }
            }
            return out
        case .vendor(let vendor):
            return ProviderModelPickerSupport
                .entries(for: vendor, catalog: catalog, query: "")
                .map { VisibleRowEntry(vendor: vendor, model: $0) }
        }
    }

    private func isRailDimmed(_ key: RailKey) -> Bool {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch key {
        case .favorites:
            return enabledVendors.allSatisfy { vendor in
                defaultsStore.favoriteModelIds(for: vendor).isEmpty
            }
        case .vendor(let vendor):
            return ProviderModelPickerSupport
                .entries(for: vendor, catalog: catalog, query: trimmed)
                .isEmpty
        }
    }
}

// MARK: - Rail keys + row records

public enum RailKey: Hashable {
    case favorites
    case vendor(ChatVendor)
}

private struct RailEntry: Identifiable {
    let key: RailKey
    let tooltip: String
    var id: RailKey { key }
}

/// Vendor + model pair carried through the visible list. Composite id
/// ("\(vendor.rawValue)|\(model.id)") makes ForEach stable even when the
/// same model id appears under multiple vendors (e.g. OpenRouter-mirrored
/// frontier models).
struct VisibleRowEntry: Hashable {
    let vendor: ChatVendor
    let model: ModelCatalogEntry
    var compositeId: String { "\(vendor.rawValue)|\(model.id)" }
}

// MARK: - Effort display fallback

private extension ReasoningEffort {
    var displayLabel: String {
        switch self {
        case .minimal: return "Minimal"
        case .low:     return "Low"
        case .medium:  return "Medium"
        case .high:    return "High"
        default:
            // .xhigh / .max / any future cases fall back to capitalized raw
            // so the bottom bar still reads sensibly.
            return rawValue.capitalized
        }
    }
}

#endif
