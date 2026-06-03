import SwiftUI
import ClawdmeterShared

/// Live state for the "Setup Trail" — the animated provisioning ribbon shown in
/// an optimistically-opened "+" session while its worktree + agent come up in
/// the background. Each step ends in a *verifiable fact* (branch name, files
/// copied, setup ran) — the thing Conductor leaves implicit.
struct ProvisioningProgress: Equatable {
    enum Step: Int, CaseIterable {
        case worktree, files, setup, agent
    }
    enum StepState: Equatable { case pending, active, done, skipped }

    /// Indexed by `Step.rawValue`. Step 1 (worktree) starts active.
    var states: [StepState] = [.active, .pending, .pending, .pending]
    var branch: String?
    var filesCopied: Int?
    var filesNoop: Bool = false
    var setupRan: Bool = false
    var startedAt: Date = Date()

    func state(_ s: Step) -> StepState { states[s.rawValue] }
    mutating func set(_ s: Step, _ st: StepState) { states[s.rawValue] = st }

    var completed: Int { states.filter { $0 == .done || $0 == .skipped }.count }
    var allDone: Bool { completed == Step.allCases.count }
}

/// The animated provisioning trail. Non-blocking glass ribbon that lives between
/// the transcript and the composer — the composer stays usable the whole time.
@available(macOS 14, *)
struct ProvisioningTrailView: View {
    let progress: ProvisioningProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed = false

    private var accent: Color { SessionsV2Theme.accent }
    private var done: Color { SessionsV2Theme.success }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
                    .padding(.vertical, 8)
                VStack(spacing: 0) {
                    ForEach(ProvisioningProgress.Step.allCases, id: \.self) { step in
                        stepRow(step, isLast: step == .agent)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke((progress.allDone ? done : accent).opacity(0.20), lineWidth: 0.5)
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: progress)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: collapsed)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.allDone ? "Workspace ready" : "Setting up workspace, \(progress.completed) of 4 steps done")
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 9) {
            aggregateRing
            VStack(alignment: .leading, spacing: 1) {
                Text(progress.allDone ? "Workspace ready" : "Setting up workspace")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(progress.completed) of \(ProvisioningProgress.Step.allCases.count)")
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            elapsedLabel
            Button { collapsed.toggle() } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show setup steps" : "Hide setup steps")
        }
    }

    private var aggregateRing: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.001, CGFloat(progress.completed) / 4))
                .stroke(progress.allDone ? done : accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress.allDone {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(done)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var elapsedLabel: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1.0 : 0.2)) { ctx in
            let secs = max(0, ctx.date.timeIntervalSince(progress.startedAt))
            Text(String(format: "%.1fs", secs))
                .font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: step row

    @ViewBuilder
    private func stepRow(_ s: ProvisioningProgress.Step, isLast: Bool) -> some View {
        let st = progress.state(s)
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                node(st)
                if !isLast {
                    Rectangle()
                        .fill((st == .done || st == .skipped) ? accent.opacity(0.45) : Color.white.opacity(0.08))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label(s))
                    .font(.system(size: 12.5, weight: st == .active ? .semibold : .medium))
                    .foregroundStyle(st == .pending ? Color.secondary : Color.primary)
                if let sub = sublabel(s) {
                    Text(sub)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 0)
            Spacer(minLength: 0)
        }
        .frame(minHeight: isLast ? 22 : 38, alignment: .top)
    }

    @ViewBuilder
    private func node(_ state: ProvisioningProgress.StepState) -> some View {
        switch state {
        case .pending:
            Circle().stroke(Color.white.opacity(0.16), lineWidth: 1.5).frame(width: 16, height: 16)
        case .active:
            SetupSpinnerRing()
        case .done:
            ZStack {
                Circle().fill(accent)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 16, height: 16)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .skipped:
            ZStack {
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 1.5)
                Image(systemName: "minus").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
            }
            .frame(width: 16, height: 16)
        }
    }

    // MARK: labels (active = present-progressive, done = the verifiable fact)

    private func label(_ s: ProvisioningProgress.Step) -> String {
        let st = progress.state(s)
        if st == .done || st == .skipped { return doneLabel(s) }
        switch s {
        case .worktree: return "Creating worktree"
        case .files:    return "Copying files"
        case .setup:    return "Running setup"
        case .agent:    return "Starting Codex"
        }
    }

    private func doneLabel(_ s: ProvisioningProgress.Step) -> String {
        switch s {
        case .worktree:
            return "Worktree on \(progress.branch ?? "new branch")"
        case .files:
            if progress.filesNoop { return "No extra files to copy" }
            let n = progress.filesCopied ?? 0
            return n == 1 ? "1 file copied" : "\(n) files copied"
        case .setup:
            return progress.setupRan ? "Setup complete" : "No setup script"
        case .agent:
            return "Codex ready"
        }
    }

    /// Monospace proof / hint sub-line. Branch + count read as confirmation.
    private func sublabel(_ s: ProvisioningProgress.Step) -> String? {
        switch s {
        case .worktree:
            return progress.state(s) == .done ? nil : "git worktree add"
        case .files:
            return progress.state(s) == .pending ? ".env, secrets" : nil
        case .setup:
            return progress.state(s) == .active ? "setup script" : nil
        case .agent:
            return progress.state(s) == .done ? nil : "gpt-5.5 · max"
        }
    }
}

/// Small rotating arc used as the per-step "in progress" node. 0.9s linear loop
/// matches the app-wide spinner cadence (DESIGN.md).
@available(macOS 14, *)
private struct SetupSpinnerRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.26)
            .stroke(SessionsV2Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: SessionsV2Theme.AnimationDuration.spinner).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
    }
}
