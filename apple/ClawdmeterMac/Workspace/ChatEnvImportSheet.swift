import SwiftUI
import ClawdmeterShared

/// Confirmation sheet shown when the Code tab composer contains vendor env
/// variables. Saves into RepoEnvStore via VendorProvisioningService.
struct ChatEnvImportSheet: View {
    @Environment(\.tahoe) private var t

    let detection: ChatEnvPasteDetection
    let workspaceId: UUID
    let envSetIds: Set<UUID>
    let service: VendorProvisioningService?
    let envStore: RepoEnvStore?
    let onSaveAndSend: () -> Void
    let onSendWithoutSaving: () -> Void
    let onCancel: () -> Void

    @State private var previews: [VendorEnvPreviewItem] = []
    @State private var isWorking = false
    @State private var message: String?

    private var candidates: [VendorEnvCandidate] {
        detection.candidates.map { VendorEnvCandidate(key: $0.key, value: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                TahoeIcon("key", size: 18, weight: .bold)
                    .foregroundStyle(t.accent)
                    .frame(width: 34, height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(t.accentAlpha(0.12))
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Save \(detection.vendorDisplayName) env vars?")
                        .font(TahoeFont.body(18, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text("These values look like \(detection.vendorDisplayName) credentials. Save them to this repo's env variables instead of sending them to the model.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Detected")
                    .font(TahoeFont.body(12, weight: .bold))
                    .foregroundStyle(t.fg2)
                ForEach(detection.candidates) { candidate in
                    HStack(spacing: 10) {
                        Text(candidate.key)
                            .font(TahoeFont.mono(11.5, weight: .bold))
                            .foregroundStyle(t.fg)
                        Spacer(minLength: 0)
                        Text("••••••••")
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(t.fg3)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(t.glassTintHi.opacity(0.35))
                    }
                }
            }

            if !previews.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Import preview")
                        .font(TahoeFont.body(12, weight: .bold))
                        .foregroundStyle(t.fg2)
                    ForEach(previews) { item in
                        HStack(spacing: 10) {
                            Text(item.key ?? "line \(item.line)")
                                .font(TahoeFont.mono(11.5, weight: .bold))
                            Spacer(minLength: 0)
                            Text(item.status)
                                .font(TahoeFont.body(10.5, weight: .bold))
                                .foregroundStyle(item.canImport ? .green : .orange)
                        }
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg3)
                    }
                }
            }

            if let message {
                Text(message)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .foregroundStyle(t.fg2)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button("Send without saving") {
                    onSendWithoutSaving()
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
                Button("Save & send") {
                    Task { await saveAndSend() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || service == nil)
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 360)
        .task {
            await previewImport()
        }
    }

    @MainActor
    private func previewImport() async {
        guard let service else { return }
        do {
            let response = try service.previewEnv(
                vendorId: detection.vendorId,
                request: VendorEnvPreviewRequest(
                    currentWorkspaceId: workspaceId,
                    workspaceIds: [workspaceId],
                    candidates: candidates
                )
            )
            previews = response.previews
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func saveAndSend() async {
        guard let service else {
            message = "Env import is unavailable."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try service.importEnv(
                vendorId: detection.vendorId,
                request: VendorEnvImportRequest(
                    currentWorkspaceId: workspaceId,
                    workspaceIds: [workspaceId],
                    selectedSetIds: Array(envSetIds),
                    candidates: candidates,
                    conflictStrategy: .skip
                )
            )
            message = "Saved \(response.importedCount) env var(s) to \(detection.vendorDisplayName)."
            onSaveAndSend()
        } catch {
            message = error.localizedDescription
        }
    }
}
