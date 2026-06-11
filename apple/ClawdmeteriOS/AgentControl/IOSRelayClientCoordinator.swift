// E4 wiring: a thin singleton that:
//
//   - watches `IOSRelayPairingService.phase` for `.readyButNotConnected`,
//   - constructs an `IOSRelayClient` against the persisted pairing
//     record + Keychain key,
//   - calls `start()` so the WebSocket opens as soon as the iPhone has
//     a valid pairing.
//
// The coordinator is NOT a transport router — it doesn't replace
// `iOSChatStore`'s direct-WS path yet. That swap requires the Mac
// daemon to also speak the relay envelope (E3 lands that). Until then
// this coordinator just keeps the relay socket WARM so:
//
//   - iOS's foreground/background lifecycle is exercised end-to-end
//     against a real Cloudflare DO from day one (catches OS-level
//     regressions early);
//   - any inbound APNS-wake decryption path lands on a connected
//     client, no slow first-open in the wake budget;
//   - the iOS daemon can observe `.lastInbound` once E3 starts pushing
//     real plan-approval / chat-frame envelopes through the relay.
//
// Per the E4 task spec ("wherever the iOS app currently uses Tailscale
// to reach the Mac, swap in the relay client when a relay pairing is
// present"), the swap is conditional: if no pairing record exists,
// this coordinator stays idle and the legacy Tailscale path
// (`AgentControlClient`) handles all traffic. If a pairing record
// exists, BOTH paths run side-by-side until E3 promotes the relay to
// the primary transport. This is the "fallback to legacy Tailscale LAN
// mode when relay is unavailable" guarantee from the design doc §1.

import Foundation
import Combine
import OSLog
import ClawdmeterShared

private let coordinatorLogger = Logger(
    subsystem: "com.clawdmeter.ios",
    category: "RelayCoordinator"
)

@MainActor
public final class IOSRelayClientCoordinator: ObservableObject {

    public static let shared = IOSRelayClientCoordinator()

    /// The active relay client, or nil if no pairing has been completed.
    /// Surfaced as `@Published` so a debug overlay can observe state.
    @Published public private(set) var client: IOSRelayClient?

    /// Track B (B1): the single shared multiplex client, constructed ONLY when
    /// `clawdmeter.transport.relayDefault` is on. Stores read this to route their
    /// streams over the relay; nil ⇒ every store uses its direct path
    /// (byte-identical). Independent of the socket lifecycle (keep-warm for APNS
    /// stays governed by `clawdmeter.relay.enabled`), so flipping relayDefault
    /// off never regresses the existing relay socket.
    @Published public private(set) var muxClient: RelayMuxClient?

    /// Track B (B1.7): the shared request/response correlator, built + cleared
    /// alongside muxClient and bound into AgentControlClient.relayRequestClient.
    @Published public private(set) var requestClient: RelayMuxRequestClient?

    private let pairingService: IOSRelayPairingService
    private let store: RelayPairingStore
    private var cancellables: Set<AnyCancellable> = []

    /// Track B (B1): the app's shared AgentControlClient. The coordinator pushes
    /// `muxClient` into `client.relayMux` whenever it changes, so the Shared-side
    /// streams (events + frontier-via-client) route over the relay without
    /// reaching across the module boundary into iOS-only relay types.
    private weak var boundAgentClient: AgentControlClient?
    private var didStart = false

    /// Register the shared AgentControlClient so its `relayMux` tracks the
    /// coordinator's mux client. Call once at app startup.
    public func bindAgentClient(_ client: AgentControlClient) {
        boundAgentClient = client
        client.relayMux = muxClient
        client.relayRequestClient = requestClient
    }

    public init(
        pairingService: IOSRelayPairingService? = nil,
        store: RelayPairingStore = .shared
    ) {
        self.pairingService = pairingService ?? .shared
        self.store = store
    }

