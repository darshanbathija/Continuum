import Foundation

public struct STTModelDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let whisperModelName: String
    public let sizeLabel: String
    public let approximateBytes: Int64

    public init(
        id: String,
        displayName: String,
        whisperModelName: String,
        sizeLabel: String,
        approximateBytes: Int64
    ) {
        self.id = id
        self.displayName = displayName
        self.whisperModelName = whisperModelName
        self.sizeLabel = sizeLabel
        self.approximateBytes = approximateBytes
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
        STTModelDescriptor(
            id: "tiny",
            displayName: "Tiny",
            whisperModelName: "tiny",
            sizeLabel: "~39 MB",
            approximateBytes: 39_000_000
        ),
        STTModelDescriptor(
            id: "base",
            displayName: "Base",
            whisperModelName: "base",
            sizeLabel: "~74 MB",
            approximateBytes: 74_000_000
        ),
        STTModelDescriptor(
            id: "small",
            displayName: "Small",
            whisperModelName: "small",
            sizeLabel: "~244 MB",
            approximateBytes: 244_000_000
        ),
        STTModelDescriptor(
            id: "medium",
            displayName: "Medium",
            whisperModelName: "medium",
            sizeLabel: "~769 MB",
            approximateBytes: 769_000_000
        ),
    ]

    public static func model(forID id: String) -> STTModelDescriptor? {
        models.first { $0.id == id }
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
