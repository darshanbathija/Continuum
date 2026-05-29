import SwiftUI
import ClawdmeterShared

/// Display payload for the composer's right-side chips. All numbers are
/// parent-supplied — the chips + popovers stay view-pure so they work in
/// both the bound (session) and empty-state composers.
struct UsageStatusInfo: Equatable {
    let modelDisplay: String
    let effortDisplay: String?
    let contextUsedTokens: Int
    let contextLimitTokens: Int?
    let costDollar: Decimal
    let sessionPct: Int?
    let sessionResetMins: Int?
    let weeklyPct: Int?
    let weeklyResetMins: Int?
}

// MARK: - Model + Effort chip

/// Right-side composer chip that opens a Models / Effort selector.
/// Kept narrow — the context+usage data lives on its sibling chip
/// (`ContextUsageChip`) so each surface owns one concern.
struct ModelEffortChip: View {
    let info: UsageStatusInfo
    let catalog: ModelCatalog
    let agent: AgentKind
    @Binding var selectedModelId: String?
    @Binding var selectedEffort: ReasoningEffort?
    let modelSupportsEffort: Bool
    /// v0.29.31: when the rich picker's rail switches to another vendor, map
    /// that vendor back to its AgentKind so the host can align the session's
    /// agent. Lets the model picker subsume provider selection (the separate
    /// "Provider" menu chip was removed as redundant). Nil → caller doesn't
    /// track agent (agent change ignored, e.g. mid-session).
    var onSelectAgent: ((AgentKind) -> Void)? = nil

    @State private var showingPopover = false
    @State private var isHovered = false
    /// Shared favorites + per-vendor defaults backing store. Reads the
    /// same `UserDefaults` keys as the Chat picker, so a model starred
    /// in Chat shows up starred in Code and vice-versa.
    @StateObject private var providerDefaults = ProviderDefaultsStore()
    /// Throwaway ChatV2Store the rich picker writes its preview state
    /// into. We never observe it from Code (the real selection flows
    /// through `onSelectModel`), but ComposerModelPicker requires one.
    @StateObject private var pickerScratchStore = ChatV2Store()

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 6) {
                Text(summaryText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 128, maxWidth: 220, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(Color.secondary.opacity(isHovered ? 0.16 : 0.10), in: Capsule())
            .overlay(Capsule().stroke(isHovered ? Color.secondary.opacity(0.24) : Color.clear, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help("Change model or effort (⌘⌥M)")
        .accessibilityLabel("Model and effort")
        .accessibilityValue(summaryText)
        .accessibilityIdentifier("code.composer.model-effort")
        .onHover { isHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .composerOpenModelEffort)) { _ in
            showingPopover = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerCycleEffortNext)) { _ in
            cycleEffort(direction: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerCycleEffortPrevious)) { _ in
            cycleEffort(direction: -1)
        }
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            // v0.30 — Code now uses the same rich vendor-rail picker as
            // Chat. The ChatV2Store is a private scratch store; the real
            // mutation flows through `onSelectModel` which updates the
            // Code-side bindings (and, indirectly, the running session
            // via SessionConfigChanger). The simpler `ModelEffortPopover`
            // is retained as the secondary surface — held behind a small
            // "Effort" footer button below so users can still re-pick
            // effort without re-picking model.
            ComposerModelPicker(
                initialVendor: ChatVendor.migrated(from: agent) ?? .chatgpt,
                store: pickerScratchStore,
                defaultsStore: providerDefaults,
                catalog: catalog,
                onClose: { showingPopover = false },
                onSelectModel: { vendor, modelId, effort in
                    // Align the session's agent to the picked vendor (the rail
                    // is now the only provider switcher in Code), then set the
                    // specific model + effort the user chose.
                    onSelectAgent?(vendor.backingProvider)
                    selectedModelId = modelId
                    if let effort {
                        selectedEffort = effort
                    }
                }
            )
        }
    }

    private var summaryText: String {
        if let effort = info.effortDisplay, !effort.isEmpty {
            return "\(info.modelDisplay) · \(effort)"
        }
        return info.modelDisplay
    }

    private func cycleEffort(direction: Int) {
        guard modelSupportsEffort else { return }
        let values: [ReasoningEffort] = [.low, .medium, .high, .xhigh, .max]
        let currentIndex = selectedEffort.flatMap { values.firstIndex(of: $0) } ?? values.firstIndex(of: .medium) ?? 0
        let next = (currentIndex + direction + values.count) % values.count
        selectedEffort = values[next]
    }
}

