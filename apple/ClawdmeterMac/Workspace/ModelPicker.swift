import SwiftUI
import ClawdmeterShared

/// Per-session model picker — chip-styled menu that mirrors Conductor's
/// model selector. Grouped by provider (Claude Code, Codex) with version
/// pills (1M, New, Fast).
///
/// Sessions v2 D11+ from the CEO/Eng review. Lives in the composer header
/// of `SessionWorkspaceView`, next to `ModePicker` + `EffortDial`.
struct ModelPicker: View {
    /// Currently selected model id; nil = CLI default. The picker shows
    /// the catalog entry's `displayName` when found, else the raw id.
    let selectedModelId: String?
    /// Catalog the picker reads from. Mac ships the bundled catalog; the
    /// daemon can override via `GET /models` when the iOS client fetches.
    let catalog: ModelCatalog
    /// Filter — only show models for this agent type, or for a custom provider
    /// when `customProviderId` is set. Switching agent mid-session is a
    /// different flow (D13 overlay).
    let agent: AgentKind
    var customProviderId: String? = nil
    /// Called when the user picks a different model id. The caller is
    /// responsible for actually swapping the session (D13 overlay flow).
    let onSelect: (ModelCatalogEntry) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            // Header showing the current provider.
            Section(providerSectionTitle) {
                ForEach(modelsForAgent) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        modelRow(entry: entry, isSelected: entry.id == selectedModelId)
                    }
                    .accessibilityLabel(rowAccessibilityLabel(entry: entry))
                    .accessibilityAddTraits(entry.id == selectedModelId ? [.isButton, .isSelected] : .isButton)
                }
            }
        } label: {
            chipLabel
        }
        .menuStyle(.borderlessButton)
        .help("Switch model — Cmd+Opt+M")
        .accessibilityLabel("Model picker")
        .accessibilityValue(chipAccessibilityValue)
        .accessibilityHint("Click to choose a different model.")
    }

    private var chipAccessibilityValue: String {
        guard let entry = selectedEntry else { return "default model" }
        var parts = [entry.displayName]
        if let cw = entry.contextWindow, cw >= 1_000_000 {
            parts.append("\(cw / 1_000_000) million context window")
        }
        if let badge = entry.badge {
            parts.append(badge.lowercased())
        }
        return parts.joined(separator: ", ")
    }

    private func rowAccessibilityLabel(entry: ModelCatalogEntry) -> String {
        var parts = [entry.displayName]
        if let cw = entry.contextWindow, cw >= 1_000_000 {
            parts.append("\(cw / 1_000_000) million context")
        }
        if let badge = entry.badge {
            parts.append(badge.lowercased())
        }
        if let recommended = entry.recommendedFor {
            parts.append("recommended for \(recommended.lowercased())")
        }
        return parts.joined(separator: ", ")
    }

    private var modelsForAgent: [ModelCatalogEntry] {
        if let customProviderId,
           let summary = catalog.customProviders.first(where: { $0.id == customProviderId }) {
            return summary.entries
        }
        switch agent {
        case .claude: return catalog.claude
        case .codex:  return catalog.codex
        case .gemini: return catalog.gemini
        case .opencode:
            var merged = catalog.opencode
            if ProviderEnablement.isEnabled("openrouter") {
                merged.append(contentsOf: catalog.openrouter)
            }
            return merged
        case .cursor: return catalog.cursor
        case .grok: return catalog.grok
        case .unknown: return []  // X3: no catalog slice for forward-compat unknown
        }
    }

    private var providerSectionTitle: String {
        if let customProviderId,
           let summary = catalog.customProviders.first(where: { $0.id == customProviderId }) {
            return summary.label
        }
        switch agent {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .unknown: return "Other agent"  // X3
        }
    }

    private var selectedEntry: ModelCatalogEntry? {
        guard let id = selectedModelId else { return nil }
        return modelsForAgent.first(where: { $0.id == id })
    }

    @ViewBuilder
    private var chipLabel: some View {
        HStack(spacing: SessionsV2Theme.Spacing.xs) {
            Text(selectedEntry?.displayName ?? "Default")
                .font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(SessionsV2Theme.textSecondary)
        }
        .padding(.horizontal, SessionsV2Theme.Spacing.sm)
        .padding(.vertical, SessionsV2Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: SessionsV2Theme.Radius.chip)
                .fill(Color.secondary.opacity(0.10))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func modelRow(entry: ModelCatalogEntry, isSelected: Bool) -> some View {
        HStack {
            if isSelected {
                Image(systemName: "checkmark")
            }
            Text(entry.displayName)
            if let badge = entry.badge {
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(badgeBackground(badge), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
            }
            if let recommended = entry.recommendedFor {
                Text("· \(recommended)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func badgeBackground(_ badge: String) -> Color {
        switch badge {
        case "1M":   return SessionsV2Theme.accent
        case "New":  return SessionsV2Theme.codexBlue
        case "Fast": return SessionsV2Theme.success.opacity(0.8)
        default:     return Color.secondary
        }
    }
}
