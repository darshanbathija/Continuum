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
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        return containsWhisperKitArtifacts(in: directory)
    }

    private static func containsWhisperKitArtifacts(in directory: URL) -> Bool {
        let requiredNames = [
            "AudioEncoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
            "TextDecoder.mlmodelc",
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var found = Set<String>()
        for case let fileURL as URL in enumerator {
            found.insert(fileURL.lastPathComponent)
            if requiredNames.allSatisfy({ found.contains($0) }) {
                return true
            }
        }
        return false
    }
}
