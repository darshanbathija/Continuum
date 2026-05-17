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

    @State private var showingPopover = false

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 6) {
                Text(summaryText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Change model or effort")
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            ModelEffortPopover(
                catalog: catalog,
                agent: agent,
                selectedModelId: $selectedModelId,
                selectedEffort: $selectedEffort,
                modelSupportsEffort: modelSupportsEffort
            )
        }
    }

    private var summaryText: String {
        if let effort = info.effortDisplay, !effort.isEmpty {
            return "\(info.modelDisplay) · \(effort)"
        }
        return info.modelDisplay
    }
}

// MARK: - Context + Usage chip

/// Right-side composer chip that opens the context window + plan usage
/// rows. The ring renders the most-saturated meter (context / 5h / weekly)
/// so the user sees the closest cap at a glance.
struct ContextUsageChip: View {
    let info: UsageStatusInfo

    @State private var showingPopover = false

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
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show context + plan usage")
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
        var pieces: [CGFloat] = []
        if let limit = info.contextLimitTokens, limit > 0 {
            pieces.append(min(1.0, CGFloat(info.contextUsedTokens) / CGFloat(limit)))
        }
        if let s = info.sessionPct {
            pieces.append(min(1.0, CGFloat(s) / 100.0))
        }
        if let w = info.weeklyPct {
            pieces.append(min(1.0, CGFloat(w) / 100.0))
        }
        return pieces.max() ?? 0
    }

    private func ringColor(_ fraction: CGFloat) -> Color {
        if fraction >= 0.95 { return .red }
        if fraction >= 0.75 { return .orange }
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
        agent == .claude ? catalog.claude : catalog.codex
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                Spacer()
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
                .tint(tint)
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
        if pct >= 95 { return .red }
        if pct >= 75 { return .orange }
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
