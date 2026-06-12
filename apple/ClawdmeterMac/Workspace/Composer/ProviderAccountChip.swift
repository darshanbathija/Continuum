import SwiftUI
import AppKit
import ClawdmeterShared

/// Persists the Code-tab account pick per provider kind. nil wireId = primary.
enum CodeComposerAccountPreference {
    private static let defaultsKey = "clawdmeter.code.accountByAgent"

    static func wireId(for agent: AgentKind) -> String? {
        guard let map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] else {
            return nil
        }
        guard let wireId = map[agent.rawValue] else { return nil }
        return ProviderInstanceId.isSecondaryWireId(wireId) ? wireId : nil
    }

    static func setWireId(_ wireId: String?, for agent: AgentKind) {
        var map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        if let wireId, ProviderInstanceId.isSecondaryWireId(wireId) {
            map[agent.rawValue] = wireId
        } else {
            map.removeValue(forKey: agent.rawValue)
        }
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }
}

/// Compact pill on the composer's bottom bar that opens an account menu
/// (Default / work / personal …). Mirrors `PermissionModeChip`.
struct ProviderAccountChip: View {
    let accountChoices: [ProviderInstanceId]
    let selectedWireId: String?
    let onSelect: (String?) -> Void
    @State private var isHovered = false

    private var selectedLabel: String {
        Self.displayLabel(for: selectedWireId, in: accountChoices)
    }

    static func displayLabel(for wireId: String?, in choices: [ProviderInstanceId]) -> String {
        if let wireId,
           let match = choices.first(where: { $0.wireId == wireId }) {
            return match.isPrimary ? "Default" : match.name
        }
        return "Default"
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(selectedLabel)
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
        .accessibilityLabel("Account")
        .accessibilityValue(selectedLabel)
        .accessibilityIdentifier("code.composer.account")
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
            ProviderAccountMenuButton(
                accountChoices: accountChoices,
                selectedWireId: selectedWireId,
                onSelect: onSelect
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Capsule())
        .fixedSize()
        .help("Which account runs this session")
        .onHover { isHovered = $0 }
    }
}

private struct ProviderAccountMenuButton: NSViewRepresentable {
    let accountChoices: [ProviderInstanceId]
    let selectedWireId: String?
    let onSelect: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            accountChoices: accountChoices,
            selectedWireId: selectedWireId,
            onSelect: onSelect
        )
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        button.imagePosition = .noImage
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        button.setAccessibilityLabel("Account menu")
        button.setAccessibilityIdentifier("code.composer.account.menu")
        button.setAccessibilityRole(.button)
        button.setAccessibilityValue("Closed" as NSString)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.accountChoices = accountChoices
        context.coordinator.selectedWireId = selectedWireId
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
        var accountChoices: [ProviderInstanceId]
        var selectedWireId: String?
        var onSelect: (String?) -> Void
        weak var button: NSButton?

        init(
            accountChoices: [ProviderInstanceId],
            selectedWireId: String?,
            onSelect: @escaping (String?) -> Void
        ) {
            self.accountChoices = accountChoices
            self.selectedWireId = selectedWireId
            self.onSelect = onSelect
        }

        @objc func openMenu(_ sender: NSButton) {
            button = sender
            sender.setAccessibilityValue("Open" as NSString)
            let menu = NSMenu()
            menu.delegate = self
            for instance in accountChoices {
                let dto = ProviderInstanceDTO(instance: instance)
                let item = NSMenuItem(
                    title: dto.displayName,
                    action: #selector(selectAccount(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = instance.isPrimary ? NSNull() : instance.wireId as NSString
                item.identifier = NSUserInterfaceItemIdentifier("code.composer.account.\(instance.name)")
                let isCurrent = instance.isPrimary
                    ? selectedWireId == nil
                    : selectedWireId == instance.wireId
                item.state = isCurrent ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func selectAccount(_ item: NSMenuItem) {
            if item.representedObject is NSNull {
                onSelect(nil)
            } else if let wireId = item.representedObject as? String {
                onSelect(wireId)
            }
        }

        func menuDidClose(_ menu: NSMenu) {
            button?.setAccessibilityValue("Closed" as NSString)
        }
    }
}
