import SwiftUI
import AppKit
import ClawdmeterShared

/// Compact pill on the composer's bottom bar that opens an effort menu
/// (Minimal / Low / Medium / High / Extra high / Max). Mirrors
/// `PermissionModeChip` — model selection stays on `ModelEffortChip`.
struct EffortChip: View {
    let effort: ReasoningEffort?
    let supportsEffort: Bool
    let onChange: (ReasoningEffort) -> Void
    @State private var isHovered = false

    private var resolvedEffort: ReasoningEffort {
        effort ?? .medium
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(resolvedEffort.shortLabel)
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
        .accessibilityLabel("Effort")
        .accessibilityValue(resolvedEffort.shortLabel)
        .accessibilityIdentifier("code.composer.effort")
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
            EffortMenuButton(
                effort: resolvedEffort,
                onSelect: onChange
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Capsule())
        .fixedSize()
        .help("Open effort menu (⌘⌥E cycles up, ⌘⌥⇧E down)")
        .onHover { isHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .composerCycleEffortNext)) { _ in
            cycleEffort(direction: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerCycleEffortPrevious)) { _ in
            cycleEffort(direction: -1)
        }
    }

    private func cycleEffort(direction: Int) {
        guard supportsEffort else { return }
        let values = ReasoningEffort.allCases
        let currentIndex = values.firstIndex(of: resolvedEffort) ?? values.firstIndex(of: .medium) ?? 0
        let next = (currentIndex + direction + values.count) % values.count
        onChange(values[next])
    }
}

private struct EffortMenuButton: NSViewRepresentable {
    let effort: ReasoningEffort
    let onSelect: (ReasoningEffort) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(effort: effort, onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSButton {
        // PointingHandButton (defined in PermissionModeChip.swift) shows the
        // link cursor over the whole pill, matching the permission pill.
        let button = PointingHandButton()
        button.isBordered = false
        button.title = ""
        button.imagePosition = .noImage
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        button.setAccessibilityLabel("Effort menu")
        button.setAccessibilityIdentifier("code.composer.effort.menu")
        button.setAccessibilityRole(.button)
        button.setAccessibilityValue("Closed" as NSString)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.effort = effort
        context.coordinator.onSelect = onSelect
        context.coordinator.button = button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: proposal.height ?? nsView.intrinsicContentSize.height
        )
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var effort: ReasoningEffort
        var onSelect: (ReasoningEffort) -> Void
        weak var button: NSButton?

        init(effort: ReasoningEffort, onSelect: @escaping (ReasoningEffort) -> Void) {
            self.effort = effort
            self.onSelect = onSelect
        }

        @objc func openMenu(_ sender: NSButton) {
            ContinuumAnalytics.trackButton("composer_effort_menu")
            button = sender
            sender.setAccessibilityValue("Open" as NSString)
            let menu = NSMenu()
            menu.delegate = self
            for candidate in ReasoningEffort.allCases {
                let item = NSMenuItem(
                    title: candidate.displayName,
                    action: #selector(selectEffort(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = candidate.rawValue
                item.identifier = NSUserInterfaceItemIdentifier("code.composer.effort.\(candidate.rawValue)")
                item.state = candidate == effort ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func selectEffort(_ item: NSMenuItem) {
            guard
                let raw = item.representedObject as? String,
                let selectedEffort = ReasoningEffort(rawValue: raw)
            else { return }
            ContinuumAnalytics.trackButton("composer_effort_select_\(raw)")
            onSelect(selectedEffort)
        }

        func menuDidClose(_ menu: NSMenu) {
            button?.setAccessibilityValue("Closed" as NSString)
        }
    }
}
