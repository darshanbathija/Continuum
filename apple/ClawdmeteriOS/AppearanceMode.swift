import SwiftUI

/// User-selectable interface theme for the iPhone app. Stored under
/// `clawdmeter.appearance` so SettingsView writes once and ContentView's
/// `preferredColorScheme` modifier picks it up everywhere — the TabView,
/// every sheet, every NavigationStack inherits.
///
/// `.system` (default) defers to iOS Settings → Display → Appearance.
/// `.light` / `.dark` pin the app regardless of system state.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var systemIcon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// Resolved SwiftUI color scheme. `.system` returns nil so
    /// `.preferredColorScheme(nil)` lets the system theme through.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
