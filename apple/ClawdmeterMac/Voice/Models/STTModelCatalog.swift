import ClawdmeterShared
import Foundation

/// Language reach of a local STT model — drives the "Multi-language /
/// English only / …" tag shown on each model card.
public enum STTLanguageCoverage: Hashable, Sendable {
    case multilingual          // broad, auto-detect
    case europeanMultilingual  // Parakeet v3 / Canary-class: ~25 European langs
    case englishOnly

    public var tagLabel: String {
        switch self {
        case .multilingual: return "Multi-language"
        case .europeanMultilingual: return "25 European languages"
        case .englishOnly: return "English only"
        }
    }
}

/// One downloadable local speech-to-text model. Carries both the runtime
/// wiring (`engine` + the engine-specific download key) and the
/// speed/quality/language tradeoff metadata the Voice settings cards render.
///
/// `quality` and `speed` are coarse 1–5 ratings (relative to the other local
/// models on this list, not absolute WER/RTFx numbers) — they exist to drive
/// the comparison rail-meters, mirroring Handy / macParakeet's model pickers.
public struct STTModelDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let engine: STTEngine
    public let displayName: String
    /// WhisperKit download variant (Whisper models) — empty for Parakeet.
    public let whisperModelName: String
    /// FluidAudio model version key ("v3" / "v2") — nil for Whisper models.
    public let parakeetVersionKey: String?
    public let sizeLabel: String
    public let approximateBytes: Int64
    public let tagline: String
    public let quality: Int
    public let speed: Int
    public let languageCoverage: STTLanguageCoverage
    public let supportsTranslation: Bool
    public let requiresAppleSilicon: Bool
    public let recommended: Bool

    public init(
        id: String,
        engine: STTEngine,
        displayName: String,
        whisperModelName: String = "",
        parakeetVersionKey: String? = nil,
        sizeLabel: String,
        approximateBytes: Int64,
        tagline: String,
        quality: Int,
        speed: Int,
        languageCoverage: STTLanguageCoverage,
        supportsTranslation: Bool = false,
        requiresAppleSilicon: Bool = false,
        recommended: Bool = false
    ) {
        self.id = id
        self.engine = engine
        self.displayName = displayName
        self.whisperModelName = whisperModelName
        self.parakeetVersionKey = parakeetVersionKey
        self.sizeLabel = sizeLabel
        self.approximateBytes = approximateBytes
        self.tagline = tagline
        self.quality = max(1, min(5, quality))
        self.speed = max(1, min(5, speed))
        self.languageCoverage = languageCoverage
        self.supportsTranslation = supportsTranslation
        self.requiresAppleSilicon = requiresAppleSilicon
        self.recommended = recommended
    }
}

public enum STTModelCatalog {
    public static let voiceModelsDirectoryName = "VoiceModels"
    public static let defaultModelID = "base"
    public static let largeDownloadWarningBytes: Int64 = 500_000_000
    private static let requiredModelNames = [
        "AudioEncoder",
        "MelSpectrogram",
        "TextDecoder",
    ]

