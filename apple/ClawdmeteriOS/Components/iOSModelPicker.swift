import SwiftUI
import ClawdmeterShared

/// iOS model picker — `NavigationLink` to a sub-screen with two sections
/// (Claude Code / Codex). Each row shows displayName + badge pill + the
/// `recommendedFor` subtitle.
///
/// Sessions v2 D11 + Phase 2.
struct iOSModelPicker: View {
    @Binding var selectedModelId: String?
    let catalog: ModelCatalog
    let agent: AgentKind

    var body: some View {
        NavigationLink {
            iOSModelPickerList(
                catalog: catalog,
                agent: agent,
                selectedModelId: $selectedModelId
            )
        } label: {
            HStack {
                Text("Model")
                Spacer()
                Text(selectedEntry?.displayName ?? "Default")
                    .foregroundStyle(.secondary)
                if let badge = selectedEntry?.badge {
                    iOSBadgePill(label: badge, isPrimary: badge == "New")
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model picker")
        .accessibilityValue(selectedAccessibilityValue)
        .accessibilityHint("Double-tap to choose a different model.")
        .accessibilityAddTraits(.isButton)
    }

    /// VoiceOver should read e.g. "Opus 4.7, 1 million context window,
    /// new" instead of dropping the badge + context entirely.
    private var selectedAccessibilityValue: String {
        guard let entry = selectedEntry else { return "default model" }
        var parts = [entry.displayName]
        if let cw = entry.contextWindow {
            if cw >= 1_000_000 {
                parts.append("\(cw / 1_000_000) million context window")
            } else if cw >= 1_000 {
                parts.append("\(cw / 1_000) thousand context window")
            }
        }
        if let badge = entry.badge {
            parts.append(badge.lowercased())
        }
        if let recommended = entry.recommendedFor {
            parts.append("recommended for \(recommended.lowercased())")
        }
        return parts.joined(separator: ", ")
    }

    private var selectedEntry: ModelCatalogEntry? {
        guard let id = selectedModelId else { return nil }
        let entries = agent == .claude ? catalog.claude : catalog.codex
        return entries.first(where: { $0.id == id })
    }
}

struct iOSModelPickerList: View {
    let catalog: ModelCatalog
    let agent: AgentKind
    @Binding var selectedModelId: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section(agent == .claude ? "Claude Code" : "Codex") {
                ForEach(entries) { entry in
                    Button {
                        selectedModelId = entry.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.displayName)
                                        .foregroundStyle(.primary)
                                    if let badge = entry.badge {
                                        iOSBadgePill(label: badge, isPrimary: badge == "New")
                                    }
                                }
                                if let recommended = entry.recommendedFor {
                                    Text(recommended)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if entry.id == selectedModelId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(SessionsV2Theme.accent)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(rowAccessibilityLabel(entry: entry))
                    .accessibilityAddTraits(entry.id == selectedModelId ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var entries: [ModelCatalogEntry] {
        agent == .claude ? catalog.claude : catalog.codex
    }

    private func rowAccessibilityLabel(entry: ModelCatalogEntry) -> String {
        var parts = [entry.displayName]
        if let cw = entry.contextWindow {
            if cw >= 1_000_000 {
                parts.append("\(cw / 1_000_000) million context window")
            } else if cw >= 1_000 {
                parts.append("\(cw / 1_000) thousand context window")
            }
        }
        if let badge = entry.badge {
            parts.append("\(badge.lowercased())")
        }
        if let recommended = entry.recommendedFor {
            parts.append("recommended for \(recommended.lowercased())")
        }
        return parts.joined(separator: ", ")
    }
}

struct iOSBadgePill: View {
    let label: String
    let isPrimary: Bool
    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                isPrimary ? SessionsV2Theme.accent : SessionsV2Theme.codexBlue,
                in: RoundedRectangle(cornerRadius: 3)
            )
            .foregroundStyle(.white)
            .accessibilityLabel("\(label) badge")
    }
}
