import Combine
import Foundation
import WhisperKit

@MainActor
public final class STTModelDownloadManager: ObservableObject {
    public enum DownloadState: Equatable, Sendable {
        case idle
        case downloading(modelID: String, progress: Double)
        case cancelled(modelID: String)
        case failed(modelID: String, message: String)
    }

    @Published public private(set) var downloadState: DownloadState = .idle
    @Published public private(set) var installedModelIDs: Set<String> = []
    @Published public private(set) var resumableModelID: String?

    private let appSupportDirectory: URL
    private var activeDownloadModelID: String?
    private var downloadTask: Task<Void, Error>?

    public init(appSupportDirectory: URL) {
        self.appSupportDirectory = appSupportDirectory
        refreshInstalledModels()
    }

    public func isModelInstalled(_ modelID: String) -> Bool {
        installedModelIDs.contains(modelID)
    }

    public func canResumeDownload(for modelID: String) -> Bool {
        resumableModelID == modelID
            || {
                switch downloadState {
                case .cancelled(let id), .failed(let id, _):
                    return id == modelID && !isModelInstalled(modelID)
                default:
                    return false
                }
            }()
    }

    public func refreshInstalledModels() {
        installedModelIDs = Set(
            STTModelCatalog.models
                .map(\.id)
                .filter { modelID in
                    STTModelCatalog.isModelInstalled(
                        at: STTModelCatalog.modelDirectory(
                            appSupportDirectory: appSupportDirectory,
                            modelID: modelID
                        )
                    )
                }
        )
    }

    public func download(modelID: String) async throws {
        guard downloadTask == nil else {
            throw STTModelDownloadError.downloadInProgress
        }

        let task = Task<Void, Error> { @MainActor in
            try await self.performDownload(modelID: modelID)
        }
        downloadTask = task
        defer { downloadTask = nil }

        do {
            try await task.value
        } catch is CancellationError {
            throw STTModelDownloadError.cancelled
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
    }

    public func delete(modelID: String) throws {
        let directory = STTModelCatalog.modelDirectory(
            appSupportDirectory: appSupportDirectory,
            modelID: modelID
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
        refreshInstalledModels()
        if resumableModelID == modelID {
            resumableModelID = nil
        }
        switch downloadState {
        case .failed(let failedID, _), .cancelled(let failedID):
            if failedID == modelID {
                downloadState = .idle
            }
        default:
            break
        }
    }

    public func clearFailure() {
        switch downloadState {
        case .failed:
            downloadState = .idle
        default:
            break
        }
    }

    public var installedModelsApproximateByteCount: Int64 {
        installedModelIDs
            .compactMap { STTModelCatalog.model(forID: $0)?.approximateBytes }
            .reduce(0, +)
    }

    private func performDownload(modelID: String) async throws {
        guard let descriptor = STTModelCatalog.model(forID: modelID) else {
            throw STTModelDownloadError.unknownModel(modelID)
        }

        let destination = STTModelCatalog.modelDirectory(
            appSupportDirectory: appSupportDirectory,
            modelID: modelID
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        activeDownloadModelID = modelID
        resumableModelID = nil
        downloadState = .downloading(modelID: modelID, progress: 0)

        defer { activeDownloadModelID = nil }

        do {
            try Task.checkCancellation()
            let downloadedDirectory = try await WhisperKit.download(
                variant: descriptor.whisperModelName,
                downloadBase: destination,
                progressCallback: { [weak self] progress in
                    Task { @MainActor in
                        guard self?.activeDownloadModelID == modelID else { return }
                        self?.downloadState = .downloading(
                            modelID: modelID,
                            progress: progress.fractionCompleted
                        )
                    }
                }
            )
            try Task.checkCancellation()
            guard STTModelCatalog.resolvedModelDirectory(in: downloadedDirectory) != nil
                || STTModelCatalog.resolvedModelDirectory(in: destination) != nil else {
                throw STTModelDownloadError.installationIncomplete(modelID)
            }
            refreshInstalledModels()
            downloadState = .idle
            resumableModelID = nil
        } catch is CancellationError {
            markDownloadInterrupted(modelID: modelID)
            throw CancellationError()
        } catch {
            markDownloadFailed(modelID: modelID, message: error.localizedDescription)
            throw error
        }
    }

    private func markDownloadInterrupted(modelID: String) {
        if isModelInstalledOnDisk(modelID) {
            refreshInstalledModels()
            downloadState = .idle
            resumableModelID = nil
        } else {
            resumableModelID = modelID
            downloadState = .cancelled(modelID: modelID)
        }
    }

    private func markDownloadFailed(modelID: String, message: String) {
        if !isModelInstalledOnDisk(modelID) {
            resumableModelID = modelID
        }
        downloadState = .failed(modelID: modelID, message: message)
    }

    private func isModelInstalledOnDisk(_ modelID: String) -> Bool {
        STTModelCatalog.isModelInstalled(
            at: STTModelCatalog.modelDirectory(
                appSupportDirectory: appSupportDirectory,
                modelID: modelID
            )
        )
    }
}

public enum STTModelDownloadError: LocalizedError {
    case downloadInProgress
    case unknownModel(String)
    case cancelled
    case installationIncomplete(String)

    public var errorDescription: String? {
        switch self {
        case .downloadInProgress:
            return "A model download is already in progress."
        case .unknownModel(let modelID):
            return "Unknown Whisper model \"\(modelID)\"."
        case .cancelled:
            return "Model download cancelled."
        case .installationIncomplete(let modelID):
            return "Whisper model \"\(modelID)\" downloaded but required model files were not found."
        }
    }
}
