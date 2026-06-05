import Foundation
import OSLog
import ClawdmeterShared

/// Vends `UsageWriterProtocol` over an XPC Mach service so the widget
/// extension can pull live usage snapshots from the Mac app. The service
/// name (`UsageWriterMachServiceName`) is App-Group-prefixed so a sandboxed
/// caller is entitled to look it up via its App Group entitlement.
///
/// Lives for the lifetime of `AppRuntime`. Polls go through `AppModel`
/// instances; this object snapshots the latest `UsageData` on demand and
/// hands it back as a `JSONEncoder`-encoded `UsageStore.Envelope`.
@MainActor
final class UsageQueryService: NSObject {

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "UsageQueryService")
    private let runtime: AppRuntime
    private let listener: NSXPCListener
    private let listenerDelegate: ListenerDelegate

    init(runtime: AppRuntime) {
        self.runtime = runtime
        self.listener = NSXPCListener(machServiceName: UsageWriterMachServiceName)
        self.listenerDelegate = ListenerDelegate(runtime: runtime)
        super.init()
        self.listener.delegate = listenerDelegate
        self.listener.resume()
        logger.info("UsageQueryService vending \(UsageWriterMachServiceName, privacy: .public)")
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let runtime: AppRuntime

    init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: UsageWriterProtocol.self)
        newConnection.exportedObject = UsageQueryServer(runtime: runtime)
        newConnection.resume()
        return true
    }
}

/// Per-connection responder. Keeps a weak reference to the runtime so the
/// SwiftUI lifecycle stays the source of truth.
private final class UsageQueryServer: NSObject, UsageWriterProtocol {
    private weak var runtime: AppRuntime?

    init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    // The XPC interface is not @MainActor, but we touch `runtime.*Model.usage`
    // which is `@MainActor`-isolated. Hop synchronously via
    // `DispatchQueue.main.sync`.

    func readSnapshot(
        forProviderID providerID: String,
        reply: @escaping (Data?) -> Void
    ) {
        Task { @MainActor [weak runtime] in
            guard let runtime else { reply(nil); return }
            let model: AppModel?
            switch providerID {
            case "claude": model = runtime.claudeModel
            case "codex":  model = runtime.codexModel
            case "cursor": model = runtime.cursorModel
            default:       model = nil
            }
            reply(model.flatMap { encode(model: $0) })
        }
    }

    func readAllSnapshots(reply: @escaping ([Data]) -> Void) {
        Task { @MainActor [weak runtime] in
            guard let runtime else { reply([]); return }
            let blobs = [runtime.claudeModel, runtime.codexModel, runtime.cursorModel]
                .compactMap { encode(model: $0) }
            reply(blobs)
        }
    }

    @MainActor
    private func encode(model: AppModel) -> Data? {
        guard let usage = model.usage else { return nil }
        let now = Date().timeIntervalSince1970
        let envelope = UsageStore.Envelope(
            version: 2,
            providerID: model.config.id,
            displayName: model.config.displayName,
            usage: usage,
            writtenAt: Int(now),
            writtenAtPrecise: now
        )
        return try? JSONEncoder().encode(envelope)
    }
}
