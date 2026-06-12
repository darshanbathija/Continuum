import Foundation

/// Which Continuum composer should receive a dictation toggle.
public enum DictationComposerTarget: String, Codable, CaseIterable, Hashable, Sendable {
    case code
    case chat
}

public enum DictationRouteResolution: Equatable, Sendable {
    case route(DictationComposerTarget)
    case unavailableReadOnlyChat
}

public enum DictationRouteResolver {
    public struct Input: Equatable, Sendable {
        public var currentTab: String
        public var activeRecordingTarget: DictationComposerTarget?
        public var chatComposerIsReadOnly: Bool
        public var lastDictationTab: DictationComposerTarget?

        public init(
            currentTab: String,
            activeRecordingTarget: DictationComposerTarget? = nil,
            chatComposerIsReadOnly: Bool = false,
            lastDictationTab: DictationComposerTarget? = nil
        ) {
            self.currentTab = currentTab
            self.activeRecordingTarget = activeRecordingTarget
            self.chatComposerIsReadOnly = chatComposerIsReadOnly
            self.lastDictationTab = lastDictationTab
        }
    }

    /// Chooses the composer for the next dictation toggle.
    public static func resolve(_ input: Input) -> DictationRouteResolution {
        if let active = input.activeRecordingTarget {
            return .route(active)
        }
        switch input.currentTab {
        case DictationComposerTarget.chat.rawValue:
            return input.chatComposerIsReadOnly ? .unavailableReadOnlyChat : .route(.chat)
        case DictationComposerTarget.code.rawValue:
            return .route(.code)
        default:
            return .route(input.lastDictationTab ?? .code)
        }
    }
}

public enum DictationTextMerge {
    /// Merges a monotonic session partial from `SFSpeechRecognizer` onto the
    /// composer text that existed before dictation started.
    public static func mergedText(baseBeforeSession: String, sessionPartial: String) -> String {
        let partial = sessionPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty else { return baseBeforeSession }
        let base = baseBeforeSession.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return partial }
        return base + " " + partial
    }
}

public enum DictationToggleNotification {
    public static let targetUserInfoKey = "dictationTarget"

    public static func userInfo(for target: DictationComposerTarget) -> [AnyHashable: Any] {
        [targetUserInfoKey: target.rawValue]
    }

    public static func target(from notification: Notification) -> DictationComposerTarget? {
        guard let raw = notification.userInfo?[targetUserInfoKey] as? String else { return nil }
        return DictationComposerTarget(rawValue: raw)
    }

    /// Returns true when the notification is addressed to `expected`, or when
    /// the payload omits a target (legacy Code-only posters).
    public static func shouldHandle(_ notification: Notification, as expected: DictationComposerTarget) -> Bool {
        guard let target = target(from: notification) else {
            return expected == .code
        }
        return target == expected
    }
}
