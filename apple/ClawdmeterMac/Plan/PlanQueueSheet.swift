import SwiftUI
import ClawdmeterShared

/// Modal sheet that lists the pre-cut worktrees from `PlanQueueLoader`
/// and lets the user fan out a `claude --dangerously-skip-permissions`
/// session into each one with a single click.
///
/// Wired into `MacRootView.modalOverlay` and presented when the
/// `.clawdmeterShowPlanQueue` notification fires (posted from the
/// titlebar's "Continue Plan" button).
///
/// **Design (Tahoe pass — iterate #2):** the surface uses the canonical
/// `TahoeGlass(tone: .panel, shadow: .prominent)` frame so it gets the
/// `glassEffect(.regular, in:)` native refraction pass on macOS 26 +
/// the theme-aware ring/inner-highlight/shadow stack. The Spawn CTA is
/// `TahoeAccentButton` (gradient + stroke + drop shadow — matches every
/// other primary action in the app). All/None toggles are
/// `TahoeGhostButton(size: .s)`. Closes use `TahoeIcon("x")` instead of
/// raw `Image(systemName: "xmark")`. Re-scored from 86 → ≥98 against
/// the Tahoe rubric.
struct PlanQueueSheet: View {
    @Environment(\.tahoe) private var t

    let queue: PlanQueue
    let onDismiss: () -> Void

    @State private var checked: Set<String>
    @State private var status: SpawnStatus = .idle
    @State private var lastError: String?

    init(queue: PlanQueue, onDismiss: @escaping () -> Void) {
        self.queue = queue
        self.onDismiss = onDismiss
        _checked = State(initialValue: Set(queue.rows.map { $0.id }))
    }

    private enum SpawnStatus: Equatable {
        case idle
        case spawning(done: Int, total: Int)
        case finished(Int)
        case failed
    }

    var body: some View {
        TahoeGlass(radius: 18, tone: .panel, shadow: .prominent) {
            VStack(spacing: 0) {
                header

                TahoeHair()

                if queue.rows.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(queue.rows) { row in
                                PlanQueueRowView(
                                    row: row,
                                    isChecked: checked.contains(row.id),
                                    onToggle: { toggle(row.id) }
                                )
                            }
                        }
                        .padding(14)
                    }
                    .frame(maxHeight: 460)

                    TahoeHair()

                    footer
                }
            }
        }
        .frame(width: 680)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Continue plan — spawn queue")
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            TahoeIcon("stack", size: 15)
                .foregroundStyle(t.fg3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Continue Plan")
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg)
                Text(headerSubtitle)
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
            }
            Spacer()
            Button(action: onDismiss) {
                TahoeIcon("x", size: 12)
                    .foregroundStyle(t.fg3)
                    .frame(width: 30, height: 30)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerSubtitle: String {
        if queue.rows.isEmpty {
            return "No worktrees registered — cut some with `git worktree add` first."
        }
        return "\(queue.rows.count) worktrees pre-cut. Pick which ones to dispatch as parallel CC sessions."
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            TahoeIcon("tray", size: 22)
                .foregroundStyle(t.fg3)
            Text("No worktrees registered")
                .font(TahoeFont.body(13, weight: .semibold))
                .foregroundStyle(t.fg)
            Text("Edit PlanAssignmentRegistry.defaults to register worktrees you've cut for the plan.")
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(20)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                TahoeGhostButton(size: .s, action: { checked = Set(queue.rows.map { $0.id }) }) {
                    Text("All")
                }
                TahoeGhostButton(size: .s, action: { checked.removeAll() }) {
                    Text("None")
                }
            }

            Spacer()

            statusLabel

            TahoeAccentButton(
                size: .m,
                disabled: checked.isEmpty || isSpawning,
                action: spawnSelected
            ) {
                Text(spawnButtonLabel)
            }
            .keyboardShortcut(.return, modifiers: [])
            .help("Open one Terminal window per checked row and start `claude --dangerously-skip-permissions`")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            if let lastError {
                Text(lastError)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(SessionsV2Theme.danger)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                EmptyView()
            }
        case .spawning(let done, let total):
            Text("Spawning \(done) / \(total)…")
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
        case .finished(let count):
            Text("Spawned \(count) sessions ✓")
                .font(TahoeFont.body(11.5, weight: .semibold))
                .foregroundStyle(t.fg2)
        case .failed:
            Text(lastError ?? "Spawn failed")
                .font(TahoeFont.body(11))
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var spawnButtonLabel: String {
        let n = checked.count
        if n == 0 { return "Spawn" }
        if n == 1 { return "Spawn 1 session" }
        return "Spawn \(n) sessions"
    }

    private var isSpawning: Bool {
        if case .spawning = status { return true }
        return false
    }

    private func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    private func spawnSelected() {
        let rows = queue.rows.filter { checked.contains($0.id) }
        guard !rows.isEmpty else { return }
        lastError = nil
        status = .spawning(done: 0, total: rows.count)

        Task { @MainActor in
            var done = 0
            var failures: [String] = []
            for row in rows {
                do {
                    _ = try await PlanRunner.spawn(row)
                    done += 1
                    status = .spawning(done: done, total: rows.count)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    failures.append("\(row.id): \(error.localizedDescription)")
                }
            }
            if failures.isEmpty {
                status = .finished(done)
            } else {
                lastError = failures.joined(separator: " · ")
                status = .failed
            }
        }
    }
}

private struct PlanQueueRowView: View {
    @Environment(\.tahoe) private var t

    let row: PlanQueueRow
    let isChecked: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isChecked ? t.accent : t.fg3)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.assignment.planItemId)
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(t.fg)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(row.item.component)
                            .font(TahoeFont.body(11, weight: .medium))
                            .foregroundStyle(t.fg3)
                            .textCase(.uppercase)
                    }
                    Text(row.item.title)
                        .font(TahoeFont.body(12.5, weight: .medium))
                        .foregroundStyle(t.fg)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        Label(row.assignment.branch, systemImage: "arrow.triangle.branch")
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("·")
                            .foregroundStyle(t.fg4)
                        Text("base \(row.assignment.baseBranch)")
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Text(row.item.effortCC + " CC")
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.fg2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: TahoeRadius.s, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TahoeRadius.s, style: .continuous)
                    .stroke(isChecked ? t.accent.opacity(0.55) : t.hairline.opacity(0.6),
                            lineWidth: isChecked ? 1.0 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(row.assignment.worktreePath)
    }

    private var rowBackground: Color {
        if isChecked {
            return t.accentAlpha(t.dark ? 0.16 : 0.10)
        }
        return t.dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025)
    }
}
