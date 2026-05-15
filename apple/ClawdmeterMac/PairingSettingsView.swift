import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ClawdmeterShared

/// Mac Settings pane for the Sessions feature. Shows the pairing QR
/// (host + ports + token), supervisor health, scan-roots editor,
/// and explicit regenerate/revoke buttons for the bearer token.
///
/// Per Codex Round 1 reviewer concern #6 (lost-phone story): regenerate
/// invalidates the iPhone's stored token. Revoke removes the token
/// entirely; the daemon refuses every connection until next launch
/// auto-generates a fresh one.
struct PairingSettingsView: View {

    @ObservedObject var runtime: AppRuntime
    @AppStorage(RepoIndex.scanRootsKey) private var scanRoots: String = ""
    @State private var qrImage: NSImage?
    @State private var tokenForDisplay: String = ""

    init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Group {
                    header("Pair iPhone")
                    pairingPanel
                }

                Divider()

                Group {
                    header("Scan roots")
                    scanRootsPanel
                }

                Divider()

                Group {
                    header("Supervisor")
                    supervisorPanel
                }

                Divider()

                Group {
                    header("Security")
                    securityPanel
                }
            }
            .padding(28)
        }
        .frame(width: 540, height: 600)
        .onAppear {
            refreshQR()
        }
    }

    // MARK: - Subviews

    private func header(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 18, weight: .semibold))
    }

    private var pairingPanel: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan this QR with Clawdmeter on your iPhone.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let httpPort = runtime.agentControlServer.boundPort,
                   let wsPort = runtime.agentControlServer.boundWsPort {
                    KeyValueRow(label: "Host", value: macHost())
                    KeyValueRow(label: "HTTP port", value: "\(httpPort)")
                    KeyValueRow(label: "WS port", value: "\(wsPort)")
                    KeyValueRow(
                        label: "Token",
                        value: String(tokenForDisplay.prefix(8)) + "…",
                        secondary: true
                    )
                } else {
                    Text("Daemon not running")
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let qr = qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.2))
                    .frame(width: 200, height: 200)
            }
        }
    }

    private var scanRootsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comma-separated directories to scan for `.git` repos. Empty by default; common picks: `~/Downloads`, `~/Desktop`, `~/code`.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("e.g. ~/Downloads, ~/code", text: $scanRoots, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .onChange(of: scanRoots) { _, newValue in
                    let roots = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    UserDefaults.standard.set(roots, forKey: RepoIndex.scanRootsKey)
                    Task { await runtime.repoIndex.refresh() }
                }
        }
    }

    private var supervisorPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Restart count: \(runtime.tmuxSupervisor.restartCount)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if runtime.tmuxSupervisor.isRecoveryBlocked {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("tmux unrecoverable — recovery attempts exhausted")
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("Recover") {
                        Task { await runtime.tmuxSupervisor.userInitiatedRecovery() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("tmux server is healthy")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }
        }
    }

    private var securityPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Regenerating the token invalidates every paired device. Revoking removes it entirely — the daemon will refuse every connection until you relaunch Clawdmeter.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Regenerate token") {
                    _ = PairingTokenStore.shared.regenerate()
                    refreshQR()
                }
                Button("Revoke token", role: .destructive) {
                    PairingTokenStore.shared.revoke()
                    refreshQR()
                }
            }
        }
    }

    // MARK: - Helpers

    private func refreshQR() {
        tokenForDisplay = PairingTokenStore.shared.currentToken()
        guard let httpPort = runtime.agentControlServer.boundPort,
              let wsPort = runtime.agentControlServer.boundWsPort
        else {
            qrImage = nil
            return
        }
        let challenge = PairingChallenge(
            host: macHost(),
            port: Int(httpPort),
            wsPort: Int(wsPort),
            token: tokenForDisplay
        )
        let urlString = "clawdmeter://\(challenge.host):\(challenge.port)?token=\(challenge.token)&ws=\(challenge.wsPort)"
        qrImage = generateQR(from: urlString)
    }

    /// Best-effort: read the Tailscale MagicDNS name from `tailscale status`.
    /// Falls back to `Host.current().localizedName`.
    private func macHost() -> String {
        if let result = try? Process.runAndCapture(
            "/opt/homebrew/bin/tailscale", ["status", "--json"]
        ),
           let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
           let selfNode = json["Self"] as? [String: Any],
           let dnsName = selfNode["DNSName"] as? String,
           !dnsName.isEmpty {
            return dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return Host.current().localizedName ?? "localhost"
    }

    private func generateQR(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        // Scale up so the QR is crisp at 200x200.
        let scaleFactor: CGFloat = 10
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 200, height: 200))
    }
}

private struct KeyValueRow: View {
    let label: String
    let value: String
    var secondary: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, design: secondary ? .monospaced : .default))
                .textSelection(.enabled)
        }
    }
}

/// Process helper for the host-name lookup. Throwing variant that returns
/// stdout Data.
private extension Process {
    static func runAndCapture(_ executable: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}
