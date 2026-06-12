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

    static func parse(urlString: String) -> PairingChallenge? {
        PairingChallengeURLParser.parse(urlString: urlString)
    }
}
