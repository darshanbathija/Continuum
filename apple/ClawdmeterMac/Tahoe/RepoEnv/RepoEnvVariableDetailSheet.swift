import SwiftUI
import ClawdmeterShared

struct RepoEnvVariableDetailSheet: View {
    @Environment(\.tahoe) private var t

    let variable: RepoEnvVariableRecord
    let workspaces: [CodeWorkspaceRecord]
    let envStore: RepoEnvStore?
    let selectedWorkspaceId: UUID?
    let onReveal: () throws -> String
    let onChanged: () -> Void
    let onClose: () -> Void

    @State private var revealedValue: String?
    @State private var revealError: String?
    @State private var assignmentError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(variable.key)
                        .font(TahoeFont.mono(18, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text("\(variable.kind.displayName) · \(variable.scope.displayName)")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                }
                Spacer()
                Button(action: ContinuumAnalytics.wrapButton("repo_env_detail_close", onClose)) {
                    TahoeIcon("x", size: 12, weight: .bold)
                }
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailSummary
                    assignmentMatrix
                    auditTrail
                }
                .padding(.bottom, 18)
            }
        }
        .padding(24)
    }

    private var detailSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Value")
                .font(TahoeFont.body(12, weight: .bold))
                .foregroundStyle(t.fg2)
            HStack {
                Text(revealedValue ?? "••••••••")
                    .font(TahoeFont.mono(12, weight: .semibold))
                    .foregroundStyle(revealedValue == nil ? t.fg3 : t.fg)
                    .lineLimit(3)
                Spacer()
                Button(revealedValue == nil ? "Reveal" : "Hide", action: ContinuumAnalytics.wrapButton("repo_env_detail_toggle_reveal", {
                    if revealedValue == nil {
                        revealValue()
                    } else {
                        revealedValue = nil
                    }
                }))
                .buttonStyle(.bordered)
            }
            if let note = variable.note, !note.isEmpty {
                Text(note)
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            }
            if let revealError {
                Text(revealError)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.accentAlpha(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(t.hairline, lineWidth: 1)
        }
    }

    private var assignmentMatrix: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assignment Matrix")
                .font(TahoeFont.body(12, weight: .bold))
                .foregroundStyle(t.fg2)
            if let assignmentError {
                Text(assignmentError)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(.red)
            }
            ForEach(workspaces) { workspace in
                let sets = envStore?.sets(for: workspace.id) ?? []
                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.repoDisplayName)
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(workspace.id == selectedWorkspaceId ? t.accent : t.fg2)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(sets) { set in
                            Toggle(set.name, isOn: Binding(
                                get: {
                                    envStore?.assignment(variableId: variable.id, workspaceId: workspace.id, setId: set.id)?.isEnabled == true
                                },
                                set: { enabled in
                                    do {
                                        try envStore?.setAssignment(variableId: variable.id, workspaceId: workspace.id, setId: set.id, enabled: enabled)
                                        assignmentError = nil
                                        onChanged()
                                    } catch {
                                        assignmentError = error.localizedDescription
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .font(TahoeFont.body(11.5))
                        }
                    }
                }
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.accentAlpha(0.025))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(t.hairline, lineWidth: 1)
                }
            }
        }
    }

    private var auditTrail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audit")
                .font(TahoeFont.body(12, weight: .bold))
                .foregroundStyle(t.fg2)
            let events = envStore?.auditEvents(for: variable.id) ?? []
            if events.isEmpty {
                Text("No audit events yet.")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
            } else {
                ForEach(events.prefix(10)) { event in
                    HStack(spacing: 10) {
                        Text(event.action.rawValue)
                            .font(TahoeFont.body(10.5, weight: .bold))
                            .foregroundStyle(t.accent)
                            .frame(width: 92, alignment: .leading)
                        Text(event.message)
                            .font(TahoeFont.body(11.5))
                            .foregroundStyle(t.fg2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(relative(event.createdAt))
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg4)
                    }
                }
            }
        }
    }

    private func revealValue() {
        do {
            revealedValue = try onReveal()
            revealError = nil
        } catch {
            revealError = error.localizedDescription
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
