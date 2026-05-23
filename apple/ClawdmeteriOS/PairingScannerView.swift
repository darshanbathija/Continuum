import SwiftUI
import AVFoundation
import ClawdmeterShared

/// Full-screen QR scanner. Decodes a `clawdmeter://host:httpPort?token=...&ws=wsPort`
/// payload and hands the fields to the AgentControlClient.
struct PairingScannerView: UIViewControllerRepresentable {

    let onScanned: (PairingChallenge) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onScanned = onScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScanned: ((PairingChallenge) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        /// P2-iOS-3: serial queue that owns every AVCaptureSession state
        /// change. Previously `startRunning()` was on a global queue and
        /// `stopRunning()` ran synchronously on the main thread, which
        /// (a) blocked the UI for ~300ms on stop and (b) raced the
        /// background start. Coordinating all transitions on this serial
        /// queue closes both windows.
        private let sessionQueue = DispatchQueue(label: "com.clawdmeter.ios.pairing.sessionQueue", qos: .userInitiated)

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            setupSession()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            sessionQueue.async { [weak self] in
                guard let self, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            sessionQueue.async { [weak self] in
                guard let self, self.session.isRunning else { return }
                self.session.stopRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        private func setupSession() {
            guard let device = AVCaptureDevice.default(for: .video) else { return }
            guard let input = try? AVCaptureDeviceInput(device: device) else { return }
            if session.canAddInput(input) { session.addInput(input) }

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                if output.availableMetadataObjectTypes.contains(.qr) {
                    output.metadataObjectTypes = [.qr]
                }
            }

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            previewLayer = layer
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr, let value = obj.stringValue else { return }
            guard let challenge = PairingScannerView.parse(urlString: value) else { return }
            sessionQueue.async { [weak self] in
                self?.session.stopRunning()
            }
            onScanned?(challenge)
        }
    }

    /// Parse `clawdmeter://host:httpPort?token=<base64url>&ws=<wsPort>` into
    /// a `PairingChallenge`. Returns nil for unrecognized URLs.
    ///
    /// Audit P1 fix: validate every field. Previously token / designToken
    /// were accepted verbatim and host could be any string — a malicious
    /// printed QR ("Open in Code on this airport Wi-Fi!") could pair the
    /// iPhone with an attacker-chosen host. The defenses:
    ///   - host must look like loopback, Tailscale CGNAT
    ///     (100.64.0.0/10), or `*.ts.net`.
    ///   - ports must fall in 1…65535.
    ///   - tokens must match `^[A-Za-z0-9_-]{16,256}$` (base64url shape).
    static func parse(urlString: String) -> PairingChallenge? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              scheme == "clawdmeter" || scheme == "clawdmeters",
              let host = url.host,
              let httpPort = url.port,
              isAllowedPairingHost(host),
              isValidPort(httpPort)
        else { return nil }
        // v16: `clawdmeters://` is the TLS-preferred scheme. iOS marks
        // the challenge so a future AgentControlClient knows to switch
        // to `https://`. The daemon today still listens on plain HTTP,
        // so we don't act on the flag until server TLS termination
        // ships — but we persist it so the URL parser is forward-compat.
        let useHTTPS = (scheme == "clawdmeters")
        var token: String?
        var wsPort: Int?
        var designPort: Int?
        var designToken: String?
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            for item in items {
                switch item.name {
                case "token":
                    if let v = item.value, isValidPairingToken(v) { token = v }
                case "ws":
                    if let v = item.value, let n = Int(v), isValidPort(n) { wsPort = n }
                case "dp":
                    if let v = item.value, let n = Int(v), isValidPort(n) { designPort = n }
                case "dt":
                    if let v = item.value, isValidPairingToken(v) { designToken = v }
                default: break
                }
            }
        }
        guard let token, let wsPort else { return nil }
        return PairingChallenge(host: host, port: httpPort, wsPort: wsPort, token: token,
                                designPort: designPort, designToken: designToken,
                                useHTTPS: useHTTPS)
    }

    /// Host must be loopback, in Tailscale CGNAT (100.64.0.0/10), or a
    /// MagicDNS hostname under `*.ts.net`. Anything else (public IP,
    /// random domain) is rejected — the daemon listens on Tailscale by
    /// design and there's no legitimate reason to pair with anywhere
    /// else.
    static func isAllowedPairingHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasSuffix(".ts.net") || host.hasSuffix(".tailnet.ts.net") { return true }
        // CGNAT range 100.64.0.0/10 → first octet 100, second 64–127.
        let parts = host.split(separator: ".")
        if parts.count == 4,
           let a = Int(parts[0]), let b = Int(parts[1]),
           let c = Int(parts[2]), let d = Int(parts[3]),
           a == 100, b >= 64, b <= 127, c >= 0, c <= 255, d >= 0, d <= 255 {
            return true
        }
        return false
    }

    static func isValidPort(_ p: Int) -> Bool {
        p >= 1 && p <= 65535
    }

    static func isValidPairingToken(_ s: String) -> Bool {
        // base64url charset; length 16–256 covers SHA-256 hex,
        // 32-byte random tokens, and a generous future budget.
        guard s.count >= 16, s.count <= 256 else { return false }
        for ch in s.unicodeScalars {
            let v = ch.value
            let isAlnum = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let isUrlSafe = v == 0x2D || v == 0x5F  // '-' or '_'
            if !(isAlnum || isUrlSafe) { return false }
        }
        return true
    }
}
