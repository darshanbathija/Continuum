import SwiftUI
import ClawdmeterShared

/// Per-session effort dial — 5-segment chip control (Min · Low · Med · High
/// · xHigh). Wires to `claude --effort` and `codex -c model_reasoning_effort`.
///
/// Disabled when the currently-selected model `supportsEffort == false`
/// (e.g., Haiku 4.5). Hidden segments display a tooltip explaining why.
///
/// Sessions v2 D11 + Phase 1.
struct EffortDial: View {
    let selected: ReasoningEffort?
    /// When false (e.g., Haiku 4.5), the dial renders disabled with a tooltip.
    let supportsEffort: Bool
    let onChange: (ReasoningEffort) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                segment(effort)
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: SessionsV2Theme.Radius.chip + 1))
        .opacity(supportsEffort ? 1.0 : 0.5)
        .disabled(!supportsEffort)
        .help(supportsEffort
              ? "Reasoning effort — Opt+E cycles up, Shift+Opt+E down"
              : "This model doesn't take an effort level (e.g. Haiku)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(supportsEffort ? "Effort dial" : "Effort dial unavailable for the selected model")
        .accessibilityValue(supportsEffort ? longLabel(for: selected ?? .medium) : "")
    }

    @ViewBuilder
    private func segment(_ effort: ReasoningEffort) -> some View {
        let isSelected = (effort == selected)
        Button {
            guard !isSelected else { return }
            withAnimation(SessionsV2Theme.chipSwapAnimation(reduceMotion: reduceMotion)) {
                onChange(effort)
            }
        } label: {
            Text(label(for: effort))
                .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    isSelected
                        ? AnyShapeStyle(SessionsV2Theme.accent)
                        : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: SessionsV2Theme.Radius.chip - 1)
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Effort \(label(for: effort))\(isSelected ? ", selected" : "")")
    }

    private func label(for effort: ReasoningEffort) -> String {
        switch effort {
        case .minimal: return "Min"
        case .low:     return "Low"
        case .medium:  return "Med"
        case .high:    return "High"
        case .xhigh:   return "xHigh"
        case .max:     return "Max"
        }
    }

    private func longLabel(for effort: ReasoningEffort) -> String {
        switch effort {
        case .minimal: return "minimal"
        case .low:     return "low"
        case .medium:  return "medium"
        case .high:    return "high"
        case .xhigh:   return "extra high"
        case .max:     return "max"
        }
    }
}
