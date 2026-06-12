import SwiftUI
import ClawdmeterShared

/// Settings → Devices: execution host registry (R1 1C).
struct ExecutionHostSettingsView: View {
    @Environment(\.tahoe) private var t
    var client: AgentControlClient?

    @State private var displayName = ""
    @State private var tailscaleHostname = ""
    @State private var pairingToken = ""
    @State private var relayAlsoEnabled = true
    @State private var showAddTailscale = false
    @State private var showAddVPS = false
    @State private var showAddAWS = false
    @State private var vpsDisplayName = ""
    @State private var vpsSSHAlias = ""
    @State private var vpsRelayUrl = ""
    @State private var vpsRelaySid = ""
    @State private var vpsRelayToken = ""
    @State private var vpsRelaySymmetricKey = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let client, client.supportsExecutionHosts {
                ForEach(client.executionHosts) { host in
                    hostRow(host)
                }

                HStack(spacing: 10) {
                    Button("Add Tailscale device") { showAddTailscale = true }
                        .buttonStyle(.bordered)
                    Button("Add VPS") { showAddVPS = true }
                        .buttonStyle(.bordered)
                    Button("Add AWS cloud") { showAddAWS = true }
                        .buttonStyle(.bordered)
                    Button("Refresh") {
                        Task { await client.refreshExecutionHosts() }
                    }
                    .buttonStyle(.bordered)
                }

                if client.executionHosts.contains(where: { $0.kind == .byocAWS }) {
                    ForEach(client.executionHosts.filter { $0.kind == .byocAWS }) { host in
                        HStack {
                            Text(host.cloudResourceId ?? host.displayName)
                                .font(TahoeFont.mono(10))
                            Spacer()
                            Button("Stop") {
                                Task { _ = await client.stopAWSRunner(hostId: host.id) }
                            }
                            Button("Terminate", role: .destructive) {
                                Task { _ = await client.terminateAWSRunner(hostId: host.id) }
                            }
                        }
                    }
                }
            } else {
                Text("Update Clawdmeter on this Mac to wire v30 for multi-device support.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $showAddTailscale) {
            addTailscaleSheet
        }
        .sheet(isPresented: $showAddVPS) {
            addVPSSheet
        }
        .sheet(isPresented: $showAddAWS) {
            AWSBYOCSettingsView(client: client)
                .padding(20)
                .frame(width: 480)
        }
        .task {
            await client?.refreshExecutionHosts()
        }
    }

    private func hostRow(_ host: ExecutionHost) -> some View {
        HStack {
            Circle()
                .fill(host.health == .healthy ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(TahoeFont.body(13, weight: .semibold))
                Text(hostTransportLabel(host))
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg3)
            }
            Spacer()
            if host.kind == .localMac {
                Text("local")
                    .font(TahoeFont.mono(10))
                    .foregroundStyle(t.fg3)
            }
        }
        .padding(.vertical, 6)
    }

    private var addTailscaleSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Tailscale device")
                .font(TahoeFont.body(16, weight: .semibold))
            TextField("Display name", text: $displayName)
            TextField("MagicDNS hostname", text: $tailscaleHostname)
            SecureField("Pairing token", text: $pairingToken)
            Toggle("Also enable relay access (recommended)", isOn: $relayAlsoEnabled)
            HStack {
                Button("Cancel") { showAddTailscale = false }
                Spacer()
                Button("Add") {
                    Task { await submitTailscaleHost() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var addVPSSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add VPS via SSH")
                .font(TahoeFont.body(16, weight: .semibold))
            TextField("Display name", text: $vpsDisplayName)
            TextField("SSH alias (~/.ssh/config)", text: $vpsSSHAlias)
            Text("Runs: ssh alias 'curl -fsSL …/install-linux.sh | bash'")
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg3)

            Divider()

            Text("Relay pairing (from VPS `continuum-agent pair` output)")
                .font(TahoeFont.body(12, weight: .semibold))
            TextField("Relay URL (wss://…)", text: $vpsRelayUrl)
            TextField("Session ID (sid)", text: $vpsRelaySid)
            SecureField("Pairing token", text: $vpsRelayToken)
            TextField("Symmetric key (optional, base64url)", text: $vpsRelaySymmetricKey)

            HStack {
                Button("Cancel") { showAddVPS = false }
                Spacer()
                Button("Install") {
                    Task { await bootstrapVPS() }
                }
                Button("Pair relay") {
                    Task { await submitRelayHost() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func hostTransportLabel(_ host: ExecutionHost) -> String {
        switch host.kind {
        case .localMac: return "This Mac"
        case .tailscaleHost:
            let relay = host.relayAlsoEnabled ? " + relay" : ""
            return (host.tailscaleHostname ?? "tailnet") + relay
        case .vps: return "VPS · relay"
        case .remoteMac: return "Remote Mac"
        case .byocAWS: return "AWS (R2)"
        case .byocRailway: return "Railway"
        }
    }

    @MainActor
    private func submitTailscaleHost() async {
        guard let client else { return }
        let ok = await client.pairTailscaleExecutionHost(
            PairTailscaleExecutionHostRequest(
                displayName: displayName,
                tailscaleHostname: tailscaleHostname,
                port: 21731,
                pairingToken: pairingToken,
                relayAlsoEnabled: relayAlsoEnabled
            )
        )
        if ok != nil {
            showAddTailscale = false
            displayName = ""
            tailscaleHostname = ""
            pairingToken = ""
            errorMessage = nil
        } else {
            errorMessage = client.lastError ?? "Could not add device."
        }
    }

    @MainActor
    private func bootstrapVPS() async {
        let alias = vpsSSHAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else {
            errorMessage = "Enter an SSH alias."
            return
        }
        let script = "curl -fsSL https://raw.githubusercontent.com/clawdmeter/clawdmeter/main/tools/continuum-agent/install-linux.sh | bash"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [alias, script]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                showAddVPS = false
                errorMessage = nil
            } else {
                errorMessage = "SSH install exited with code \(process.terminationStatus)."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func submitRelayHost() async {
        guard let client else { return }
        let name = vpsDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayUrl = vpsRelayUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let sid = vpsRelaySid.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = vpsRelayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !relayUrl.isEmpty, !sid.isEmpty, !token.isEmpty else {
            errorMessage = "Display name, relay URL, sid, and token are required."
            return
        }
        let alias = vpsSSHAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let symKey = vpsRelaySymmetricKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = await client.pairRelayExecutionHost(
            PairRelayExecutionHostRequest(
                displayName: name,
                relayUrl: relayUrl,
                sid: sid,
                pairingToken: token,
                derivedSymmetricKeyBase64URL: symKey.isEmpty ? nil : symKey,
                sshHostAlias: alias.isEmpty ? nil : alias
            )
        )
        if host != nil {
            showAddVPS = false
            resetVPSForm()
            errorMessage = nil
        } else {
            errorMessage = client.lastError ?? "Could not pair relay host."
        }
    }

    private func resetVPSForm() {
        vpsDisplayName = ""
        vpsSSHAlias = ""
        vpsRelayUrl = ""
        vpsRelaySid = ""
        vpsRelayToken = ""
        vpsRelaySymmetricKey = ""
    }
}