    /// Wire up the pairing-service observer. Call once at launch
    /// (`IOSAppBootstrap.finishLaunching`).
    public func start() {
        guard !didStart else { return }
        didStart = true
        // If a pairing already exists at app launch, spin up immediately.
        if pairingService.hasActivePairing {
            spinUpFromPersistedRecord()
        }
        pairingService.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.handlePhaseChange(phase)
            }
            .store(in: &cancellables)
    }

    /// E6 entry point — once APNS routing is in place, the app delegate
    /// forwards push receipts here, which forwards to the client.
    public func handleAPNSWake() {
        client?.connectForAPNSWake()
    }

    /// Tear down the coordinator. Used by `RelayPairingStore.clear()`
    /// callers ("Forget pairing" in iOS Settings).
    public func stop() {
        didStart = false
        cancellables.removeAll()
        client?.stop()
        client = nil
        muxClient?.reset()
        muxClient = nil
        requestClient?.failAll()
        requestClient = nil
        boundAgentClient?.relayMux = nil
        boundAgentClient?.relayRequestClient = nil
    }

    // MARK: - Internal

    private func handlePhaseChange(_ phase: RelayPairingPhase) {
        switch phase {
        case .readyButNotConnected, .keyExchanged:
            if client == nil { spinUpFromPersistedRecord() }
        case .unpaired:
            client?.stop()
            client = nil
            muxClient?.reset()
            muxClient = nil
            requestClient?.failAll()
            requestClient = nil
            boundAgentClient?.relayMux = nil
            boundAgentClient?.relayRequestClient = nil
        case .scanning, .generatingBundle:
            // Mid-flight; don't act yet.
            break
        }
    }

    private func spinUpFromPersistedRecord() {
        guard let record = store.loadRecord() else {
            coordinatorLogger.warning("No persisted pairing record; coordinator idle")
            return
        }
        guard let key = store.loadSymmetricKey(), key.count == 32 else {
            coordinatorLogger.error("Symmetric key missing/short in Keychain — re-pair required")
            return
        }
        guard let config = IOSRelayClientConfig.fromPairingRecord(record, symmetricKey: key) else {
            coordinatorLogger.error("Pairing record lacks peer pubkey; re-pair required")
            return
        }
        // For v1 we send the iPhone's own pubkey from the pairing
        // record as the handshake envelope. The pairing service stored
        // it in `ourEcdhPublicKeyBase64URL`.
        guard let ourPub = base64URLDecodeStrict(record.ourEcdhPublicKeyBase64URL),
              ourPub.count == 32 else {
            coordinatorLogger.error("Our pubkey malformed in pairing record")
            return
        }
        let newClient = IOSRelayClient(
            config: config,
            ourPublicKeyBytes: ourPub
        )
        // Track B (B1): when the relay is the default transport, build the single
        // shared mux client and cross-wire it: its `send` ships frames as
        // op == "mux" via the relay client, and the relay client routes inbound
        // mux frames back into it. The send closure holds the client weakly to
        // avoid a retain cycle. Off ⇒ muxClient stays nil ⇒ stores stay direct.
        if RelayTransportFlag.relayDefaultEnabled {
            let muxSend: RelayMuxClient.SendMux = { [weak newClient] frame in
                guard let payload = try? frame.encoded() else { return }
                try? await newClient?.send(op: RelayMux.op, payload: payload)
            }
            let mux = RelayMuxClient(send: muxSend)
            let reqClient = RelayMuxRequestClient(send: { [weak newClient] frame in
                guard let payload = try? frame.encoded() else { return }
                try? await newClient?.send(op: RelayMux.op, payload: payload)
            })
            newClient.muxClient = mux
            newClient.requestClient = reqClient
            self.muxClient = mux
            self.requestClient = reqClient
            boundAgentClient?.relayMux = mux
            boundAgentClient?.relayRequestClient = reqClient
        }
        self.client = newClient
        newClient.start()
        coordinatorLogger.info("Relay client started (sid prefix=\(record.sid.prefix(8))…, relayDefault=\(RelayTransportFlag.relayDefaultEnabled))")
    }
}

private func base64URLDecodeStrict(_ s: String) -> Data? {
    var padded = s
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 { padded.append("=") }
    return Data(base64Encoded: padded)
}
