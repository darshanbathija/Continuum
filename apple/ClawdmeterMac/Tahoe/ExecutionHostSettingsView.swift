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
    @State private var tailscaleTestStatus: String?
    @State private var tailscaleTesting = false

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
            if let tailscaleTestStatus {
                Text(tailscaleTestStatus)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(tailscaleTestStatus.contains("reachable") ? Color.green : t.fg3)
            }
            HStack {
                Button("Cancel") { showAddTailscale = false }
                Button("Test connection") {
                    Task { await testTailscaleConnection() }
                }
                .disabled(tailscaleTesting || tailscaleHostname.isEmpty || pairingToken.isEmpty)
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

            Text("Relay pairing (from VPS `continuum-agent pair-relay` output)")
                .font(TahoeFont.body(12, weight: .semibold))
            TextField("Relay URL (wss://…)", text: $vpsRelayUrl)
            TextField("Session ID (sid)", text: $vpsRelaySid)
            SecureField("Pairing token", text: $vpsRelayToken)
            TextField("Symmetric key (base64url)", text: $vpsRelaySymmetricKey)

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
    private func testTailscaleConnection() async {
        tailscaleTesting = true
        defer { tailscaleTesting = false }
        let host = tailscaleHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !token.isEmpty else {
            tailscaleTestStatus = "Enter hostname and pairing token."
            return
        }
        let port = 21731
        let onTailnet = await TailnetReachability.canReach(hostname: host, port: port)
        guard onTailnet else {
            tailscaleTestStatus = relayAlsoEnabled
                ? "Tailnet unreachable — relay fallback will be used after pairing."
                : "Tailnet unreachable. Enable relay access or join this tailnet."
            return
        }
        let literal = AgentControlClient.urlHostLiteral(host)
        guard let url = URL(string: "http://\(literal):\(port)/health") else {
            tailscaleTestStatus = "Invalid hostname."
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                tailscaleTestStatus = relayAlsoEnabled
                    ? "Tailnet reachable · relay enabled"
                    : "Tailnet reachable"
            } else {
                tailscaleTestStatus = "Health check failed — verify token and daemon."
            }
        } catch {
            tailscaleTestStatus = "Connection failed: \(error.localizedDescription)"
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
        // D fix: the install SSH can run for minutes. Drive it through the
        // async, argv-only ShellRunner so the @MainActor isn't blocked on
        // `waitUntilExit()` (which froze the whole UI). The `await` hops the
        // blocking work off the main actor; we update state after it returns.
        let ssh = ShellRunner.locateBinary("ssh") ?? "/usr/bin/ssh"
        do {
            let result = try await ShellRunner.shared.run(
                executable: ssh,
                arguments: [alias, script],
                timeout: 600
            )
            if result.exitStatus == 0 {
                showAddVPS = false
                errorMessage = nil
            } else {
                errorMessage = "SSH install exited with code \(result.exitStatus)."
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
        let symKey = vpsRelaySymmetricKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !relayUrl.isEmpty, !sid.isEmpty, !token.isEmpty, !symKey.isEmpty else {
            errorMessage = "Display name, relay URL, sid, token, and symmetric key are required."
            return
        }
        let alias = vpsSSHAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = await client.pairRelayExecutionHost(
            PairRelayExecutionHostRequest(
                displayName: name,
                relayUrl: relayUrl,
                sid: sid,
                pairingToken: token,
                derivedSymmetricKeyBase64URL: symKey,
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
