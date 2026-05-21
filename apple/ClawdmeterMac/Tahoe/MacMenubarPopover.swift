import SwiftUI
import ClawdmeterShared

/// Replacement for `PopoverView`. Provider segmented + stacked meters.
/// Ports `mac-dashboard.jsx::MacMenubarPopover`.
public struct MacMenubarPopover: View {
    @Environment(\.tahoe) private var t
    @State private var selected: TahoeProvider
    public var data: TahoeLiveBindings

    private let enabled: [TahoeProvider] = [.claude, .codex, .gemini]

    public init(data: TahoeLiveBindings = .demo, initialProvider: TahoeProvider = .claude) {
        self.data = data
        self._selected = State(initialValue: initialProvider)
    }

    public var body: some View {
        let row = data.row(for: selected)
        TahoeGlass(radius: 18, tone: .panel) {
            VStack(alignment: .leading, spacing: 0) {
                // Provider segmented control
                HStack(spacing: 3) {
                    ForEach(enabled) { p in
                        let active = p == selected
                        Button { selected = p } label: {
                            HStack(spacing: 6) {
                                TahoeProviderGlyph(provider: p, size: 18)
                                Text(p.displayName)
                            }
                            .font(TahoeFont.body(12, weight: active ? .bold : .semibold))
                            .foregroundStyle(active ? t.fg : t.fg3)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background {
                                if active {
                                    Capsule(style: .continuous)
                                        .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : .white)
                                        .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background {
                    Capsule(style: .continuous).fill(t.glassTintHi)
                }
                .padding(.bottom, 12)

                // 5h + Weekly meters
                VStack(spacing: 12) {
                    TahoeMenuBarMeter(label: "5h session", percent: row.sessionPercent, hint: "resets in \(row.sessionResetIn)", provider: selected)
                    if row.hasWeekly {
                        TahoeMenuBarMeter(label: "Weekly", percent: row.weeklyPercent, hint: "resets in \(row.weeklyResetIn)", provider: selected)
                    }
                }
                .padding(.horizontal, 4)

                // JSX `<Hair style={{ margin: '12px 0 10px' }} />` (mac-dashboard.jsx:646)
                // — asymmetric: 12pt above, 10pt below.
                TahoeHair().padding(.top, 12).padding(.bottom, 10)

                HStack(spacing: 6) {
                    TahoeGhostButton(size: .s) {
                        HStack(spacing: 4) {
                            TahoeIcon("grid", size: 10)
                            Text("Open dashboard")
                        }
                    }
                    .frame(maxWidth: .infinity)

                    TahoeGhostButton(size: .s) {
                        HStack(spacing: 4) {
                            TahoeIcon("qr", size: 10)
                            Text("Sync iPhone")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(14)
            .frame(width: 360)
        }
    }
}

/// Status-item label as it appears in the macOS menu bar.
/// Ports the JSX `menu-bar items` row format: `[glyph] {percent}%` per provider.
public struct MenuBarItemView: View {
    @Environment(\.tahoe) private var t
    public var provider: TahoeProvider
    public var percent: Double
    public var onClick: () -> Void

    public init(provider: TahoeProvider, percent: Double, onClick: @escaping () -> Void) {
        self.provider = provider; self.percent = percent; self.onClick = onClick
    }

    public var body: some View {
        Button(action: onClick) {
            HStack(spacing: 5) {
                TahoeProviderGlyph(provider: provider, size: 14)
                Text("\(Int(percent))%")
                    .font(TahoeFont.mono(11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(t.fg)
            }
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 6).padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
