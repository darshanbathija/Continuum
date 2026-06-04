#if os(macOS)
import Foundation

/// Cross-process query API. The Mac app vends an `NSXPCListener` against a
/// Mach service name prefixed with our App Group identifier. The widget
/// extension connects via `NSXPCConnection(machServiceName:)` and pulls the
/// current usage snapshots directly from the Mac app's in-memory state.
///
/// Why this exists: macOS Tahoe's sandbox kernel refuses cross-sandbox-principal
/// reads of App Group container files, AND `cfprefsd` refuses cross-sandbox
/// surfacing of App Group `UserDefaults`. Routing the query through a Mach
/// service the Mac app vends sidesteps both — the file system never enters
/// the picture, and Mach-service lookup is the documented App Group IPC path.
///
/// The Mach service name must start with `<group-id>.` for sandboxed callers
/// to be able to look it up via their App Group entitlement.
@objc public protocol UsageWriterProtocol {
    /// Read the snapshot for `providerID`. Reply data is a JSON-encoded
    /// `UsageStore.Envelope`, or `nil` if the Mac app hasn't polled that
    /// provider yet this session.
    func readSnapshot(
        forProviderID providerID: String,
        reply: @escaping (Data?) -> Void
    )

    /// All snapshots — used by the combined widget.
    func readAllSnapshots(reply: @escaping ([Data]) -> Void)
}

/// Mach service name the Mac app vends `UsageWriterProtocol` at. The
/// `group.<team>.<bundle>.` prefix is required for sandboxed callers (e.g.
/// the widget extension) to be entitled to look it up via App Group access.
public let UsageWriterMachServiceName = "group.LRL8MRH6B4.ai.continuum.UsageQuery"
#endif // os(macOS)
