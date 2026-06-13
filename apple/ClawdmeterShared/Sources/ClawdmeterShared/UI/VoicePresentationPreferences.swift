import Foundation

public enum STTEngine: String, Codable, Hashable, Sendable, CaseIterable {
    case appleSpeech
    case whisperKit
    /// NVIDIA Parakeet TDT via FluidAudio CoreML (Apple Neural Engine). Local,
    /// multilingual / English-only depending on the chosen model.
    case parakeet
}

public enum FnGestureMode: String, Codable, Hashable, Sendable, CaseIterable {
    case doubleTapOnly
    case doubleTapAndHold
    case holdOnly

    public var displayName: String {
        switch self {
        case .doubleTapOnly: return "Double-tap Fn"
        case .doubleTapAndHold: return "Double-tap or hold Fn"
        case .holdOnly: return "Hold Fn"
        }
    }
}

public struct VoicePresentationPreferences: Codable, Hashable, Sendable {
    public var systemWideDictationEnabled: Bool
    public var allowControlMShortcut: Bool
    public var sttEngine: STTEngine
    public var whisperModelID: String
    public var fnGestureMode: FnGestureMode
    public var recognitionLocaleIdentifier: String?

    public init(
        systemWideDictationEnabled: Bool = false,
        allowControlMShortcut: Bool = true,
        sttEngine: STTEngine = .appleSpeech,
        whisperModelID: String = "base",
        fnGestureMode: FnGestureMode = .doubleTapOnly,
        recognitionLocaleIdentifier: String? = nil
    ) {
        self.systemWideDictationEnabled = systemWideDictationEnabled
        self.allowControlMShortcut = allowControlMShortcut
        self.sttEngine = sttEngine
        self.whisperModelID = whisperModelID
        self.fnGestureMode = fnGestureMode
        self.recognitionLocaleIdentifier = recognitionLocaleIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemWideDictationEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemWideDictationEnabled) ?? false
        allowControlMShortcut = try container.decodeIfPresent(Bool.self, forKey: .allowControlMShortcut) ?? true
        sttEngine = try container.decodeIfPresent(STTEngine.self, forKey: .sttEngine) ?? .appleSpeech
        whisperModelID = try container.decodeIfPresent(String.self, forKey: .whisperModelID) ?? "base"
        fnGestureMode = try container.decodeIfPresent(FnGestureMode.self, forKey: .fnGestureMode) ?? .doubleTapOnly
        recognitionLocaleIdentifier = try container.decodeIfPresent(String.self, forKey: .recognitionLocaleIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case systemWideDictationEnabled
        case allowControlMShortcut
        case sttEngine
        case whisperModelID
        case fnGestureMode
        case recognitionLocaleIdentifier
    }
}

public enum GlobalDictationDelivery: Equatable, Sendable {
    case composer
    case externalPaste
    case systemWideDisabled
}

public enum GlobalDictationDeliveryResolver {
    public static func resolve(
        continuumBundleID: String,
        frontmostBundleID: String?,
        systemWideEnabled: Bool
    ) -> GlobalDictationDelivery {
        if frontmostBundleID == continuumBundleID {
            return .composer
        }
        return systemWideEnabled ? .externalPaste : .systemWideDisabled
    }
}

public enum GlobalDictationNotification {
    public static let targetUserInfoKey = "dictationTarget"
    public static let textUserInfoKey = "text"
    public static let phaseUserInfoKey = "phase"

    public enum Phase: String, Sendable {
        case partial
        case final
    }

    public static func applyTextUserInfo(
        target: DictationComposerTarget,
        text: String,
        phase: Phase
    ) -> [AnyHashable: Any] {
        [
            targetUserInfoKey: target.rawValue,
            textUserInfoKey: text,
            phaseUserInfoKey: phase.rawValue,
        ]
    }

    public static func parseApplyText(_ notification: Notification) -> (target: DictationComposerTarget, text: String, phase: Phase)? {
        guard let rawTarget = notification.userInfo?[targetUserInfoKey] as? String,
              let target = DictationComposerTarget(rawValue: rawTarget),
              let text = notification.userInfo?[textUserInfoKey] as? String
        else { return nil }
        let phaseRaw = notification.userInfo?[phaseUserInfoKey] as? String
        let phase = Phase(rawValue: phaseRaw ?? "") ?? .final
        return (target, text, phase)
    }
}
