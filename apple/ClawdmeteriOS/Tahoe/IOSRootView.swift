import SwiftUI
import ClawdmeterShared

/// Tahoe 26 iOS root — owns the global `TahoeThemeStore` and routes
/// between the four tabs (Chat / Live / Analytics / Code). Ports the
/// `ios-shell.jsx::IOSTabBar` floating glass capsule.
public struct IOSRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var theme: TahoeThemeStore
    @State private var tab: Tab
    @State private var pushedScreen: Screen?
    @State private var newSessionPresented: Bool = false
    @State private var settingsPresented: Bool = false
    /// First-run AI data-sharing consent gate (App Store 5.1.1(i)/5.1.2(i)).
    @State private var showConsent: Bool = false
    @StateObject private var presentationStore: SessionPresentationStore
    // v0.27.0: focusedCodeRepoKey state is unused now that the Design
    // → Code handoff is gone. Kept as a placeholder for future
    // repo-pre-selection work from other entry points.
    @State private var focusedCodeRepoKey: String?

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
    /// v0.26.2 review: outbox is owned by `ClawdmeteriOSApp` and
    /// observed here. Previously held as `@StateObject` here, which
    /// was per-WindowGroup-scene on iPad — multiple windows each got
    /// their own outbox, racing on the persisted `outbox.json`.
    @ObservedObject private var outbox: MobileCommandOutbox
    /// E7: relay pairing service. Drives `unpaired → scanning →
    /// readyButNotConnected`. The unpaired banner now considers
    /// EITHER the legacy AgentControlClient config (Tailscale) OR a
    /// persisted relay record — a user paired via relay still gets
    /// the connected experience even though `agentClient.isConfigured`
    /// stays false until E4 lands the actual relay transport.
    @ObservedObject private var relayService: IOSRelayPairingService
    private let screenshotDemo: Bool

    public init(usageModel: UsageModel, agentClient: AgentControlClient, outbox: MobileCommandOutbox) {
        self.usageModel = usageModel
        self.agentClient = agentClient
        self.outbox = outbox
        self.relayService = .shared
        let args = ProcessInfo.processInfo.arguments
        let demo = args.contains("--ios-code-demo")
        self.screenshotDemo = demo
        // Gate the app behind the AI data-sharing disclosure until the user
        // agrees (skipped in screenshot-demo mode). Persisted → one-time.
        _showConsent = State(initialValue: !demo && !AIDataSharingConsent.hasConsented)
        _theme = State(initialValue: TahoeThemeStore.loaded())
        _tab = State(initialValue: demo ? .code : .chat)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        _presentationStore = StateObject(wrappedValue: SessionPresentationStore(
            storeURL: SessionPresentationStore.defaultStoreURL(appSupportDirectory: appSupport)
        ))
        if demo, args.contains("--ios-code-demo-detail") {
            #if DEBUG
            _pushedScreen = State(initialValue: .sessionDetail(AgentControlClient.codeTabVerificationSessionId))
            #else
            _pushedScreen = State(initialValue: nil)
            #endif
        } else {
            _pushedScreen = State(initialValue: nil)
        }
    }

    public var body: some View {
        let live = usageModel.tahoeLive
        let code = agentClient.tahoeCode
        let useCodeReferenceTheme = usesCodeReferenceTheme
        let activeTheme = useCodeReferenceTheme ? Self.iosCodeReferenceTheme : theme
        let activeTokens = TahoeTokens.make(from: activeTheme)
        // v0.22.5: unpaired banner stays visible across every tab so
        // first-launch users always have an actionable path to
        // pairing. Was: only LiveGaugesHeader (inside Analytics tab)
        // surfaced a CTA — Chat/Code tabs left users staring at a
        // blank "not connected" screen with no flow forward.
        //
        // E7: also hide the banner once the user has a relay pairing
        // record — even though the relay socket itself is E4's job,
        // the pairing UX is "done" the moment the keys exchanged. UI
        // surfaces should treat both transports as "paired" for the
        // empty-state banner purpose.
        let isUnpaired = !screenshotDemo
            && !agentClient.isConfigured
            && !relayService.hasActivePairing
        // Extra bottom clearance when banner is visible so content
        // doesn't slide under it.
        let bottomClearance: CGFloat = isUnpaired ? 168 : 92
        return ZStack {
            TahoeWallpaperView()
            contentView(live: live, code: code)
                .padding(.bottom, bottomClearance)
            if pushedScreen == nil {
                VStack(spacing: 12) {
                    if isUnpaired {
                        IOSUnpairedBanner(
                            onPair: { pushedScreen = .pairing }
                        )
                        .padding(.horizontal, 16)
                    }
                    IOSTabBar(tab: $tab)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .background(activeTokens.pageBg)
        .tahoeTheme(activeTheme)
        // P1 fix: pull live session data on first appearance and whenever
        // we return to the foreground. Without this, the daemon-mirrored
        // session list stays empty until the user interacts with the Mac.
        .task {
            await agentClient.refreshAll()
            agentClient.startDesktopEventSync()
            PostHogScreenTracking.screen(tab.rawValue.capitalized)
        }
        .onChange(of: tab) { _, newTab in
            PostHogScreenTracking.screen(newTab.rawValue.capitalized)
        }
        .onChange(of: pushedScreen) { _, screen in
            switch screen {
            case .pairing:
                PostHogScreenTracking.screen("Pairing")
            case .sessionDetail:
                PostHogScreenTracking.screen("Session Detail")
            case nil:
                PostHogScreenTracking.screen(tab.rawValue.capitalized)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await agentClient.refreshAll()
                    agentClient.startDesktopEventSync()
                }
            case .background:
                agentClient.stopDesktopEventSync()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $newSessionPresented) {
            NewSessionSheet(client: agentClient, isPresented: $newSessionPresented)
        }
        .sheet(isPresented: $settingsPresented) {
            // v0.22.29: pass agentClient so SettingsView can surface
            // Pair-with-Mac (Scan QR + Paste URL + Forget pairing).
            SettingsView(model: usageModel, agentClient: agentClient, presentationStore: presentationStore)
        }
        // Required AI data-sharing consent — covers everything on first launch;
        // nothing is sent to a provider until the user accepts (non-dismissible).
        .fullScreenCover(isPresented: $showConsent) {
            AIDataSharingConsentView(onAgree: { showConsent = false })
        }
    }

    private var usesCodeReferenceTheme: Bool {
        switch pushedScreen {
        case .sessionDetail:
            return true
        case .pairing:
            return false
        case nil:
            return tab == .code
        }
    }

    @MainActor
    private static var iosCodeReferenceTheme: TahoeThemeStore {
        TahoeThemeStore(
            appearance: .light,
            surface: .translucent,
            accent: .halo,
            wallpaper: .graphite,
            glassIntensity: 95,
            providerFocus: .claude
        )
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
                outbox: outbox,
                sessionId: id,
                data: code,
                presentationStore: presentationStore,
                onOpenSession: { nextId in
                    pushedScreen = .sessionDetail(nextId)
                },
                onBack: { pushedScreen = nil }
            )
        case nil:
            switch tab {
            case .chat:
                IOSChatV2View(agentClient: agentClient, outbox: outbox)
                    .postHogScreenScope("chat")
            case .live:
                IOSLiveView(
                    data: live,
                    enabledProviderIDs: usageModel.enabledProviderIDs,
                    secondaryAccounts: usageModel.secondaryAccounts,
                    onRefresh: { await agentClient.refreshAll() },
                    onOpenSettings: { settingsPresented = true },
                    agentClient: agentClient
                )
                .postHogScreenScope("live")
            case .analytics:
                // v0.14.0 (plan v2.1 D1): fold Live gauges into Analytics
                // as a permanent header. Settings sheet trigger moves here
                // so the gear that used to live in the Live tab still works.
                IOSAnalyticsView(usageModel: usageModel, agentClient: agentClient) {
                    LiveGaugesHeader(
                        model: usageModel,
                        agentClient: agentClient,
                        showingSettings: $settingsPresented
                    )
                } onPairWithDesktop: {
                    pushedScreen = .pairing
                }
                .postHogScreenScope("analytics")
            case .code:
                // v0.22.30: drop `focusedRepoKey:` — IOSCodeView init
                // doesn't declare it yet (the parallel-agent's repo-
                // focus refactor is in-flight elsewhere). Re-adding
                // once IOSCodeView's signature catches up.
                IOSCodeView(
                    data: code,
                    onOpenDetail: { sessionId in
                        pushedScreen = .sessionDetail(sessionId)
                    },
                    onNewSession: { newSessionPresented = true },
                    agentClient: agentClient,
                    outbox: outbox,
                    presentationStore: presentationStore,
                    onPairWithDesktop: { pushedScreen = .pairing }
                )
                .refreshable {
                    await agentClient.refreshAll()
                }
                .postHogScreenScope("code")
            }
        }
    }
}

