import SwiftUI
import AppKit
import ClawdmeterShared

/// Compact pill on the left of the composer's bottom bar that opens a
/// "Mode" menu (Ask permissions / Accept edits / Plan / Bypass).
/// Replaces the standalone AutopilotChip + Plan-mode toggle.
///
/// The chip uses the same neutral pill styling for every mode.
struct PermissionModeChip: View {
    let mode: PermissionMode
    /// Available modes vary by context — Cursor hides `.plan`, and read-only
    /// composers hide the chip entirely. Callers pass the eligible list.
    let availableModes: [PermissionMode]
    let onChange: (PermissionMode) -> Void
    @State private var isHovered = false

    static func shortcutDigit(for mode: PermissionMode) -> Character {
        switch mode {
        case .ask: return "1"
        case .acceptEdits: return "2"
        case .plan: return "3"
        case .bypass: return "4"
        }
    }

    static func quickFlipTarget(current mode: PermissionMode, availableModes: [PermissionMode]) -> PermissionMode? {
        let canPlan = availableModes.contains(.plan)
        let canEdits = availableModes.contains(.acceptEdits)
        switch mode {
        case .plan where canEdits:
            return .acceptEdits
        case .acceptEdits where canPlan:
            return .plan
        default:
            if canPlan { return .plan }
            if canEdits { return .acceptEdits }
            return nil
        }
    }

    var body: some View {
        // The whole pill opens the Mode menu. A full-bleed AppKit popup
        // button sits on top of the label so a click ANYWHERE on the capsule
        // pops the dropdown (ask / accept / plan / bypass) — not just the
        // chevron. Quick-flip-on-click was removed per user feedback; the
        // ⌘⇧1–4 shortcuts (hosted in ComposerInputCore) still switch modes.
        // The label hugs its text and centers it (no fixed min slot) so
        // "Ask permissions", "Plan mode", "Bypass permissions", etc. read centered.
        HStack(spacing: 4) {
            Text(mode.shortLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Permission mode")
        .accessibilityValue(mode.shortLabel)
        .accessibilityIdentifier("code.composer.permission-mode")
        .background(
            Color.secondary.opacity(isHovered ? 0.16 : 0.10),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isHovered ? Color.secondary.opacity(0.24) : Color.clear,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
        .overlay {
            // Invisible click target spanning the entire capsule.
            PermissionModeMenuButton(
                mode: mode,
                availableModes: availableModes,
                onSelect: onChange
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Capsule())
        .fixedSize()
        .help("Open permission mode menu (⌘⇧1–4)")
        .onHover { isHovered = $0 }
    }
}

private struct PermissionModeMenuButton: NSViewRepresentable {
    let mode: PermissionMode
    let availableModes: [PermissionMode]
    let onSelect: (PermissionMode) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, availableModes: availableModes, onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSButton {
        // Transparent, title/image-less button that fills the whole pill (the
        // SwiftUI label draws the text + chevron underneath). Borderless +
        // empty content = invisible, but still hit-tests its entire bounds, so
        // clicking anywhere on the capsule opens the menu.
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        button.imagePosition = .noImage
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        button.setAccessibilityLabel("Permission mode menu")
        button.setAccessibilityIdentifier("code.composer.permission-mode.menu")
        button.setAccessibilityRole(.button)
        button.setAccessibilityValue("Closed" as NSString)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.mode = mode
        context.coordinator.availableModes = availableModes
        context.coordinator.onSelect = onSelect
        context.coordinator.button = button
    }

    // Accept the proposed size so the button FILLS the pill instead of
    // collapsing to an empty NSButton's tiny intrinsic size (which would
    // leave most of the capsule dead). This is what makes the whole pill the
    // clickable hit target.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: proposal.height ?? nsView.intrinsicContentSize.height
        )
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var mode: PermissionMode
        var availableModes: [PermissionMode]
        var onSelect: (PermissionMode) -> Void
        weak var button: NSButton?

        init(mode: PermissionMode, availableModes: [PermissionMode], onSelect: @escaping (PermissionMode) -> Void) {
            self.mode = mode
            self.availableModes = availableModes
            self.onSelect = onSelect
        }

        @objc func openMenu(_ sender: NSButton) {
            ContinuumAnalytics.trackButton("composer_permission_menu")
            button = sender
            sender.setAccessibilityValue("Open" as NSString)
            let menu = NSMenu()
            menu.delegate = self
            for candidate in availableModes {
                let item = NSMenuItem(
                    title: candidate.displayName,
                    action: #selector(selectMode(_:)),
                    keyEquivalent: String(PermissionModeChip.shortcutDigit(for: candidate))
                )
                item.keyEquivalentModifierMask = [.command, .shift]
                item.target = self
                item.representedObject = candidate.rawValue
                item.identifier = NSUserInterfaceItemIdentifier("code.composer.permission-mode.\(candidate.rawValue)")
                item.state = candidate == mode ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func selectMode(_ item: NSMenuItem) {
            guard
                let raw = item.representedObject as? String,
                let selectedMode = PermissionMode(rawValue: raw)
            else { return }
            ContinuumAnalytics.trackButton("composer_permission_select_\(raw)")
            onSelect(selectedMode)
        }

        func menuDidClose(_ menu: NSMenu) {
            button?.setAccessibilityValue("Closed" as NSString)
        }
    }
}
