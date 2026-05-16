import SwiftUI
import ClawdmeterShared

/// iOS effort dial — segmented `Picker` over the 5 reasoning levels.
/// Hidden / disabled when the selected model doesn't support effort.
///
/// Sessions v2 D11 + Phase 2.
struct iOSEffortDial: View {
    @Binding var selected: ReasoningEffort
    let supportsEffort: Bool

    var body: some View {
        if supportsEffort {
            Picker("Effort", selection: $selected) {
                ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                    Text(label(for: effort))
                        .tag(effort)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Effort dial, currently \(label(for: selected))")
        } else {
            HStack {
                Text("Effort")
                Spacer()
                Text("Not available for this model")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
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
}
