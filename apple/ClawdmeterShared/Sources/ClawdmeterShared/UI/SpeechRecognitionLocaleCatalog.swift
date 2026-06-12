import Foundation

public enum SpeechRecognitionLocaleCatalog {
    public struct Option: Identifiable, Hashable, Sendable {
        public var id: String { identifier ?? Self.systemDefaultToken }
        public let identifier: String?
        public let label: String

        public static let systemDefaultToken = "system-default"
    }

    public static func options(systemLocale: Locale = .current) -> [Option] {
        let systemLabel = systemLocale.localizedString(forIdentifier: systemLocale.identifier)
            ?? systemLocale.identifier
        return [
            Option(identifier: nil, label: "System default (\(systemLabel))"),
            Option(identifier: "en_US", label: "English (United States)"),
            Option(identifier: "en_GB", label: "English (United Kingdom)"),
            Option(identifier: "es_ES", label: "Spanish (Spain)"),
            Option(identifier: "fr_FR", label: "French (France)"),
            Option(identifier: "de_DE", label: "German (Germany)"),
            Option(identifier: "ja_JP", label: "Japanese (Japan)"),
            Option(identifier: "zh_CN", label: "Chinese (Simplified)"),
        ]
    }

    public static func label(for identifier: String?, systemLocale: Locale = .current) -> String {
        if let identifier,
           let match = options(systemLocale: systemLocale).first(where: { $0.identifier == identifier }) {
            return match.label
        }
        return options(systemLocale: systemLocale).first?.label ?? "System default"
    }
}

public enum GlobalDictationStopDelivery: Equatable, Sendable {
    case composer(DictationComposerTarget)
    case externalPaste
    case unavailable(String)
}

public enum GlobalDictationStopDeliveryResolver {
    /// Resolves where a finished dictation session should deliver text (finish-target model).
    public static func resolve(
        continuumBundleID: String,
        frontmostBundleID: String?,
        systemWideEnabled: Bool,
        composerResolution: DictationRouteResolution
    ) -> GlobalDictationStopDelivery {
        switch GlobalDictationDeliveryResolver.resolve(
            continuumBundleID: continuumBundleID,
            frontmostBundleID: frontmostBundleID,
            systemWideEnabled: systemWideEnabled
        ) {
        case .composer:
            switch composerResolution {
            case .unavailableReadOnlyChat:
                return .unavailable("Dictation unavailable for archived transcripts")
            case .route(let target):
                return .composer(target)
            }
        case .externalPaste:
            return .externalPaste
        case .systemWideDisabled:
            return .unavailable("Enable system-wide dictation in Voice settings")
        }
    }
}