// MARK: - Tab Bar

public struct IOSTabBar: View {
    @Environment(\.tahoe) private var t
    @Binding var tab: IOSRootView.Tab

    // v0.14.0 (plan v2.1 D1): Live folds into Analytics as a permanent
    // header; tab bar shrinks to Chat / Analytics / Code (3 items after
    // v0.27.0's Design strip).
    // The `.live` enum case stays for binary-compat with code that
    // references it; deep-link from elsewhere still routes there but
    // it's no longer surfaced in the tab bar. Full LiveGaugesHeader →
    // Analytics integration is tracked as a follow-up (see plan T6).
    private let items: [(IOSRootView.Tab, String, String)] = [
        (.chat,      "Chat",      "sparkles"),
        (.live,      "Live",      "moon"),
        (.analytics, "Analytics", "diff"),
        (.code,      "Code",      "chat"),
    ]

    public var body: some View {
        TahoeGlass(radius: 999, tone: .raised) {
            HStack(spacing: 4) {
                ForEach(items, id: \.0) { (key, label, icon) in
                    let active = tab == key
                    Button(action: ContinuumAnalytics.wrapButton("tab_\(key.rawValue)", { tab = key })) {
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
        Button(action: ContinuumAnalytics.wrapButton("round_icon_\(icon)", action)) {
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

// MARK: - Unpaired banner (v0.22.5)

/// Glass card pinned above the floating tab bar whenever the
/// AgentControlClient hasn't received a pairing token yet. Solves the
/// "Chat/Code tabs are blank with no flow forward" feedback —
/// every tab now has a visible "Pair with Mac" CTA the user can act on
/// without hunting through Settings or the Analytics tab's
/// LiveGaugesHeader (which is where the only previous CTA lived).
public struct IOSUnpairedBanner: View {
    @Environment(\.tahoe) private var t
    var onPair: () -> Void

    public init(onPair: @escaping () -> Void) {
        self.onPair = onPair
    }

    public var body: some View {
        TahoeGlass(radius: 8, tone: .raised) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(t.accentAlpha(0.18))
                    TahoeIcon("qr", size: 18).foregroundStyle(t.accent)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Not paired to a Mac")
                        .font(TahoeFont.body(13.5, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text("Tahoe surfaces fall back to demo data until you pair.")
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg3)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: ContinuumAnalytics.wrapButton("pair_with_mac", onPair)) {
                    Text("Pair with Mac")
                        .font(TahoeFont.body(12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background {
                            Capsule().fill(LinearGradient(
                                colors: [t.accent, t.accentDeepC],
                                startPoint: .top, endPoint: .bottom
                            ))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pair with Mac")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }
}
