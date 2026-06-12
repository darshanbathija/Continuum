import SwiftUI
import ClawdmeterShared

/// Settings → Devices → Add cloud (R2 phase 2C).
struct AWSBYOCSettingsView: View {
    @Environment(\.tahoe) private var t
    var client: AgentControlClient?

    @State private var displayName = "AWS Runner"
    @State private var region = "us-east-1"
    @State private var instanceSize: RunnerInstanceSize = .small
    @State private var billingMode: ComputeBillingMode = .onDemand
    @State private var autoStopIdleMinutes = 30
    @State private var awsHealth: ProvisionerHealth?
    @State private var isValidating = false
    @State private var isDeploying = false
    @State private var errorMessage: String?
    @State private var lastProvision: AWSProvisionResponse?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Deploy an AWS EC2 runner in your account. You pay AWS directly.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)

            TextField("Display name", text: $displayName)
            TextField("Region", text: $region)
            Picker("Size", selection: $instanceSize) {
                ForEach(RunnerInstanceSize.allCases, id: \.self) { size in
                    Text(size.displayName).tag(size)
                }
            }
            Picker("Billing", selection: $billingMode) {
                Text("On-demand (~$0.017/hr)").tag(ComputeBillingMode.onDemand)
                Text("Spot (~$0.005/hr)").tag(ComputeBillingMode.spot)
            }
            Stepper("Auto-stop after \(autoStopIdleMinutes) min idle", value: $autoStopIdleMinutes, in: 5...120, step: 5)

            HStack(spacing: 10) {
                Button(isValidating ? "Checking…" : "Validate AWS") {
                    Task { await validateAWS() }
                }
                .buttonStyle(.bordered)
                Button(isDeploying ? "Deploying…" : "Deploy EC2") {
                    Task { await deployAWS() }
                }
                .buttonStyle(.borderedProminent)
            }

            if let awsHealth {
                Text(awsHealth.ok ? "AWS OK: \(awsHealth.accountAlias ?? awsHealth.accountId ?? "connected")" : (awsHealth.message ?? "Invalid credentials"))
                    .font(TahoeFont.body(11))
                    .foregroundStyle(awsHealth.ok ? .green : .red)
            }
            if let lastProvision {
                Text("Launched \(lastProvision.host.cloudResourceId ?? "instance") in \(lastProvision.host.cloudRegion ?? region)")
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(t.fg3)
            }
            if let errorMessage {
                Text(errorMessage).font(TahoeFont.body(11)).foregroundStyle(.red)
            }

            Link("Open CloudFormation stack template", destination: URL(string: "https://github.com/clawdmeter/clawdmeter/blob/main/tools/cloud/clawdmeter-aws-runner.yaml")!)
                .font(TahoeFont.body(11))
        }
    }

    @MainActor
    private func validateAWS() async {
        guard let client else { return }
        isValidating = true
        defer { isValidating = false }
        awsHealth = await client.validateAWSCompute()
        errorMessage = awsHealth?.ok == true ? nil : awsHealth?.message
    }

    @MainActor
    private func deployAWS() async {
        guard let client else { return }
        isDeploying = true
        errorMessage = nil
        defer { isDeploying = false }
        let spec = RunnerSpec(
            region: region,
            instanceSize: instanceSize,
            billingMode: billingMode,
            displayName: displayName,
            autoStopIdleMinutes: autoStopIdleMinutes
        )
        if let response = await client.provisionAWSRunner(spec: spec) {
            lastProvision = response
            await client.refreshExecutionHosts()
        } else {
            errorMessage = client.lastError ?? "Deploy failed."
        }
    }
}
