import SwiftUI
import ClawdmeterShared

/// Compact pill on the left of the composer's bottom bar that opens a
/// "Mode" menu (Ask permissions / Accept edits / Plan / Bypass).
/// Replaces the standalone AutopilotChip + Plan-mode toggle.
///
/// The chip's color encodes the active mode at a glance:
///   • Ask permissions → secondary
///   • Accept edits    → accent
///   • Plan mode       → accent
///   • Bypass          → yellow (matches Claude Code's "Auto" warning hue)
struct PermissionModeChip: View {
    let mode: PermissionMode
    /// Available modes vary by context — the empty-state composer hides
    /// `.bypass` (no session yet) and the read-only composer hides
    /// everything except a stub. Callers pass the eligible list.
    let availableModes: [PermissionMode]
    let onChange: (PermissionMode) -> Void
    @State private var isHovered = false

    var body: some View {
        // Single chip, dual behavior:
        //   • click          → quick-flip plan ⇆ acceptEdits (the two
        //                       modes people swap between hourly)
        //   • hold / arrow   → full menu with ask / accept / plan / bypass
        // Backed by SwiftUI's `Menu(primaryAction:)` which is the native
        // pattern for "button with attached menu". Replaces the older
        // setup that needed a sibling `</> code` chip to provide the
        // single-click flip.
        Menu {
            Section("Mode") {
                ForEach(Array(availableModes.enumerated()), id: \.element) { (idx, candidate) in
                    Button(action: { onChange(candidate) }) {
                        HStack {
                            Text(candidate.displayName)
                            if candidate == mode {
                                Image(systemName: "checkmark")
                            }
                            Spacer()
                            Text("\(idx + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.command, .shift])
                }
            }
        } label: {
            // v0.7.13: chip styled identically to ModelEffortChip — same
            // Capsule background, same 11pt-medium label + 8pt chevron,
            // same padding.
            // v0.7.15: bypass is destructive (no permission prompts —
            // agent has carte blanche), so it gets a yellow accent ring
            // + bold label. Plan/Edits/Ask stay neutral-grey to match
            // the right-side model chip.
            HStack(spacing: 6) {
                Text(mode.shortLabel)
                    .font(.system(size: 12, weight: mode == .bypass ? .bold : .semibold))
                    .foregroundStyle(mode == .bypass ? Color.yellow : .primary)
                    .lineLimit(1)
                    .frame(minWidth: 50, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(
                mode == .bypass
                    ? AnyShapeStyle(Color.yellow.opacity(isHovered ? 0.22 : 0.15))
                    : AnyShapeStyle(Color.secondary.opacity(isHovered ? 0.16 : 0.10)),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        mode == .bypass
                            ? Color.yellow.opacity(0.5)
                            : (isHovered ? Color.secondary.opacity(0.24) : Color.clear),
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
        }
        primaryAction: {
            // Quick flip: plan ↔ acceptEdits. Both must be available
            // (Cursor's acceptEdits-only modes drop into the menu via
            // long-press). When the current mode is something else
            // (ask / bypass), the flip lands on plan if available so the
            // user feels "click to enter plan mode."
            let canPlan = availableModes.contains(.plan)
            let canEdits = availableModes.contains(.acceptEdits)
            switch mode {
            case .plan where canEdits:
                onChange(.acceptEdits)
            case .acceptEdits where canPlan:
                onChange(.plan)
            default:
                if canPlan { onChange(.plan) }
                else if canEdits { onChange(.acceptEdits) }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Click to toggle plan ⇆ code — long-press for ask / bypass (⌘⇧1-4)")
        .accessibilityLabel("Permission mode")
        .accessibilityValue(mode.shortLabel)
        .accessibilityIdentifier("code.composer.permission-mode")
        .onHover { isHovered = $0 }
    }
}
