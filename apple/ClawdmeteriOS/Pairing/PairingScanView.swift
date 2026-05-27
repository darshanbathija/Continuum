import SwiftUI
import AVFoundation
import ClawdmeterShared

/// E7 (Gate 3 GTM launch blocker): camera-based QR scanner for the new
/// relay-session-token pairing flow.
///
/// Replaces the legacy Tailscale-config scanner at
/// `PairingScannerView.swift` (kept around for the legacy URL paste-
/// sheet which still emits `PairingChallenge`). This view parses the
/// new `clawdmeter-pair://v1/<base64url>` bundle URL via
/// `RelayPairingBundle.decode(fromURL:)`, then hands off to
/// `IOSRelayPairingService.handleScannedURL(_:)` which:
///
///   1. validates every bundle field (charset, TTL, relay-URL allowlist),
///   2. generates an X25519 ephemeral keypair on the iPhone,
///   3. derives the shared symmetric key via HKDF-SHA256(salt=sid,
///      info="clawdmeter.relay.v1"),
///   4. persists the record + key (Application Support + Keychain).
///
/// E7 stops here — the actual relay WebSocket open lives in E4.
public struct PairingScanView: View {

    @ObservedObject var service: IOSRelayPairingService
    var onDone: (Result<RelayPairingRecord, Error>) -> Void

    @State private var pasteSheetPresented: Bool = false
    @State private var capturedError: String?
    @Environment(\.dismiss) private var dismiss

    public init(
        service: IOSRelayPairingService = .shared,
        onDone: @escaping (Result<RelayPairingRecord, Error>) -> Void
    ) {
        self.service = service
        self.onDone = onDone
    }

    public var body: some View {
        ZStack {
            scannerLayer
                .ignoresSafeArea()

            // Halo overlay — a centered viewfinder with brackets at the
            // four corners. Matches the IOSPairingView aesthetic.
            VStack(spacing: 0) {
                Spacer()
                viewfinderOverlay
                Spacer()
                bottomActions
            }
            .padding(.bottom, 28)

            // Top-leading close + top-trailing paste button.
            VStack {
                HStack {
                    Button(action: { onDone(.failure(CancellationError())); dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                    .accessibilityLabel("Cancel pairing")
                    Spacer()
                    Button(action: { pasteSheetPresented = true }) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                    .accessibilityLabel("Paste pairing URL")
                }
                .padding(.horizontal, 16)
                Spacer()
            }
        }
        .onAppear { service.beginScanning() }
        .sheet(isPresented: $pasteSheetPresented) {
            PairingPasteURLSheet(
                isPresented: $pasteSheetPresented,
                onAccept: { url in attempt(urlString: url) }
            )
        }
        .alert("Pairing failed", isPresented: errorAlertBinding) {
            Button("OK") { capturedError = nil }
        } message: {
            Text(capturedError ?? "")
        }
    }

    // MARK: - Overlay

    @ViewBuilder
    private var viewfinderOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
                .frame(width: 280, height: 280)

            ForEach(0..<4) { i in
                bracket(corner: i)
            }

            VStack(spacing: 6) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text("Point at the QR on your Mac")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 240)
        }
    }

    private func bracket(corner: Int) -> some View {
        let top = corner < 2
        let leading = corner % 2 == 0
        return Path { p in
            let s: CGFloat = 28
            p.move(to: CGPoint(x: leading ? 0 : s, y: top ? s : 0))
            p.addLine(to: CGPoint(x: leading ? 0 : s, y: top ? 0 : s))
            p.addLine(to: CGPoint(x: leading ? s : 0, y: top ? 0 : s))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .frame(width: 28, height: 28)
        .offset(
            x: leading ? -140 + 14 : 140 - 14,
            y: top    ? -140 + 14 : 140 - 14
        )
    }

    @ViewBuilder
    private var bottomActions: some View {
        VStack(spacing: 12) {
            Text("Open Clawdmeter on your Mac → Settings → Sessions → Pair iPhone. Then point this camera at the QR.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 28)

            Button(action: { pasteSheetPresented = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                    Text("Paste pairing URL instead")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
    }

    // MARK: - Camera plumbing

    private var scannerLayer: some View {
        ScannerViewControllerRepresentable(
            onScannedURL: attempt(urlString:)
        )
        .background(Color.black)
    }

    // MARK: - Apply

    private func attempt(urlString: String) {
        guard !urlString.isEmpty else { return }
        let ok = service.handleScannedURL(urlString)
        if ok, let record = service.currentRecord {
            onDone(.success(record))
            dismiss()
        } else {
            capturedError = service.lastError ?? "Unrecognized pairing QR."
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { capturedError != nil },
            set: { if !$0 { capturedError = nil } }
        )
    }
}

// MARK: - UIKit camera bridge

/// AVFoundation-based QR scanner — port of the relevant pieces of
/// `PairingScannerView` but emitting raw URL strings (not the legacy
/// `PairingChallenge`). The shared bundle parser is the trust boundary.
private struct ScannerViewControllerRepresentable: UIViewControllerRepresentable {
    let onScannedURL: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onScannedURL = onScannedURL
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScannedURL: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        /// Serial queue that owns every AVCaptureSession state change.
        /// Mirrors PairingScannerView's P2-iOS-3 fix.
        private let sessionQueue = DispatchQueue(
            label: "com.clawdmeter.ios.pairingscan.sessionQueue",
            qos: .userInitiated
        )

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
                  obj.type == .qr,
                  let value = obj.stringValue else { return }
            // Only act on the relay scheme — the legacy scanner handles
            // `clawdmeter://` separately. Anything else falls through to
            // the service's error path so the user sees a clear message.
            sessionQueue.async { [weak self] in
                self?.session.stopRunning()
            }
            onScannedURL?(value)
        }
    }
}

// MARK: - Paste sheet

/// Paste-URL fallback for the case where the camera doesn't work
/// (simulator, accessibility, no camera permission, etc.). Mirrors
/// IOSPairingView's PasteURLSheet but accepts the new bundle URL form.
struct PairingPasteURLSheet: View {
    @Binding var isPresented: Bool
    var onAccept: (String) -> Void

    @State private var pastedURL: String = ""
    @State private var pasteError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Open Clawdmeter on your Mac → Settings → Sessions → Pair iPhone → Copy pairing URL. Then paste it below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(
                    "clawdmeter-pair://v1/…",
                    text: $pastedURL,
                    axis: .vertical
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                if let error = pasteError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Button("Pair") {
                    let trimmed = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Don't double-parse — let the service do the
                    // validation and surface its error.
                    guard !trimmed.isEmpty else {
                        pasteError = "Empty URL."
                        return
                    }
                    onAccept(trimmed)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(SessionsV2Theme.accent)
                .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Paste pairing URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}
