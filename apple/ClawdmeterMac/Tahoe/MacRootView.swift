import SwiftUI
import ClawdmeterShared

/// Tahoe 26 Mac window root — replaces `DashboardView` as the primary
/// SwiftUI scene content. Owns the global `TahoeThemeStore`, paints the
/// wallpaper layer, and hosts the four titlebar tabs (Chat / Usage / Code /
/// Settings) and the menu bar window. Tab routing is purely local — each
/// tab is its own view file under `Tahoe/`.
public struct MacRootView: View {
    public enum Tab: String, CaseIterable, Hashable { case chat, usage, code, settings }

    @State private var theme: TahoeThemeStore
    @State private var tab: Tab

    public init(initialTab: Tab = .chat) {
        _theme = State(initialValue: TahoeThemeStore.loaded())
        _tab = State(initialValue: initialTab)
    }

    public var body: some View {
        ZStack {
            TahoeWallpaperView()
            VStack(spacing: 0) {
                MacTitlebar(active: tab, onTab: { tab = $0 }, theme: theme)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)

                Group {
                    switch tab {
                    case .chat:     MacChatView()
                    case .usage:    MacUsageView()
                    case .code:     MacCodeView()
                    case .settings: MacSettingsView(theme: theme)
                    }
                }
                .padding([.horizontal, .bottom], 10)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1280, minHeight: 820)
        .tahoeTheme(theme)
        .background(theme.appearance == .dark ? Color.black : Color(.sRGB, red: 0.94, green: 0.97, blue: 0.98))
    }
}

// MARK: - Titlebar (shared across all Mac tabs)

/// Floating titlebar — traffic lights chip + tabs chip + ancillary status.
/// Matches the pattern shared by every Mac artboard in the design
/// (mac-chat.jsx, mac-dashboard.jsx, mac-sessions.jsx, mac-settings.jsx).
public struct MacTitlebar: View {
    @Environment(\.tahoe) private var t
    public var active: MacRootView.Tab
    public var onTab: (MacRootView.Tab) -> Void
    public var theme: TahoeThemeStore

    public init(active: MacRootView.Tab, onTab: @escaping (MacRootView.Tab) -> Void, theme: TahoeThemeStore) {
        self.active = active; self.onTab = onTab; self.theme = theme
    }

    public var body: some View {
        HStack(spacing: 10) {
            TahoeGlass(radius: 11, tone: .chip) {
                TahoeTrafficLights()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }

            TahoeGlass(radius: 11, tone: .chip) {
                HStack(spacing: 10) {
                    TahoeDashTab("Chat",     active: active == .chat)     { onTab(.chat) }
                    TahoeDashTab("Usage",    active: active == .usage)    { onTab(.usage) }
                    TahoeDashTab("Code",     active: active == .code)     { onTab(.code) }
                    TahoeDashTab("Settings", active: active == .settings) { onTab(.settings) }
                    Spacer(minLength: 0)
                    secondaryRight
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private var secondaryRight: some View {
        switch active {
        case .chat:
            EmptyView()
        case .usage:
            HStack(spacing: 8) {
                Label {
                    Text("Updated 14s ago")
                        .font(TahoeFont.body(12))
                } icon: {
                    TahoeIcon("refresh", size: 11)
                }
                .foregroundStyle(t.fg2)
                TahoeHair(vertical: true).frame(height: 14)
                TahoeSyncChip(icon: "qr", text: "Sync with iPhone")
            }
        case .code:
            TahoeSyncChip(text: "iPhone paired")
        case .settings:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.1") · synced")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg2)
        }
    }
}