    public static let models: [STTModelDescriptor] = [
        // ── WhisperKit (Whisper-family, multilingual) ──────────────────
        STTModelDescriptor(
            id: "tiny",
            engine: .whisperKit,
            displayName: "Tiny",
            whisperModelName: "tiny",
            sizeLabel: "~39 MB",
            approximateBytes: 39_000_000,
            tagline: "Fastest Whisper. Roughest accuracy — quick notes.",
            quality: 1,
            speed: 5,
            languageCoverage: .multilingual
        ),
        STTModelDescriptor(
            id: "base",
            engine: .whisperKit,
            displayName: "Base",
            whisperModelName: "base",
            sizeLabel: "~74 MB",
            approximateBytes: 74_000_000,
            tagline: "Small and quick. A balanced everyday default.",
            quality: 2,
            speed: 4,
            languageCoverage: .multilingual
        ),
        STTModelDescriptor(
            id: "small",
            engine: .whisperKit,
            displayName: "Small",
            whisperModelName: "small",
            sizeLabel: "~244 MB",
            approximateBytes: 244_000_000,
            tagline: "More accurate Whisper at a moderate size.",
            quality: 3,
            speed: 3,
            languageCoverage: .multilingual
        ),
        STTModelDescriptor(
            id: "medium",
            engine: .whisperKit,
            displayName: "Medium",
            whisperModelName: "medium",
            sizeLabel: "~769 MB",
            approximateBytes: 769_000_000,
            tagline: "High Whisper accuracy. Heavier and slower.",
            quality: 4,
            speed: 2,
            languageCoverage: .multilingual
        ),
        STTModelDescriptor(
            id: "distil-large-v3",
            engine: .whisperKit,
            displayName: "Distil Large v3",
            whisperModelName: "distil-large-v3_turbo_600MB",
            sizeLabel: "~600 MB",
            approximateBytes: 600_000_000,
            tagline: "Distilled large-v3. Near-large accuracy, much faster.",
            quality: 4,
            speed: 4,
            languageCoverage: .englishOnly
        ),
        STTModelDescriptor(
            id: "large-v3-turbo",
            engine: .whisperKit,
            displayName: "Large v3 Turbo",
            whisperModelName: "large-v3_turbo_954MB",
            sizeLabel: "~954 MB",
            approximateBytes: 954_000_000,
            tagline: "Best Whisper accuracy at usable speed. Multilingual.",
            quality: 5,
            speed: 3,
            languageCoverage: .multilingual,
            recommended: true
        ),
        STTModelDescriptor(
            id: "large-v3",
            engine: .whisperKit,
            displayName: "Large v3",
            whisperModelName: "large-v3_947MB",
            sizeLabel: "~947 MB",
            approximateBytes: 947_000_000,
            tagline: "Maximum Whisper accuracy. Slowest of the set.",
            quality: 5,
            speed: 2,
            languageCoverage: .multilingual
        ),
        // ── Parakeet TDT (FluidAudio CoreML, Apple Neural Engine) ──────
        STTModelDescriptor(
            id: "parakeet-v3",
            engine: .parakeet,
            displayName: "Parakeet V3",
            parakeetVersionKey: "v3",
            sizeLabel: "~478 MB",
            approximateBytes: 478_000_000,
            tagline: "Fastest local engine. Multilingual with auto-detect.",
            quality: 4,
            speed: 5,
            languageCoverage: .europeanMultilingual,
            requiresAppleSilicon: true,
            recommended: true
        ),
        STTModelDescriptor(
            id: "parakeet-v2",
            engine: .parakeet,
            displayName: "Parakeet V2",
            parakeetVersionKey: "v2",
            sizeLabel: "~473 MB",
            approximateBytes: 473_000_000,
            tagline: "English-only, highest recall. Extremely fast.",
            quality: 5,
            speed: 5,
            languageCoverage: .englishOnly,
            requiresAppleSilicon: true
        ),
    ]

    public static func model(forID id: String) -> STTModelDescriptor? {
        models.first { $0.id == id }
    }

    /// Models for a given engine, in catalog (display) order.
    public static func models(for engine: STTEngine) -> [STTModelDescriptor] {
        models.filter { $0.engine == engine }
    }

    /// Whether the host hardware can run a given model (Parakeet needs the ANE).
    public static func isSupportedOnThisDevice(_ model: STTModelDescriptor) -> Bool {
        guard model.requiresAppleSilicon else { return true }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static func voiceModelsRoot(appSupportDirectory: URL) -> URL {
        appSupportDirectory
            .appendingPathComponent(voiceModelsDirectoryName, isDirectory: true)
    }

    public static func modelDirectory(appSupportDirectory: URL, modelID: String) -> URL {
        voiceModelsRoot(appSupportDirectory: appSupportDirectory)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    public static func isModelInstalled(at directory: URL) -> Bool {
        resolvedModelDirectory(in: directory) != nil
    }

    public static func resolvedModelDirectory(appSupportDirectory: URL, modelID: String) -> URL? {
        resolvedModelDirectory(
            in: modelDirectory(
                appSupportDirectory: appSupportDirectory,
                modelID: modelID
            )
        )
    }

    public static func resolvedModelDirectory(in directory: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        if containsWhisperKitArtifacts(in: directory) {
            return directory
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            let candidate = candidateModelDirectory(for: fileURL)
            if let candidate, containsWhisperKitArtifacts(in: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func containsWhisperKitArtifacts(in directory: URL) -> Bool {
        requiredModelNames.allSatisfy { modelName in
            hasModelArtifact(named: modelName, in: directory)
        }
    }

    private static func hasModelArtifact(named modelName: String, in directory: URL) -> Bool {
        let compiledModel = directory.appendingPathComponent("\(modelName).mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: compiledModel.path) {
            return true
        }

        let packageModel = directory
            .appendingPathComponent("\(modelName).mlpackage", isDirectory: true)
            .appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        return FileManager.default.fileExists(atPath: packageModel.path)
    }

    private static func candidateModelDirectory(for fileURL: URL) -> URL? {
        if fileURL.pathExtension == "mlmodelc" {
            return fileURL.deletingLastPathComponent()
        }
        if fileURL.pathExtension == "mlpackage" {
            return fileURL.deletingLastPathComponent()
        }
        if fileURL.lastPathComponent == "model.mlmodel" {
            let packageURL = fileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if packageURL.pathExtension == "mlpackage" {
                return packageURL.deletingLastPathComponent()
            }
        }
        return nil
    }
}
