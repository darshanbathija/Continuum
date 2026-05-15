import Foundation

/// Common protocol both terminal + event WebSocket channels conform to,
/// so the AgentControlServer can store them homogeneously in a single
/// `wsChannels` table and stop them on shutdown / disconnect.
@MainActor
public protocol WSChannel: AnyObject {
    func start()
    func stop()
}
