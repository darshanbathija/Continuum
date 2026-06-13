import SwiftUI

/// "Continue on…" handoff picker (R1 1D).
public struct HandoffExecutionHostSheet: View {
    @ObservedObject public var client: AgentControlClient
    public let sessionId: UUID
    public let currentHostId: UUID?
    public let onDismiss: () -> Void

    @State private var selectedHostId: UUID?
    @State private var isHandingOff = false
    @State private var errorMessage: String?

    public init(
        client: AgentControlClient,
        sessionId: UUID,
        currentHostId: UUID?,
        onDismiss: @escaping () -> Void
    ) {
        self.client = client
        self.sessionId = sessionId
        self.currentHostId = currentHostId
        self.onDismiss = onDismiss
    }

    private var candidateHosts: [ExecutionHost] {
        client.executionHosts.filter { host in
            if let currentHostId, host.id == currentHostId { return false }
            return host.kind != .localMac
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Work will continue on the selected device. Your Mac can sleep.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("Continue on") {
                    if candidateHosts.isEmpty {
                        Text("No remote devices registered. Add one in Settings → Devices.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Device", selection: Binding(
                            get: { selectedHostId ?? candidateHosts.first?.id ?? UUID() },
                            set: { selectedHostId = $0 }
                        )) {
                            ForEach(candidateHosts) { host in
                                Text(host.displayName).tag(host.id)
                            }
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Continue on…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isHandingOff ? "Handing off…" : "Continue") {
                        Task { await performHandoff() }
                    }
                    .disabled(isHandingOff || candidateHosts.isEmpty)
                }
            }
            .task {
                await client.refreshExecutionHosts()
                selectedHostId = candidateHosts.first?.id
            }
        }
    }

    @MainActor
    private func performHandoff() async {
        guard let targetId = selectedHostId ?? candidateHosts.first?.id else { return }
        isHandingOff = true
        errorMessage = nil
        defer { isHandingOff = false }
        if let _ = await client.handoffSession(id: sessionId, to: targetId) {
            onDismiss()
        } else {
            errorMessage = client.lastError ?? "Handoff failed."
        }
    }
}
