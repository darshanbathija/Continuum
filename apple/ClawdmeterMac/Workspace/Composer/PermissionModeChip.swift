import SwiftUI
import AppKit
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
        // Single chip, dual behavior:
        //   • click          → quick-flip plan ⇆ acceptEdits (the two
        //                       modes people swap between hourly)
        //   • arrow          → full menu with ask / accept / plan / bypass
        // The primary action is an explicit Button. `Menu(primaryAction:)`
        // renders as an AppKit popup on macOS UI automation and opens the
        // menu instead of quick-flipping, which made the main click path dead.
        HStack(spacing: 0) {
            Button {
                if let target = Self.quickFlipTarget(current: mode, availableModes: availableModes) {
                    onChange(target)
                }
            } label: {
                Text(mode.shortLabel)
                    .font(.system(size: 12, weight: mode == .bypass ? .bold : .semibold))
                    .foregroundStyle(mode == .bypass ? Color.yellow : .primary)
                    .lineLimit(1)
                    .frame(minWidth: 50, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(minHeight: 32)
            .accessibilityLabel("Permission mode")
            .accessibilityValue(mode.shortLabel)
            .accessibilityIdentifier("code.composer.permission-mode")

            PermissionModeMenuButton(
                mode: mode,
                availableModes: availableModes,
                onSelect: onChange
            )
            .frame(width: 28, height: 32)
            .padding(.trailing, 6)
        }
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
                .allowsHitTesting(false)
        )
        .contentShape(Capsule())
        .fixedSize()
        .help("Click to toggle plan ⇆ code — use the arrow for ask / bypass (⌘⇧1-4)")
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
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
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
            onSelect(selectedMode)
        }

        func menuDidClose(_ menu: NSMenu) {
            button?.setAccessibilityValue("Closed" as NSString)
        }
    }
}