// MARK: - Context + Usage chip

/// Right-side composer chip that opens the context window + plan usage
/// rows. The ring shows the active session's context-window utilisation
/// (e.g. 336.2k / 1.0M = 33%). v0.29.4: this used to be `max(context,
/// 5h, weekly)` which meant a 75%-full weekly bucket pegged the ring at
/// 75% even though the chat session was only using 33% of its window —
/// users couldn't tell at a glance how much room they had left in the
/// current model's prompt. Plan caps still live one click away in the
/// popover, where each meter has its own row.
struct ContextUsageChip: View {
    let info: UsageStatusInfo

    @State private var showingPopover = false
    @State private var isHovered = false

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 5) {
                ring
                Text(percentText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(isHovered ? 0.16 : 0.10), in: Capsule())
            .overlay(Capsule().stroke(isHovered ? Color.secondary.opacity(0.24) : Color.clear, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Context window utilisation — click for plan usage (⌘⌥C)")
        .accessibilityLabel("Context window")
        .accessibilityValue(percentText)
        .accessibilityIdentifier("code.composer.context-usage")
        .onHover { isHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .composerOpenContextUsage)) { _ in
            showingPopover = true
        }
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            ContextUsagePopover(info: info)
        }
    }

    private var percentText: String {
        let pct = Int(contextFraction * 100)
        return "\(pct)%"
    }

    @ViewBuilder
    private var ring: some View {
        let fraction = contextFraction
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(ringColor(fraction), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
    }

    private var contextFraction: CGFloat {
        // v0.29.4: context-window only. If the model's limit is unknown
        // (legacy assistant turns with no `usage` payload yet) we render
        // an empty ring rather than borrowing the plan caps — the popover
        // is the right place to see plan progress.
        guard let limit = info.contextLimitTokens, limit > 0 else { return 0 }
        return min(1.0, CGFloat(info.contextUsedTokens) / CGFloat(limit))
    }

    private func ringColor(_ fraction: CGFloat) -> Color {
        if fraction >= 0.95 { return SessionsV2Theme.danger }
        if fraction >= 0.75 { return SessionsV2Theme.warn }
        return SessionsV2Theme.accent
    }
}

// MARK: - Popovers

