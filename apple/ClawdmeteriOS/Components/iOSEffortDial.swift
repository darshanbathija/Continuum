import SwiftUI
import ClawdmeterShared

/// iOS effort dial — segmented `Picker` over the 5 reasoning levels.
/// Hidden / disabled when the selected model doesn't support effort.
///
/// Sessions v2 D11 + Phase 2. T35: a11y — VoiceOver reads the dial as
/// "Effort dial, currently High. Adjustable. Swipe up to increase,
/// swipe down to decrease." Below `dynamicTypeSize >= .accessibility3`
/// the segmented picker collapses into a `Menu` to preserve a 44pt
/// touch target per segment (segmented controls shrink past AX3).
struct iOSEffortDial: View {
    @Binding var selected: ReasoningEffort
    let supportsEffort: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if supportsEffort {
            Group {
                if dynamicTypeSize >= .accessibility3 {
                    collapsedMenu
                } else {
                    segmented
                }
            }
            .accessibilityLabel("Effort dial")
            .accessibilityValue(longLabel(for: selected))
            .accessibilityHint("Adjustable. Swipe up to increase, swipe down to decrease.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    if let next = nextEffort(after: selected) { selected = next }
                case .decrement:
                    if let prev = prevEffort(before: selected) { selected = prev }
                @unknown default:
                    break
                }
            }
        } else {
            HStack {
                Text("Effort")
                Spacer()
                Text("Not available for this model")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Effort dial unavailable for the selected model")
        }
    }

    private var segmented: some View {
        Picker("Effort", selection: $selected) {
            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                Text(label(for: effort))
                    .tag(effort)
            }
        }
        .pickerStyle(.segmented)
    }

    private var collapsedMenu: some View {
        Menu {
            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                Button {
                    selected = effort
                } label: {
                    if effort == selected {
                        Label(longLabel(for: effort), systemImage: "checkmark")
                    } else {
                        Text(longLabel(for: effort))
                    }
                }
            }
        } label: {
            HStack {
                Text("Effort")
                Spacer()
                Text(longLabel(for: selected))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    private func label(for effort: ReasoningEffort) -> String {
        switch effort {
        case .minimal: return "Min"
        case .low:     return "Low"
        case .medium:  return "Med"
        case .high:    return "High"
        case .xhigh:   return "xHigh"
        }
    }

    /// Long form used in accessibilityValue + the collapsed menu so
    /// VoiceOver reads the full word ("High") rather than "High".
    private func longLabel(for effort: ReasoningEffort) -> String {
        switch effort {
        case .minimal: return "Minimal"
        case .low:     return "Low"
        case .medium:  return "Medium"
        case .high:    return "High"
        case .xhigh:   return "Extra high"
        }
    }

    private func nextEffort(after current: ReasoningEffort) -> ReasoningEffort? {
        let cases = ReasoningEffort.allCases
        guard let idx = cases.firstIndex(of: current), idx + 1 < cases.count else { return nil }
        return cases[idx + 1]
    }

    private func prevEffort(before current: ReasoningEffort) -> ReasoningEffort? {
        let cases = ReasoningEffort.allCases
        guard let idx = cases.firstIndex(of: current), idx > 0 else { return nil }
        return cases[idx - 1]
    }
}
