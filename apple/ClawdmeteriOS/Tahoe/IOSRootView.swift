import SwiftUI
import ClawdmeterShared

/// Tahoe 26 iOS root — owns the global `TahoeThemeStore` and routes
/// between the four tabs (Chat / Live / Analytics / Code). Ports the
/// `ios-shell.jsx::IOSTabBar` floating glass capsule.
public struct IOSRootView: View {
    @State private var theme: TahoeThemeStore
    @State private var tab: Tab = .chat
    @State private var pushedScreen: Screen? = nil

    public enum Tab: String, CaseIterable { case chat, live, analytics, code }
    public enum Screen { case pairing, sessionDetail }

    /// Optional iOS usage model — when provided, the Live tab switches
    /// from demo data to the live per-provider quota.
    @ObservedObject private var usageModel: UsageModel

    public init(usageModel: UsageModel) {
        self.usageModel = usageModel
        _theme = State(initialValue: TahoeThemeStore.loaded())
    }

    public var body: some View {
        let live = usageModel.tahoeLive
        return ZStack {
            TahoeWallpaperView()
            contentView(live: live)
                .padding(.bottom, 92) // floating tab bar clearance
            if pushedScreen == nil {
                IOSTabBar(tab: $tab)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .background(theme.appearance == .dark ? Color.black : Color(.sRGB, red: 244.0/255, green: 246.0/255, blue: 250.0/255))
        .tahoeTheme(theme)
    }

    @ViewBuilder
    private func contentView(live: TahoeLiveBindings) -> some View {
        switch pushedScreen {
        case .pairing:
            IOSPairingView(onClose: { pushedScreen = nil })
        case .sessionDetail:
            IOSSessionDetailView(onBack: { pushedScreen = nil })
        case nil:
            switch tab {
            case .chat:      IOSChatView()
            case .live:      IOSLiveView(data: live)
            case .analytics: IOSAnalyticsView()
            case .code:      IOSCodeView(onOpenDetail: { pushedScreen = .sessionDetail })
            }
        }
    }
}

// MARK: - Tab Bar

public struct IOSTabBar: View {
    @Environment(\.tahoe) private var t
    @Binding var tab: IOSRootView.Tab

    private let items: [(IOSRootView.Tab, String, String)] = [
        (.chat,      "Chat",      "sparkles"),
        (.live,      "Live",      "gauge"),
        (.analytics, "Analytics", "diff"),
        (.code,      "Code",      "chat"),
    ]

    public var body: some View {
        TahoeGlass(radius: 999, tone: .raised) {
            HStack(spacing: 4) {
                ForEach(items, id: \.0) { (key, label, icon) in
                    let active = tab == key
                    Button { tab = key } label: {
                        HStack(spacing: 6) {
                            TahoeIcon(icon, size: 16)
                            Text(label)
                        }
                        .font(TahoeFont.body(13, weight: active ? .bold : .semibold))
                        .foregroundStyle(active ? t.fg : t.fg3)
                        .frame(maxWidth: .infinity, minHeight: 44)
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
            .padding(6)
        }
    }
}

// MARK: - Large iOS title

public struct IOSLargeTitle<Trailing: View>: View {
    @Environment(\.tahoe) private var t
    public var title: String
    public var subtitle: String?
    public var trailing: Trailing

    public init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(TahoeFont.body(12, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(t.fg3)
                }
                Text(title)
                    .font(TahoeFont.rounded(34, weight: .heavy))
                    .tracking(-0.8)
                    .foregroundStyle(t.fg)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 8)
    }
}

public struct IOSRoundIconBtn: View {
    @Environment(\.tahoe) private var t
    public var icon: String
    public var action: () -> Void
    public init(_ icon: String, action: @escaping () -> Void = {}) { self.icon = icon; self.action = action }

    public var body: some View {
        Button(action: action) {
            TahoeIcon(icon, size: 16)
                .foregroundStyle(t.fg)
                .frame(width: 38, height: 38)
                .background {
                    Circle().fill(t.glassTintHi)
                }
                .overlay {
                    Circle().stroke(t.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }
}
