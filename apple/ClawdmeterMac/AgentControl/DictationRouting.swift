import Foundation
import Combine
import ClawdmeterShared

/// Tracks live dictation routing state for global ⌃M dispatch.
@MainActor
public final class DictationRouting: ObservableObject {
    public static let shared = DictationRouting()

    @Published public private(set) var activeRecordingTarget: DictationComposerTarget?
    @Published public private(set) var chatComposerIsReadOnly: Bool = false
    @Published public private(set) var globalSessionActive: Bool = false
    @Published public private(set) var globalSessionTarget: DictationComposerTarget?

    private init() {}

    public func setChatComposerReadOnly(_ readOnly: Bool) {
        chatComposerIsReadOnly = readOnly
    }

    public func setRecording(_ target: DictationComposerTarget, active: Bool) {
        if active {
            activeRecordingTarget = target
        } else if activeRecordingTarget == target {
            activeRecordingTarget = nil
        }
    }

    public func setGlobalSession(active: Bool, target: DictationComposerTarget? = nil) {
        globalSessionActive = active
        globalSessionTarget = active ? target : nil
        if active, let target {
            activeRecordingTarget = target
        } else if !active, let target, activeRecordingTarget == target {
            activeRecordingTarget = nil
        }
    }

    public func resolve(currentTab: String, lastDictationTab: DictationComposerTarget?) -> DictationRouteResolution {
        DictationRouteResolver.resolve(
            .init(
                currentTab: currentTab,
                activeRecordingTarget: activeRecordingTarget,
                chatComposerIsReadOnly: chatComposerIsReadOnly,
                lastDictationTab: lastDictationTab
            )
        )
    }
}
