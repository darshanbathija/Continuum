import AppKit
import ClawdmeterShared
import Foundation

/// App-scoped dictation context — always bound from `AppRuntime` so Fn works
/// even when the dashboard window is closed. `MacRootView` updates the live
/// tab + presentation store providers when visible.
@MainActor
final class AppDictationContext: GlobalDictationContextProviding {
    let continuumBundleID: String
    let appSupportDirectory: URL
    private let preferencesStoreURL: URL

    var currentTabProvider: () -> String = { "code" }
    var presentationStoreProvider: (() -> SessionPresentationStore?)?
    var onPrepareComposerRoute: ((DictationComposerTarget) -> Void)?
    var onApplyComposerText: ((String, DictationComposerTarget, GlobalDictationNotification.Phase) -> Void)?

    init(
        appSupportDirectory: URL,
        continuumBundleID: String = Bundle.main.bundleIdentifier ?? "ai.continuum.mac"
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.continuumBundleID = continuumBundleID
        self.preferencesStoreURL = SessionPresentationStore.defaultStoreURL(
            appSupportDirectory: appSupportDirectory
        )
    }

    func voicePreferences() -> VoicePresentationPreferences {
        if let store = presentationStoreProvider?() {
            return store.snapshot.voicePresentationPreferences
        }
        return (try? SessionPresentationStore(storeURL: preferencesStoreURL).snapshot.voicePresentationPreferences)
            ?? VoicePresentationPreferences()
    }

    func resolveComposerTarget() -> DictationRouteResolution {
        DictationRouting.shared.resolve(
            currentTab: currentTabProvider(),
            lastDictationTab: presentationStoreProvider?()?.snapshot.lastDictationTab
                ?? loadLastDictationTabFromDisk()
        )
    }

    func resolveComposerTargetForStopDelivery() -> DictationRouteResolution {
        DictationRouting.shared.resolve(
            currentTab: currentTabProvider(),
            lastDictationTab: presentationStoreProvider?()?.snapshot.lastDictationTab
                ?? loadLastDictationTabFromDisk(),
            includeActiveRecording: false
        )
    }

    func prepareComposerRoute(for target: DictationComposerTarget) {
        onPrepareComposerRoute?(target)
    }

    func applyComposerText(_ text: String, target: DictationComposerTarget, phase: GlobalDictationNotification.Phase) {
        onApplyComposerText?(text, target, phase)
    }

    func showInfoToast(title: String, detail: String?) {
        WorkspaceFeedback.info(title, detail: detail)
    }

    func showFailureToast(title: String, detail: String?) {
        WorkspaceFeedback.failure(title, detail: detail)
    }

    private func loadLastDictationTabFromDisk() -> DictationComposerTarget? {
        try? SessionPresentationStore(storeURL: preferencesStoreURL).snapshot.lastDictationTab
    }
}
