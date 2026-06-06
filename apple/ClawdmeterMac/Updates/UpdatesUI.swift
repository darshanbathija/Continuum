import SwiftUI
import Combine
import ClawdmeterShared

enum UpdateControlSnapshot: Equatable {
    case unavailable
    case idle
    case checking
    case upToDate
    case available(String)
    case installing
    case relaunchPending(String?)
    case cancelled(String?)
    case failed(String)
    case invalidAppcast(String)
    case corruptedDownload(String)
    case translocated
    case nonApplicationsInstall
    case setupBlocked(String)
    case automaticChecksDisabled
}

func updateControlShouldRender(_ snapshot: UpdateControlSnapshot, showsInactiveStates: Bool) -> Bool {
    if showsInactiveStates { return true }
    switch snapshot {
    case .available, .installing, .relaunchPending:
        return true
    default:
        return false
    }
}

@MainActor
func updateControlSnapshot(_ coordinator: UpdateCoordinator?) -> UpdateControlSnapshot {
    guard let coordinator else { return .unavailable }
    switch coordinator.state {
    case .idle:
        return .idle
    case .checking:
        return .checking
    case .upToDate:
        return .upToDate
    case .updateAvailable(let update):
        return .available(update.displayVersion)
    case .installing:
        return .installing
    case .installedRelaunchPending(let version):
        return .relaunchPending(version)
    case .userCancelled(let version):
        return .cancelled(version)
    case .failed(let reason, _):
        return .failed(reason)
    case .invalidAppcastSignature(let reason, _):
        return .invalidAppcast(reason)
    case .corruptedDownload(let reason, _):
        return .corruptedDownload(reason)
    case .translocated:
        return .translocated
    case .nonApplicationsInstall:
        return .nonApplicationsInstall
    case .setupBlocked(let reason, _):
        return .setupBlocked(reason)
    case .automaticChecksDisabled:
        return .automaticChecksDisabled
    }
}

struct UpdateAppControl: View {
    @ObservedObject private var coordinator: UpdateCoordinatorObservable
    private let compact: Bool
    private let showsInactiveStates: Bool
    @State private var popoverPresented = false

    init(coordinator: UpdateCoordinator?, compact: Bool = false, showsInactiveStates: Bool = false) {
        self.coordinator = UpdateCoordinatorObservable(wrapped: coordinator)
        self.compact = compact
        self.showsInactiveStates = showsInactiveStates
    }

