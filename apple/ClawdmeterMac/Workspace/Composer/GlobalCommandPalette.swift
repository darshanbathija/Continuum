import SwiftUI
import ClawdmeterShared

struct GlobalCommandPalette: View {
    @Environment(\.tahoe) private var t

    let registry: ClawdmeterCommandRegistry
    let shortcuts: ClawdmeterShortcutRegistry
    let shortcutOverrides: [String: String]
    let recentCommandIDs: [String]
    let onRun: (ClawdmeterCommandDescriptor) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private var commands: [ClawdmeterCommandDescriptor] {
        let filtered = registry.filtered(query: query)
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !recentCommandIDs.isEmpty
        else { return filtered }
        let recent = recentCommandIDs.compactMap { registry.command(id: ClawdmeterCommandID(rawValue: $0)) }
        let recentIds = Set(recent.map(\.id))
        return recent + filtered.filter { !recentIds.contains($0.id) }
    }

    var body: some View {
        let commandList = commands

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(t.fg3)
                TextField("Run a command, open a session, or search actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(TahoeFont.body(14, weight: .medium))
                    .focused($focused)
                Text("Esc")
                    .font(TahoeFont.mono(10))
                    .foregroundStyle(t.fg4)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            TahoeHair()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(commandList.enumerated()), id: \.element.id) { idx, command in
                            Button(action: { run(command) }) {
                                commandRow(command, selected: idx == selectedIndex)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .disabled(!command.isEnabled)
                            .id(command.id.rawValue)
                            .accessibilityLabel(command.title)
                            .accessibilityHint(rowDetail(for: command))
                        }
                        if commandList.isEmpty {
                            Text("No commands match")
                                .font(TahoeFont.body(12))
                                .foregroundStyle(t.fg3)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedIndex) { _, newValue in
                    guard newValue >= 0, newValue < commandList.count else { return }
                    proxy.scrollTo(commandList[newValue].id.rawValue, anchor: .center)
                }
                .onChange(of: commandList.map { $0.id.rawValue }) { _, _ in
                    selectedIndex = firstEnabledIndex(in: commandList) ?? 0
                    if selectedIndex >= 0, selectedIndex < commandList.count {
                        proxy.scrollTo(commandList[selectedIndex].id.rawValue, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: 390)
        }
        .frame(width: 640)
        .background(ContinuumTokens.surface3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.24), radius: 34, x: 0, y: 20)
        .onAppear {
            focused = true
            selectedIndex = firstEnabledIndex(in: commandList) ?? 0
        }
        .onChange(of: query) { _, _ in selectedIndex = firstEnabledIndex(in: commands) ?? 0 }
        .background(KeyMonitor(
            up: { moveSelection(delta: -1) },
            down: { moveSelection(delta: 1) },
            enter: {
                let current = commands
                if selectedIndex >= 0, selectedIndex < current.count {
                    run(current[selectedIndex])
                }
            },
            escape: onDismiss
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func commandRow(_ command: ClawdmeterCommandDescriptor, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: command))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(command.isEnabled ? t.fg2 : t.fg4)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(command.isEnabled ? t.fg : t.fg3)
                    .lineLimit(1)
                Text(rowDetail(for: command))
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg3)
                    .lineLimit(1)
            }
            Spacer()
            if let shortcut = shortcut(for: command) {
                Text(shortcuts.displayChord(for: shortcut, overrides: shortcutOverrides))
                    .font(TahoeFont.mono(10))
                    .foregroundStyle(t.fg3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            selected ? t.accentAlpha(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .opacity(command.isEnabled ? 1 : 0.62)
        .help(rowDetail(for: command))
    }

    private func rowDetail(for command: ClawdmeterCommandDescriptor) -> String {
        if !command.isEnabled, let disabledReason = command.disabledReason {
            return disabledReason
        }
        return command.subtitle ?? command.scope.rawValue.capitalized
    }

    private func shortcut(for command: ClawdmeterCommandDescriptor) -> ClawdmeterShortcut? {
        guard let shortcutID = command.shortcutID else { return nil }
        return shortcuts.shortcuts.first { $0.id == shortcutID }
    }

    private func run(_ command: ClawdmeterCommandDescriptor) {
        guard command.isEnabled else { return }
        onRun(command)
    }

    private func firstEnabledIndex(in list: [ClawdmeterCommandDescriptor]) -> Int? {
        list.firstIndex(where: \.isEnabled)
    }

    private func moveSelection(delta: Int) {
        let list = commands
        guard !list.isEmpty else {
            selectedIndex = 0
            return
        }
        var candidate = selectedIndex
        for _ in list.indices {
            candidate = min(max(candidate + delta, 0), list.count - 1)
            if list[candidate].isEnabled {
                selectedIndex = candidate
                return
            }
            if candidate == 0 || candidate == list.count - 1 { break }
        }
        selectedIndex = firstEnabledIndex(in: list) ?? min(max(selectedIndex, 0), list.count - 1)
    }

    private func symbol(for command: ClawdmeterCommandDescriptor) -> String {
        switch command.kind {
        case .navigation: return "arrow.right.circle"
        case .session: return "bubble.left.and.bubble.right"
        case .setting: return "gearshape"
        case .skill: return "wand.and.stars"
        case .external: return "arrow.up.forward.square"
        case .action: return "bolt"
        }
    }
}
