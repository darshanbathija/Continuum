import SwiftUI
import ClawdmeterShared

/// Segmented pairing transport picker shared by the download step, settings
/// pane, and toolbar popover.
struct PairingModePicker: View {
    @Binding var mode: PairingMode
    var layout: Layout = .settings

    enum Layout {
        case settings
        case compact
    }

    @Environment(\.tahoe) private var t

    var body: some View {
        switch layout {
        case .settings:
            settingsLayout
        case .compact:
            compactLayout
        }
    }

    private var settingsLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Pairing method", selection: $mode) {
                ForEach(PairingMode.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Pairing method")

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.accent)
                    .frame(width: 16)
                Text(mode.subtitle)
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Pairing method", selection: $mode) {
                ForEach(PairingMode.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Pairing method")

            Text(mode.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
