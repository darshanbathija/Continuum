import SwiftUI
import Combine
import ClawdmeterShared

// MARK: - Pure visibility logic (the testable unit)

/// Three states the titlebar chip can be in. Translocation wins over
/// update-available because a translocated user can't follow the
/// drag-to-Applications flow anyway — surfacing the upgrade prompt
/// would just nag them forever with no way to act on it.
enum ChipState: Equatable {
    case hidden
    case updateAvailable(version: String)
    case translocated
}

/// Pure function — derives the chip's visibility from the coordinator's
/// current state. Extracted from the view body so unit tests can assert
/// the state-machine behavior without spinning up SwiftUI.
@MainActor
func chipState(_ coordinator: UpdateCoordinator?) -> ChipState {
    guard let coordinator else { return .hidden }
    if coordinator.isTranslocated { return .translocated }
    guard let update = coordinator.availableUpdate,
          let version = GitHubReleaseConstants.parseVersion(fromTag: update.tagName)
    else { return .hidden }
    return .updateAvailable(version: version)
}

// MARK: - UpdateChip (titlebar pill)

/// Titlebar chip that surfaces update availability. Self-hides when
/// the coordinator is nil (Preview path) or when there's nothing to
/// say. Click opens a popover with details and actions.
struct UpdateChip: View {
    @ObservedObject var coordinator: UpdateCoordinatorObservable
    @State private var popoverPresented: Bool = false

    /// Wrapper because SwiftUI's `@ObservedObject` can't bind to an
    /// optional. Callers pass `UpdateCoordinator?`; we wrap it.
    init(coordinator: UpdateCoordinator?) {
        self.coordinator = UpdateCoordinatorObservable(wrapped: coordinator)
    }

    var body: some View {
        switch chipState(coordinator.wrapped) {
        case .hidden:
            EmptyView()
        case .updateAvailable(let version):
            chipButton(
                label: "Update \(version)",
                icon: "arrow.down.circle.fill",
                tint: Theme.accent
            )
        case .translocated:
            chipButton(
                label: "Move to Applications",
                icon: "exclamationmark.triangle.fill",
                tint: Theme.statusWarning
            )
        }
    }

    @ViewBuilder
    private func chipButton(label: String, icon: String, tint: Color) -> some View {
        Button(action: { popoverPresented.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.14))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .help(helpText(for: label))
        .popover(isPresented: $popoverPresented, arrowEdge: .bottom) {
            UpdatePopoverContent(coordinator: coordinator.wrapped)
                .frame(width: 380)
        }
    }

    private func helpText(for label: String) -> String {
        if label.hasPrefix("Move to") {
            return "Continuum is running from a temporary location. Move it to /Applications to enable updates."
        }
        return "A new version of Clawdmeter is available — click for details."
    }
}

// MARK: - UpdatePopoverContent

/// Popover body. Renders one of three states depending on the
/// coordinator's snapshot at open time. Re-reads `coordinator` so a
/// background check that lands while the popover is open updates the
/// UI live.
struct UpdatePopoverContent: View {
    @ObservedObject var coordinator: UpdateCoordinatorObservable

    init(coordinator: UpdateCoordinator?) {
        self.coordinator = UpdateCoordinatorObservable(wrapped: coordinator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch chipState(coordinator.wrapped) {
            case .translocated:
                translocatedBody
            case .updateAvailable(let version):
                updateAvailableBody(version: version)
            case .hidden:
                // The chip wouldn't be visible to open the popover in
                // this state, but render a sane default just in case.
                upToDateBody
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Update-available state

    @ViewBuilder
    private func updateAvailableBody(version: String) -> some View {
        Text("Continuum \(version) is available")
            .font(.system(size: 15, weight: .semibold))

        if let release = coordinator.wrapped?.availableUpdate {
            if let name = release.name, !name.isEmpty, name != release.tagName {
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(renderMarkdown(release.body ?? "_No release notes provided._"))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 280)
        }

        HStack(spacing: 8) {
            Button(action: openInBrowser) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download in Browser")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)

            Button("Later", action: dismiss)
                .controlSize(.large)
                .buttonStyle(.bordered)
        }

        HStack {
            Spacer()
            Button(action: checkAgain) {
                HStack(spacing: 4) {
                    if coordinator.wrapped?.isCheckingForUpdates == true {
                        ProgressView().controlSize(.small)
                    }
                    Text(coordinator.wrapped?.isCheckingForUpdates == true ? "Checking…" : "Check again")
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .disabled(coordinator.wrapped?.isCheckingForUpdates == true)
        }
    }

    // MARK: Translocated state

    @ViewBuilder
    private var translocatedBody: some View {
        Text("Move Clawdmeter to Applications")
            .font(.system(size: 15, weight: .semibold))

        Text("Continuum is running from a temporary location and can't be updated in place. Drag it to your Applications folder, then reopen.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
            Button(action: showInFinder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                    Text("Show in Finder")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Theme.statusWarning)
        }
    }

    // MARK: Up-to-date fallback (rare — chip is hidden in this state)

    @ViewBuilder
    private var upToDateBody: some View {
        Text("Clawdmeter is up to date")
            .font(.system(size: 14, weight: .semibold))

        if let last = coordinator.wrapped?.lastCheckedAt {
            Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        HStack {
            Spacer()
            Button("Check now", action: checkAgain)
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
    }

    // MARK: - Actions

    private func openInBrowser() {
        coordinator.wrapped?.openReleasePageFallback()
    }

    private func dismiss() {
        coordinator.wrapped?.dismissUpdate()
    }

    private func checkAgain() {
        coordinator.wrapped?.checkForUpdates()
    }

    private func showInFinder() {
        coordinator.wrapped?.showCurrentBundleInFinder()
    }

    private func renderMarkdown(_ source: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(source)
    }
}

// MARK: - Theme tokens (terra-cotta accent + status warning)
//
// We do NOT pull in TahoeSyncChip directly because it's hardcoded to
// `t.accent` and our translocation state needs a different tint.
// Inline the two color tokens here using the same hex values from
// `ClawdmeterShared.Theme/Theme.swift` so the chip visually matches
// the rest of the app's accent palette.

private enum Theme {
    static let accent = SessionsV2Theme.accent
    static let statusWarning = ClawdmeterTheme.Colors.statusWarning
}

// MARK: - Optional-coordinator wrapper for SwiftUI

/// `@ObservedObject` can't bind to an optional ObservableObject, so we
/// wrap the optional in a non-optional ObservableObject and forward
/// the wrapped value's publisher. When `wrapped` is nil (Preview path),
/// nothing publishes and the view stays in its initial state.
@MainActor
final class UpdateCoordinatorObservable: ObservableObject {
    let wrapped: UpdateCoordinator?
    private var cancellable: AnyCancellable?

    init(wrapped: UpdateCoordinator?) {
        self.wrapped = wrapped
        if let wrapped {
            cancellable = wrapped.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
}
