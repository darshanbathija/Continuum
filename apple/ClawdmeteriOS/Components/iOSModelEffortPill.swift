import SwiftUI
import ClawdmeterShared

/// Composer-bar pill on iOS that mirrors the Mac's `ModelEffortChip` —
/// shows the active model + effort in one tappable label and opens a
/// Menu with both Models and Effort sections. Replaces the standalone
/// `iOSModelPicker` + `iOSEffortDial` that used to sit in the
/// `iOSSessionControlsStrip` row above the chat.
///
/// Live Continuum sessions only.
struct iOSModelEffortPill: View {
    let agent: AgentKind
    let catalog: ModelCatalog
    @Binding var selectedModelId: String?
    @Binding var selectedEffort: ReasoningEffort?
    /// Haiku and similar models advertise `supportsEffort=false`. When
    /// the active model is one of those the Effort section greys out.
    var modelSupportsEffort: Bool {
        guard let id = selectedModelId,
              let entry = catalog.entry(forId: id)
        else { return true }
        return entry.supportsEffort
    }

    var body: some View {
        Menu {
            Section("Models") {
                let models = (agent == .claude) ? catalog.claude : catalog.codex
                ForEach(models) { entry in
                    Button(action: { selectedModelId = entry.id }) {
                        Label {
                            HStack {
                                Text(entry.displayName)
                                if let badge = entry.badge {
                                    Text(badge)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            if entry.id == selectedModelId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Section("Effort") {
                ForEach([ReasoningEffort.low, .medium, .high, .xhigh, .max], id: \.self) { effort in
                    Button(action: { selectedEffort = effort }) {
                        Label {
                            Text(effortLabel(effort))
                        } icon: {
                            if effort == selectedEffort {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!modelSupportsEffort)
                }
            }
        } label: {
            HStack(spacing: 6) {
                // Hug + center the model label instead of left-pinning it in a
                // fixed 96–180pt slot with tail truncation (which clipped long
                // "Model · Effort" combos and left short ones off-center). The
                // outer Menu is `.fixedSize(horizontal:)` so the capsule grows.
                // Mirrors the Mac UsageStatusChip.ModelEffortChip fix.
                Text(summaryText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                if let effort = selectedEffort, modelSupportsEffort {
                    Text(effortLabel(effort))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .background(Color(.tertiarySystemBackground), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var summaryText: String {
        guard let id = selectedModelId,
              let entry = catalog.entry(forId: id)
        else { return agent == .claude ? "Pick a model" : "Pick a model" }
        return entry.displayName
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
