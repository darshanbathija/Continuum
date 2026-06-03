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

/// The animated provisioning trail — a slim **horizontal** glass bar pinned at
/// the TOP of the session. Non-blocking (the composer below stays usable the
/// whole time); each step animates pending → spinner → spring-checkmark and
/// resolves to a fact (branch, N files copied, setup ran, Codex ready).
@available(macOS 14, *)
struct ProvisioningTrailView: View {
    let progress: ProvisioningProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { SessionsV2Theme.accent }
    private var doneColor: Color { SessionsV2Theme.success }
    private var tint: Color { progress.allDone ? doneColor : accent }

    var body: some View {
        HStack(spacing: 12) {
            aggregateRing
            // Horizontal stepper: node + label, connected by a filling line.
            HStack(spacing: 0) {
                ForEach(ProvisioningProgress.Step.allCases, id: \.self) { step in
                    stepView(step)
                    if step != .agent { connector(after: step) }
                }
            }
            Spacer(minLength: 8)
            elapsedLabel
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: progress)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.allDone ? "Workspace ready" : "Setting up workspace, \(progress.completed) of 4 steps done")
    }

    // MARK: leading aggregate ring (overall progress)

    private var aggregateRing: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.001, CGFloat(progress.completed) / 4))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress.allDone {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(doneColor)
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

    // MARK: stepper

    private func stepView(_ s: ProvisioningProgress.Step) -> some View {
        let st = progress.state(s)
        return HStack(spacing: 6) {
            node(st)
            Text(label(s))
                .font(.system(size: 12, weight: st == .active ? .semibold : .medium))
                .foregroundStyle(st == .pending ? Color.secondary : Color.primary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Connecting line between nodes — fills with the accent once the preceding
    /// step is done, so the trail visibly "advances".
    private func connector(after s: ProvisioningProgress.Step) -> some View {
        let st = progress.state(s)
        return Rectangle()
            .fill((st == .done || st == .skipped) ? accent.opacity(0.5) : Color.primary.opacity(0.12))
            .frame(height: 1.5)
            .frame(minWidth: 14, maxWidth: .infinity)
            .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func node(_ state: ProvisioningProgress.StepState) -> some View {
        switch state {
        case .pending:
            Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1.5).frame(width: 16, height: 16)
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
                Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1.5)
                Image(systemName: "minus").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
            }
            .frame(width: 16, height: 16)
        }
    }

    // MARK: labels — active = present-progressive, done/skipped = the fact

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
            if progress.filesNoop { return "No extra files" }
            let n = progress.filesCopied ?? 0
            return n == 1 ? "1 file copied" : "\(n) files copied"
        case .setup:
            return progress.setupRan ? "Setup complete" : "No setup script"
        case .agent:
            return "Codex ready"
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
