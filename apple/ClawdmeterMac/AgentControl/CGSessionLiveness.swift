import Foundation
import CoreGraphics

/// Detects whether the Mac is in a state where `NSOpenPanel.runModal()` will
/// actually be visible to the user. Per A3-A in /plan-eng-review: when iOS
/// posts `/workspaces/open-local` and the Mac is asleep, screen-locked, or
/// at the login screen, the modal would silently sit on a dark screen with
/// no way for the user to see or dismiss it — so we 423 Locked instead and
/// let iOS surface a "Mac is asleep — Wake it" banner.
///
/// Protocol-based so tests can inject mocks. The concrete `LiveCGSession`
/// reads `CGSessionCopyCurrentDictionary` keys; the mock returns a
/// user-set value.
public protocol CGSessionLiveness: Sendable {
    var state: CGSessionLivenessState { get }
}

public enum CGSessionLivenessState: String, Sendable, Equatable {
    /// Session is active, foreground, unlocked. Modal will be visible.
    case awake
    /// Screen is locked or the screensaver is engaged. Modal will land
    /// behind the lock screen.
    case locked
    /// User is at the login window (no session yet) or no console user.
    case loggedOut
    /// We couldn't determine the state — treat as locked to be safe.
    case unknown
}

public struct LiveCGSession: CGSessionLiveness {
    public init() {}

    public var state: CGSessionLivenessState {
        // CGSessionCopyCurrentDictionary returns the console-session info
        // dictionary for the current user. Keys we care about:
        //   - kCGSSessionOnConsoleKey: true when this is the active GUI session
        //   - CGSSessionScreenIsLocked: true when the screen is locked
        //   - CGSSessionScreenLockedTime: present when screen is locked
        guard let raw = CGSessionCopyCurrentDictionary() else {
            return .unknown
        }
        let dict = raw as NSDictionary
        let onConsole = (dict["kCGSSessionOnConsoleKey"] as? Bool) ?? false
        if !onConsole {
            return .loggedOut
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool, locked {
            return .locked
        }
        return .awake
    }
}

/// Test-only mock. Set `currentState` to drive `state` reads.
public final class MockCGSessionLiveness: CGSessionLiveness, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: CGSessionLivenessState

    public init(state: CGSessionLivenessState = .awake) {
        self._state = state
    }

    public func setState(_ state: CGSessionLivenessState) {
        lock.lock()
        defer { lock.unlock() }
        _state = state
    }

    public var state: CGSessionLivenessState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }
}