    @ViewBuilder
    var body: some View {
        if updateControlShouldRender(snapshot, showsInactiveStates: showsInactiveStates) {
            Button(action: primaryAction) {
                HStack(spacing: compact ? 5 : 6) {
                    icon
                    if !compact || labelAlwaysVisible {
                        Text(label)
                            .font(ContinuumFont.body(compact ? 11 : 11.5, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(statusColor)
                .padding(.horizontal, compact ? 8 : 10)
                .padding(.vertical, 4)
                .frame(height: 24)
                .background {
                    RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                        .fill(chipFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                        .strokeBorder(chipStroke, lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.55 : 1)
            .help(helpText)
            .popover(isPresented: $popoverPresented, arrowEdge: .bottom) {
                UpdatePopoverContent(coordinator: coordinator.wrapped)
                    .frame(width: 400)
            }
        }
    }

    private var snapshot: UpdateControlSnapshot {
        updateControlSnapshot(coordinator.wrapped)
    }

    @ViewBuilder
    private var icon: some View {
        if case .checking = snapshot {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)
        } else if case .installing = snapshot {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
        }
    }

    private var labelAlwaysVisible: Bool {
        switch snapshot {
        case .available, .translocated, .nonApplicationsInstall, .setupBlocked, .invalidAppcast, .corruptedDownload, .failed:
            return true
        default:
            return !compact
        }
    }

    private var systemImage: String {
        switch snapshot {
        case .available:
            return "arrow.down.circle.fill"
        case .checking, .installing:
            return "arrow.triangle.2.circlepath"
        case .upToDate:
            return "checkmark.circle.fill"
        case .translocated, .nonApplicationsInstall, .setupBlocked, .failed, .invalidAppcast, .corruptedDownload:
            return "exclamationmark.triangle.fill"
        case .automaticChecksDisabled:
            return "arrow.down.circle"
        case .relaunchPending:
            return "power.circle.fill"
        default:
            return "arrow.down.circle"
        }
    }

    private var label: String {
        switch snapshot {
        case .available:
            return "Update"
        case .checking:
            return "Checking"
        case .installing:
            return "Installing"
        case .upToDate:
            return compact ? "Updated" : "Up to date"
        case .translocated:
            return "Move App"
        case .nonApplicationsInstall:
            return "Install App"
        case .setupBlocked:
            return "Update Setup"
        case .automaticChecksDisabled:
            return compact ? "Updates" : "Update App"
        case .relaunchPending:
            return "Relaunch"
        case .failed, .invalidAppcast, .corruptedDownload:
            return "Update Failed"
        default:
            return compact ? "Update" : "Update App"
        }
    }

    private var statusColor: Color {
        switch snapshot {
        case .available, .relaunchPending:
            return ContinuumTokens.fg
        case .upToDate:
            return ContinuumTokens.live
        case .failed, .invalidAppcast, .corruptedDownload:
            return ContinuumTokens.error
        case .translocated, .nonApplicationsInstall, .setupBlocked:
            return ContinuumTokens.warn
        default:
            return ContinuumTokens.fg2
        }
    }

    private var chipFill: Color {
        switch snapshot {
        case .available, .relaunchPending:
            return ContinuumTokens.surface3
        case .failed, .invalidAppcast, .corruptedDownload:
            return ContinuumTokens.error.opacity(0.10)
        case .translocated, .nonApplicationsInstall, .setupBlocked:
            return ContinuumTokens.warn.opacity(0.10)
        default:
            return ContinuumTokens.surface2
        }
    }

    private var chipStroke: Color {
        switch snapshot {
        case .available, .relaunchPending:
            return ContinuumTokens.focus
        case .failed, .invalidAppcast, .corruptedDownload, .translocated, .nonApplicationsInstall, .setupBlocked:
            return statusColor.opacity(0.35)
        default:
            return ContinuumTokens.hairline
        }
    }

    private var disabled: Bool {
        switch snapshot {
        case .checking, .installing, .unavailable:
            return true
        default:
            return false
        }
    }

    private var helpText: String {
        switch snapshot {
        case .available(let version):
            return "Install Continuum \(version) with Sparkle."
        case .translocated:
            return "Continuum is running from a temporary Gatekeeper location."
        case .nonApplicationsInstall:
            return "Move Continuum to /Applications before enabling in-app updates."
        case .setupBlocked:
            return "Sparkle setup is blocked. Open update details."
        case .automaticChecksDisabled:
            return "Automatic checks are off. Click to check manually."
        default:
            return "Check for Continuum updates."
        }
    }

    private func primaryAction() {
        switch snapshot {
        case .idle, .upToDate, .automaticChecksDisabled, .cancelled:
            coordinator.wrapped?.refreshUpdateStatus()
            popoverPresented = true
        default:
            popoverPresented = true
        }
    }
}

struct UpdatePopoverContent: View {
    @ObservedObject private var coordinator: UpdateCoordinatorObservable

    init(coordinator: UpdateCoordinator?) {
        self.coordinator = UpdateCoordinatorObservable(wrapped: coordinator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            detail
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ContinuumTokens.surface1)
        .onAppear { coordinator.wrapped?.refreshReleaseMetadata() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(headerTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(ContinuumFont.body(14, weight: .semibold))
                    .foregroundStyle(ContinuumTokens.fg)
                Text("Current \(coordinator.wrapped?.currentVersion ?? "unknown") (\(coordinator.wrapped?.currentBuild ?? "unknown"))")
                    .font(ContinuumFont.mono(11))
                    .foregroundStyle(ContinuumTokens.fg3)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch coordinator.wrapped?.state {
        case .updateAvailable(let update):
            VStack(alignment: .leading, spacing: 8) {
                if let title = update.title, !title.isEmpty {
                    Text(title)
                        .font(ContinuumFont.body(12, weight: .semibold))
                        .foregroundStyle(ContinuumTokens.fg)
                }
                releaseNotesView
            }
        case .failed(let reason, _), .setupBlocked(let reason, _),
             .invalidAppcastSignature(let reason, _), .corruptedDownload(let reason, _):
            Text(reason)
                .font(ContinuumFont.body(12))
                .foregroundStyle(ContinuumTokens.fg2)
                .fixedSize(horizontal: false, vertical: true)
        case .translocated(let url):
            Text("Continuum is running from a temporary Gatekeeper path. Reveal the app in Finder, move it to /Applications, then relaunch.")
                .font(ContinuumFont.body(12))
                .foregroundStyle(ContinuumTokens.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Text(url.path)
                .font(ContinuumFont.mono(10))
                .foregroundStyle(ContinuumTokens.fg3)
                .lineLimit(2)
                .truncationMode(.middle)
        case .nonApplicationsInstall(let url):
            Text("Sparkle can only replace installed apps reliably from /Applications. Move Continuum there before using in-app updates.")
                .font(ContinuumFont.body(12))
                .foregroundStyle(ContinuumTokens.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Text(url.path)
                .font(ContinuumFont.mono(10))
                .foregroundStyle(ContinuumTokens.fg3)
                .lineLimit(2)
                .truncationMode(.middle)
        default:
            releaseNotesView
        }
    }

    @ViewBuilder
    private var releaseNotesView: some View {
        if coordinator.wrapped?.isLoadingReleaseMetadata == true {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading release notes")
                    .font(ContinuumFont.body(12))
                    .foregroundStyle(ContinuumTokens.fg2)
            }
        } else if let notes = coordinator.wrapped?.releaseNotes, !notes.isEmpty {
            ScrollView {
                Text(renderMarkdown(notes))
                    .font(ContinuumFont.body(12))
                    .foregroundStyle(ContinuumTokens.fg2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxHeight: 240)
            .background(ContinuumTokens.surface2, in: RoundedRectangle(cornerRadius: ContinuumTokens.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ContinuumTokens.Radius.card, style: .continuous)
                    .strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5)
            }
        } else if let error = coordinator.wrapped?.releaseMetadataError {
            Text("Release notes unavailable: \(error)")
                .font(ContinuumFont.body(12))
                .foregroundStyle(ContinuumTokens.fg2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Release notes will appear here after the appcast is available.")
                .font(ContinuumFont.body(12))
                .foregroundStyle(ContinuumTokens.fg2)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            TahoeAccentButton(size: .m, disabled: primaryActionDisabled, action: primaryAction) {
                Text(primaryActionTitle)
            }

            TahoeGhostButton(size: .m, action: secondaryAction) {
                Text(secondaryActionTitle)
            }
        }
    }

    private var headerTitle: String {
        switch coordinator.wrapped?.state {
        case .updateAvailable(let update):
            return "Continuum \(update.displayVersion) is available"
        case .checking:
            return "Checking for updates"
        case .upToDate:
            return "Continuum is up to date"
        case .installing:
            return "Installing update"
        case .installedRelaunchPending(let version):
            return "Relaunch to finish \(version ?? "the update")"
        case .automaticChecksDisabled:
            return "Automatic updates are off"
        case .translocated:
            return "Move Continuum to Applications"
        case .nonApplicationsInstall:
            return "Install Continuum in Applications"
        case .setupBlocked:
            return "Update setup is blocked"
        case .invalidAppcastSignature:
            return "Appcast signature failed"
        case .corruptedDownload:
            return "Downloaded update is corrupted"
        case .failed:
            return "Update failed"
        default:
            return "Continuum updates"
        }
    }

    private var headerIcon: String {
        switch updateControlSnapshot(coordinator.wrapped) {
        case .available:
            return "arrow.down.circle.fill"
        case .upToDate:
            return "checkmark.circle.fill"
        case .checking, .installing:
            return "arrow.triangle.2.circlepath"
        case .relaunchPending:
            return "power.circle.fill"
        case .translocated, .nonApplicationsInstall, .setupBlocked, .failed, .invalidAppcast, .corruptedDownload:
            return "exclamationmark.triangle.fill"
        default:
            return "arrow.down.circle"
        }
    }

    private var headerTint: Color {
        switch updateControlSnapshot(coordinator.wrapped) {
        case .available, .relaunchPending:
            return ContinuumTokens.fg
        case .upToDate:
            return ContinuumTokens.live
        case .failed, .invalidAppcast, .corruptedDownload:
            return ContinuumTokens.error
        case .translocated, .nonApplicationsInstall, .setupBlocked:
            return ContinuumTokens.warn
        default:
            return ContinuumTokens.fg2
        }
    }

    private var primaryActionTitle: String {
        switch coordinator.wrapped?.state {
        case .updateAvailable:
            return "Update"
        case .translocated, .nonApplicationsInstall:
            return "Show in Finder"
        case .failed, .setupBlocked, .invalidAppcastSignature, .corruptedDownload:
            return "Open Fallback"
        case .checking, .installing:
            return "Working"
        default:
            return "Check Now"
        }
    }

    private var secondaryActionTitle: String {
        switch coordinator.wrapped?.state {
        case .updateAvailable:
            return "Later"
        default:
            return "Release Notes"
        }
    }

    private var primaryActionDisabled: Bool {
        switch coordinator.wrapped?.state {
        case .checking, .installing:
            return true
        default:
            return false
        }
    }

    private func primaryAction() {
        switch coordinator.wrapped?.state {
        case .updateAvailable:
            coordinator.wrapped?.checkForUpdates()
        case .translocated, .nonApplicationsInstall:
            coordinator.wrapped?.showCurrentBundleInFinder()
        case .failed, .setupBlocked, .invalidAppcastSignature, .corruptedDownload:
            coordinator.wrapped?.openReleasePageFallback()
        default:
            coordinator.wrapped?.refreshUpdateStatus()
        }
    }

    private func secondaryAction() {
        switch coordinator.wrapped?.state {
        case .updateAvailable:
            coordinator.wrapped?.dismissUpdate()
        default:
            coordinator.wrapped?.openReleaseNotes()
        }
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

struct UpdateSettingsPanel: View {
    @ObservedObject private var coordinator: UpdateCoordinatorObservable

    init(coordinator: UpdateCoordinator?) {
        self.coordinator = UpdateCoordinatorObservable(wrapped: coordinator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UpdateSettingsRow(label: "Installed version", hint: "Bundle version used by Sparkle and appcast matching.") {
                Text("\(coordinator.wrapped?.currentVersion ?? "unknown") (\(coordinator.wrapped?.currentBuild ?? "unknown"))")
                    .font(ContinuumFont.mono(11, weight: .medium))
                    .foregroundStyle(ContinuumTokens.fg2)
            }

            UpdateSettingsRow(label: "Last checked", hint: "Updated by Sparkle, not by a GitHub API poll.") {
                Text(lastCheckedText)
                    .font(ContinuumFont.body(12))
                    .foregroundStyle(ContinuumTokens.fg2)
            }

            UpdateSettingsRow(label: "Check automatically", hint: "Sparkle schedules future appcast checks.") {
                TahoeToggleView(on: automaticChecksBinding)
            }

            UpdateSettingsRow(label: "Download automatically", hint: "Sparkle can prepare updates in the background.") {
                TahoeToggleView(on: automaticDownloadsBinding)
            }

            HStack(spacing: 8) {
                UpdateAppControl(coordinator: coordinator.wrapped, showsInactiveStates: true)
                TahoeGhostButton(size: .s, action: { coordinator.wrapped?.openAppcast() }) {
                    Text("Open Appcast")
                }
                TahoeGhostButton(size: .s, action: { coordinator.wrapped?.openReleasePageFallback() }) {
                    Text("Fallback")
                }
            }

            releaseHistory
        }
        .onAppear { coordinator.wrapped?.refreshReleaseMetadata() }
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { coordinator.wrapped?.automaticChecksEnabled ?? false },
            set: { coordinator.wrapped?.setAutomaticChecksEnabled($0) }
        )
    }

    private var automaticDownloadsBinding: Binding<Bool> {
        Binding(
            get: { coordinator.wrapped?.automaticDownloadsEnabled ?? false },
            set: { coordinator.wrapped?.setAutomaticDownloadsEnabled($0) }
        )
    }

    private var lastCheckedText: String {
        guard let last = coordinator.wrapped?.lastCheckedAt else { return "Never" }
        return last.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var releaseHistory: some View {
        if let history = coordinator.wrapped?.releaseHistory, !history.isEmpty {
            TahoeHair().padding(.vertical, 4)
            Text("Release history")
                .font(ContinuumFont.etched(10.5))
                .tracking(0.6)
                .foregroundStyle(ContinuumTokens.fg3)
            ForEach(history.prefix(6)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.version) \(entry.title)")
                        .font(ContinuumFont.body(12, weight: .semibold))
                        .foregroundStyle(ContinuumTokens.fg)
                    if let publishedAt = entry.publishedAt {
                        Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(ContinuumFont.body(11))
                            .foregroundStyle(ContinuumTokens.fg3)
                    }
                }
            }
        }
    }
}

private struct UpdateSettingsRow<Control: View>: View {
    var label: String
    var hint: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(ContinuumFont.body(14, weight: .semibold))
                    .foregroundStyle(ContinuumTokens.fg)
                if let hint {
                    Text(hint)
                        .font(ContinuumFont.body(12))
                        .foregroundStyle(ContinuumTokens.fg3)
                        .frame(maxWidth: 460, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

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
