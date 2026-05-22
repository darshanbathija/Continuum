import Foundation
import SwiftTerm

/// Protocol that abstracts the byte-source behind `MacEmbeddedTerminalView`.
///
/// Two concrete implementations ship today:
/// - `WebSocketDataPlane` — wraps an agent session's tmux pane via the
///   loopback `AgentControlServer` WebSocket. Used for every live agent
///   session's terminal pane.
/// - `TmuxLocalDataPlane` — talks to `TmuxControlClient` directly, no
///   daemon round-trip. Used for the in-process `OpencodeSetupSheet`
///   that hosts `opencode auth login` as a one-shot interactive
///   terminal pane.
///
/// Why a protocol: both planes pipe bytes into the same SwiftTerm
/// `TerminalView` and route keystrokes/resizes the same way. The only
/// thing that differs is the byte transport. Putting that behind a
/// protocol lets the view stay agnostic and makes a future third plane
/// (e.g. a pure SwiftTerm.LocalProcessTerminalView for ephemeral child
/// processes) trivial to add.
///
/// Lifecycle: `connect()` is called once when the SwiftUI NSView is
/// constructed; `disconnect()` is called from `dismantleNSView`. The
/// plane is responsible for kicking off the byte-pumping `Task` and
/// holding a reference to the `TerminalView` it writes into.
@MainActor
public protocol TerminalDataPlane: AnyObject {
    /// Wire the plane to the SwiftTerm view, kick off the byte pump.
    func connect(to terminal: TerminalView)

    /// Cancel the byte pump and any underlying transport (WebSocket
    /// cancel / tmux subscription cancel). Safe to call multiple times.
    func disconnect()

    /// Forward keystrokes from SwiftTerm into the underlying transport.
    /// Each plane is responsible for any encoding the transport
    /// requires (WS tag wrapping, tmux ESC-routing, etc.).
    func sendInput(_ bytes: ArraySlice<UInt8>)

    /// Forward a window-size change from SwiftTerm.
    func sizeChanged(cols: Int, rows: Int)
}
