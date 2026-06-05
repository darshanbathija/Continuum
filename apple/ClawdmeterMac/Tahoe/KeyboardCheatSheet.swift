import SwiftUI
import ClawdmeterShared

struct KeyboardCheatSheet: View {
    @Environment(\.tahoe) private var t

    let registry: ClawdmeterShortcutRegistry
    let overrides: [String: String]
    let onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    private var grouped: [(ClawdmeterCommandScope, [ClawdmeterShortcut])] {
        registry.grouped(query: query)
            .map { ($0.key, $0.value) }
            .sorted { $0.0.rawValue < $1.0.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(t.fg3)
                TextField("Search shortcuts", text: $query)
                    .textFieldStyle(.plain)
                    .font(TahoeFont.body(14, weight: .medium))
                    .focused($focused)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(t.fg3)
                        .frame(width: 24, height: 24)
                        .background(t.hair2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            TahoeHair()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(grouped, id: \.0) { scope, shortcuts in
                        KeyboardShortcutGroup(scope: scope, shortcuts: shortcuts, registry: registry, overrides: overrides)
                    }
                    if grouped.isEmpty {
                        KeyboardShortcutEmptyState()
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 560)
        .background(ContinuumTokens.surface3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.24), radius: 34, x: 0, y: 20)
        .onAppear { focused = true }
        .background(KeyMonitor(up: {}, down: {}, enter: {}, escape: onDismiss))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts")
    }
}

private struct KeyboardShortcutGroup: View {
    @Environment(\.tahoe) private var t

    let scope: ClawdmeterCommandScope
    let shortcuts: [ClawdmeterShortcut]
    let registry: ClawdmeterShortcutRegistry
    let overrides: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scope.rawValue.capitalized)
                .font(TahoeFont.body(11, weight: .bold))
                .foregroundStyle(t.fg3)
                .textCase(.uppercase)
            ForEach(shortcuts) { shortcut in
                KeyboardShortcutRow(shortcut: shortcut, chord: registry.displayChord(for: shortcut, overrides: overrides))
            }
        }
    }
}

private struct KeyboardShortcutRow: View {
    @Environment(\.tahoe) private var t

    let shortcut: ClawdmeterShortcut
    let chord: String

    var body: some View {
        HStack(spacing: 12) {
            Text(shortcut.label)
                .font(TahoeFont.body(12.5, weight: .medium))
                .foregroundStyle(shortcut.isEnabled ? t.fg : t.fg3)
            Spacer()
            Text(chord)
                .font(TahoeFont.mono(11))
                .foregroundStyle(t.fg2)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var rowBackground: Color {
        t.dark ? Color.white.opacity(0.035) : Color.black.opacity(0.035)
    }
}

private struct KeyboardShortcutEmptyState: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        Text("No shortcuts match")
            .font(TahoeFont.body(12))
            .foregroundStyle(t.fg3)
            .frame(maxWidth: .infinity, minHeight: 140)
    }
}
