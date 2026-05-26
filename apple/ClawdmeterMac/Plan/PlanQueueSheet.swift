import SwiftUI
import ClawdmeterShared

/// Modal sheet that lists the pre-cut worktrees from `PlanQueueLoader`
/// and lets the user fan out a `claude --dangerously-skip-permissions`
/// session into each one with a single click.
///
/// Wired into `MacRootView.modalOverlay` and presented when the
/// `.clawdmeterShowPlanQueue` notification fires (posted from the
/// titlebar's "Continue Plan" button).
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
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.24), radius: 34, x: 0, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Continue plan — spawn queue")
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack.fill.badge.plus")
                .font(.system(size: 15, weight: .semibold))
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
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(t.fg3)
                    .frame(width: 24, height: 24)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Close")
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
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .semibold))
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
                Button("All") { checked = Set(queue.rows.map { $0.id }) }
                    .buttonStyle(.plain)
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text("·")
                    .foregroundStyle(t.fg4)
                Button("None") { checked.removeAll() }
                    .buttonStyle(.plain)
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
            }

            Spacer()

            statusLabel

            Button(action: spawnSelected) {
                Text(spawnButtonLabel)
                    .font(TahoeFont.body(12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(spawnButtonBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(checked.isEmpty || isSpawning)
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
                    .foregroundStyle(.red)
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

    private var spawnButtonBackground: Color {
        if checked.isEmpty || isSpawning {
            return t.fg4.opacity(0.6)
        }
        return Color.accentColor
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
                    .foregroundStyle(isChecked ? Color.accentColor : t.fg3)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.assignment.planItemId)
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(t.fg)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(t.hair2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(row.item.component)
                            .font(TahoeFont.body(10.5, weight: .medium))
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
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("·")
                            .foregroundStyle(t.fg4)
                        Text("base \(row.assignment.baseBranch)")
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Text(row.item.effortCC + " CC")
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isChecked ? Color.accentColor.opacity(0.55) : t.hairline.opacity(0.6),
                            lineWidth: isChecked ? 1.0 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(row.assignment.worktreePath)
    }

    private var rowBackground: Color {
        if isChecked {
            return Color.accentColor.opacity(t.dark ? 0.16 : 0.10)
        }
        return t.dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025)
    }
}
