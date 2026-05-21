import SwiftUI
import ClawdmeterShared

/// Tahoe 26 iOS root — owns the global `TahoeThemeStore` and routes
/// between the four tabs (Chat / Live / Analytics / Code). Ports the
/// `ios-shell.jsx::IOSTabBar` floating glass capsule.
public struct IOSRootView: View {
    @State private var theme: TahoeThemeStore
    @State private var tab: Tab = .chat
    @State private var pushedScreen: Screen? = nil
    @State private var newSessionPresented: Bool = false
    @State private var settingsPresented: Bool = false

    public enum Tab: String, CaseIterable { case chat, live, analytics, code }
    /// Routes the modal/pushed screens above the tab bar. `sessionDetail`
    /// carries the opened session's UUID so the detail view can look up
    /// real data instead of rendering a fixture.
    public enum Screen: Equatable { case pairing, sessionDetail(UUID) }

    /// Optional iOS usage model — when provided, the Live tab switches
    /// from demo data to the live per-provider quota.
    @ObservedObject private var usageModel: UsageModel
    /// Daemon-backed agent client. Drives the Code tab's session list.
    @ObservedObject private var agentClient: AgentControlClient

    public init(usageModel: UsageModel, agentClient: AgentControlClient) {
        self.usageModel = usageModel
        self.agentClient = agentClient
        _theme = State(initialValue: TahoeThemeStore.loaded())
    }

    public var body: some View {
        let live = usageModel.tahoeLive
        let code = agentClient.tahoeCode
        return ZStack {
            TahoeWallpaperView()
            contentView(live: live, code: code)
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
        // P1 fix: pull live session data on first appearance and whenever
        // we return to the foreground. Without this, the daemon-mirrored
        // session list stays empty until the user interacts with the Mac.
        .task { await agentClient.refreshAll() }
        .sheet(isPresented: $newSessionPresented) {
            NewSessionSheet(client: agentClient, isPresented: $newSessionPresented)
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsView(model: usageModel)
        }
    }

    @ViewBuilder
    private func contentView(live: TahoeLiveBindings, code: TahoeCodeBindings) -> some View {
        switch pushedScreen {
        case .pairing:
            IOSPairingView(
                client: agentClient,
                onClose: { pushedScreen = nil }
            )
        case .sessionDetail(let id):
            IOSSessionDetailView(
                agentClient: agentClient,
                sessionId: id,
                data: code,
                onBack: { pushedScreen = nil }
            )
        case nil:
            switch tab {
            case .chat:      IOSChatView(agentClient: agentClient)
            case .live:
                IOSLiveView(
                    data: live,
                    onRefresh: { await agentClient.refreshAll() },
                    onOpenSettings: { settingsPresented = true },
                    agentClient: agentClient
                )
            case .analytics: IOSAnalyticsView(agentClient: agentClient)
            case .code:
                IOSCodeView(
                    data: code,
                    onOpenDetail: { sessionId in
                        pushedScreen = .sessionDetail(sessionId)
                    },
                    onNewSession: { newSessionPresented = true }
                )
                .refreshable {
                    await agentClient.refreshAll()
                }
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
                        .overlay {
                            // JSX active tab has TWO shadow layers — the
                            // first is the elevation shadow above, the
                            // second is `0 0 0 0.5px rgba(0,0,0,0.08)`
                            // (a hairline stroke). Render as overlay.
                            if active {
                                Capsule(style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
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