/// Models + Effort selector. Mirrors Claude Code's split menu.
struct ModelEffortPopover: View {
    let catalog: ModelCatalog
    let agent: AgentKind
    @Binding var selectedModelId: String?
    @Binding var selectedEffort: ReasoningEffort?
    let modelSupportsEffort: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelsSection
            Divider()
            effortSection
        }
        .padding(14)
        .frame(width: 320)
    }

    private var modelsForAgent: [ModelCatalogEntry] {
        switch agent {
        case .claude: return catalog.claude
        case .codex:  return catalog.codex
        case .gemini: return catalog.gemini
        case .opencode: return catalog.opencode
        case .cursor: return catalog.cursor
        case .unknown: return []  // X3: no catalog slice for unknown
        }
    }

    @ViewBuilder
    private var modelsSection: some View {
        Text("Models")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(modelsForAgent.enumerated()), id: \.element.id) { (index, entry) in
                modelRow(entry, shortcut: index < 9 ? "\(index + 1)" : nil)
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ entry: ModelCatalogEntry, shortcut: String?) -> some View {
        let isSelected = (selectedModelId == entry.id)
        Button(action: {
            selectedModelId = entry.id
        }) {
            HStack(spacing: 6) {
                Text(entry.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                if let badge = entry.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SessionsV2Theme.accent)
                } else if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.secondary.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var allEfforts: [ReasoningEffort] {
        [.low, .medium, .high, .xhigh, .max]
    }

    @ViewBuilder
    private var effortSection: some View {
        Text("Effort")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(allEfforts, id: \.self) { effort in
                effortRow(effort)
            }
        }
    }

    @ViewBuilder
    private func effortRow(_ effort: ReasoningEffort) -> some View {
        let isSelected = (selectedEffort == effort)
        Button(action: {
            selectedEffort = effort
        }) {
            HStack(spacing: 6) {
                Text(effortLabel(effort))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(modelSupportsEffort ? .primary : .secondary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SessionsV2Theme.accent)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.secondary.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!modelSupportsEffort)
        .help(modelSupportsEffort ? "" : "This model doesn't expose an effort dial")
    }

    private func effortLabel(_ e: ReasoningEffort) -> String {
        switch e {
        case .minimal: return "Minimal"
        case .low:     return "Low"
        case .medium:  return "Medium"
        case .high:    return "High"
        case .xhigh:   return "Extra high"
        case .max:     return "Max"
        }
    }
}

/// Context window + Session cost + Plan usage rows.
struct ContextUsagePopover: View {
    let info: UsageStatusInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let limit = info.contextLimitTokens, limit > 0 {
                progressRow(
                    label: "Context window",
                    value: contextValueText(used: info.contextUsedTokens, limit: limit),
                    fraction: min(1.0, Double(info.contextUsedTokens) / Double(limit)),
                    tint: SessionsV2Theme.accent
                )
            }
            HStack {
                Text("Session cost")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(costText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            if info.sessionPct != nil || info.weeklyPct != nil {
                Divider()
                Text("Plan usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let pct = info.sessionPct {
                progressRow(
                    label: "5-hour limit",
                    value: planValueText(pct: pct, resetMins: info.sessionResetMins),
                    fraction: Double(pct) / 100.0,
                    tint: planTint(pct: pct)
                )
            }
            if let pct = info.weeklyPct {
                progressRow(
                    label: "Weekly · all models",
                    value: planValueText(pct: pct, resetMins: info.weeklyResetMins),
                    fraction: Double(pct) / 100.0,
                    tint: planTint(pct: pct)
                )
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private func progressRow(label: String, value: String, fraction: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                Spacer()
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            QuotaPillBar(fraction: max(0, min(1, fraction)), tint: tint)
        }
    }

    private func contextValueText(used: Int, limit: Int) -> String {
        let pct = Int((Double(used) / Double(limit)) * 100)
        return "\(formatTokens(used)) / \(formatTokens(limit)) (\(pct)%)"
    }

    private func planValueText(pct: Int, resetMins: Int?) -> String {
        if let m = resetMins {
            return "\(pct)% · resets \(formatResetMins(m))"
        }
        return "\(pct)%"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return String(format: "%.1fM", m)
        }
        if n >= 1_000 {
            let k = Double(n) / 1_000
            return String(format: "%.1fk", k)
        }
        return "\(n)"
    }

    private func formatResetMins(_ mins: Int) -> String {
        if mins <= 0 { return "now" }
        let days = mins / (60 * 24)
        if days >= 1 { return "\(days)d" }
        let hours = mins / 60
        if hours >= 1 { return "\(hours)h" }
        return "\(mins)m"
    }

    private func planTint(pct: Int) -> Color {
        if pct >= 95 { return SessionsV2Theme.danger }
        if pct >= 75 { return SessionsV2Theme.warn }
        return SessionsV2Theme.accent
    }

    private var costText: String {
        let n = info.costDollar as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        if n.doubleValue < 1 {
            formatter.minimumFractionDigits = 4
            formatter.maximumFractionDigits = 4
        } else {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        }
        return formatter.string(from: n) ?? "$\(info.costDollar)"
    }
}

// MARK: - Quota pill bar

/// 6px pill bar matching DESIGN.md "Quota Meter" (lines 363–379):
/// - Capsule (pill radius 999).
/// - 180° linear gradient from `tint @ 0.85` (≈ provider.glow) to
///   `tint` (provider.base).
/// - Soft `tint @ 50%` shadow so the fill reads on translucent glass
///   backgrounds.
/// - Hairline-tinted track underneath so the empty portion stays
///   legible on both light and dark surfaces.
///
/// Replaces SwiftUI's `ProgressView(.linear)`, which renders flat
/// NSProgressIndicator chrome on macOS and ignores the tint gradient
/// the design system mandates for quota visualisation.
private struct QuotaPillBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.85), tint],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                    .shadow(color: tint.opacity(0.5), radius: 1.5, x: 0, y: 0)
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
