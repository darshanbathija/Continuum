import ClawdmeterShared
import Foundation
import PostHog
import SwiftUI

/// Thread-safe screen/tab context for button events fired outside SwiftUI
/// environment (e.g. wrapped `Button` action closures).
enum PostHogScreenContext {
    private static let lock = NSLock()
    private static var currentScreen: String?

    static var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return currentScreen
    }

    static func set(_ screen: String?) {
        lock.lock()
        defer { lock.unlock() }
        currentScreen = screen
        ContinuumAnalytics.currentScreen = screen
    }
}

/// Propagates the active tab/screen into `PostHogScreenContext` for descendants.
struct PostHogScreenScope: ViewModifier {
    let screen: String

    func body(content: Content) -> some View {
        content
            .onAppear { PostHogScreenContext.set(screen) }
            .onDisappear { PostHogScreenContext.set(nil) }
    }
}

extension View {
    func postHogScreenScope(_ screen: String) -> some View {
        modifier(PostHogScreenScope(screen: screen))
    }
}

/// Manual button tracking for SwiftUI (macOS + iOS). PostHog autocapture is
/// UIKit-only; every `Button` action is wrapped via `PostHogButtonTracking.wrap`.
enum PostHogButtonTracking {
    static func wrap(
        _ name: String,
        screen: String? = nil,
        file: StaticString = #file,
        line: UInt = #line,
        _ action: @escaping () -> Void
    ) -> () -> Void {
        {
            tap(name, screen: screen, file: file, line: line)
            action()
        }
    }

    static func tap(
        _ name: String,
        screen: String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard PostHogSetup.isConfigured else { return }
        let resolvedScreen = screen ?? PostHogScreenContext.current
        var props: [String: Any] = [
            "button": name,
            "source": "\(sourceFileName(file)):\(line)",
        ]
        if let resolvedScreen, !resolvedScreen.isEmpty {
            props["screen"] = resolvedScreen
        }
        PostHogSDK.shared.capture("button_tapped", properties: props)
    }

    private static func sourceFileName(_ file: StaticString) -> String {
        let path = String(describing: file)
        return path.split(separator: "/").last.map(String.init) ?? path
    }
}
