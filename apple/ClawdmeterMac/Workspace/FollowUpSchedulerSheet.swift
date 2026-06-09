import SwiftUI
import ClawdmeterShared

/// G15 follow-up scheduler. Lets the user queue a prompt to be sent
/// into a session at a future timestamp. Presented as a `.sheet` from
/// the chat header's overflow menu.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. Owns its
/// own `@State fireAt` + `@State prompt`; everything else is dependency-
/// injected through the constructor. Independent of the parent
/// workspace's @State.
struct FollowUpSchedulerSheet: View {
    let session: AgentSession
    let registry: AgentSessionRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var fireAt: Date = Date().addingTimeInterval(5 * 60)
    @State private var prompt: String = ""

    var body: some View {
        // A6 (foundation): body-invalidation tap. No-op in production.
        BodyInvalidationCounter.bump("FollowUpSchedulerSheet")
        return VStack(alignment: .leading, spacing: 14) {
            Text("Schedule follow-up")
                .font(.system(size: 16, weight: .semibold))
                .accessibilityIdentifier("code.follow-up-sheet.title")
            Text("Sends the prompt as a fresh message into this session at the chosen time.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            DatePicker("Fire at", selection: $fireAt, in: Date()...)
                .datePickerStyle(.field)
                .accessibilityIdentifier("code.follow-up-sheet.fire-at")
            TextField("Prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .accessibilityIdentifier("code.follow-up-sheet.prompt")
            if !session.scheduledFollowUps.isEmpty {
                Divider()
                Text("Pending")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(session.scheduledFollowUps.filter { $0.firedAt == nil }) { up in
                    HStack {
                        Text(up.fireAt, style: .time)
                            .font(.system(size: 11, design: .monospaced))
                        Text(up.prompt)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if up.deliveryPolicy == .requiresConfirmation {
                            Button(action: {
                                Task { @MainActor in
                                    try? await registry.confirmScheduledFollowUp(
                                        sessionId: session.id,
                                        followUpId: up.id,
                                        confirmedBy: "mac-follow-up-sheet-confirm"
                                    )
                                }
                            }) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(PressableButtonStyle())
                            .help("Confirm")
                        }
                        Button(action: {
                            // F2-wire: SwiftUI Button action closures are
                            // sync — wrap the now-async registry call in
                            // a Task. Errors are non-fatal here (failing
                            // to remove a follow-up just means it'll fire
                            // once and self-mark fired; the user can re-
                            // remove it).
                            Task { @MainActor in
                                try? await registry.removeScheduledFollowUp(sessionId: session.id, followUpId: up.id)
                            }
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("code.follow-up-sheet.done")
                Button("Schedule") {
                    let up = ScheduledFollowUp(
                        fireAt: fireAt,
                        prompt: prompt,
                        origin: .scheduledUserFollowUp,
                        createdBy: "mac-follow-up-sheet",
                        deliveryPolicy: .autonomousAfterRestart
                    )
                    // F2-wire: SwiftUI Button action closure is sync —
                    // wrap the now-async registry call. Best-effort:
                    // if the receipt write fails, the user re-clicks.
                    Task { @MainActor in
                        try? await registry.addScheduledFollowUp(sessionId: session.id, followUp: up)
                    }
                    prompt = ""
                    fireAt = Date().addingTimeInterval(5 * 60)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(SessionsV2Theme.accent)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("code.follow-up-sheet.schedule")
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.follow-up-sheet")
    }
}
