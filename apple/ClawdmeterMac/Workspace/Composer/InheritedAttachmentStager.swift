import Foundation
import ClawdmeterShared

enum InheritedAttachmentStager {
    static let manifestFilename = "inherited-attachments-manifest.json"

    struct Manifest: Codable, Equatable {
        let entries: [Entry]
    }

    struct Entry: Codable, Equatable {
        let sourceSessionId: UUID
        let originalName: String
        let stagedPath: String?
        let byteSize: Int
        let error: String?
    }

    static func stage(sourceSessions: [AgentSession], into dir: URL) throws -> [URL] {
        guard !sourceSessions.isEmpty else { return [] }
        let fileManager = FileManager.default
        let inheritedRoot = dir.appendingPathComponent("inherited-attachments", isDirectory: true)
        try fileManager.createDirectory(at: inheritedRoot, withIntermediateDirectories: true)

        var stagedURLs: [URL] = []
        var manifestEntries: [Entry] = []
        for source in sourceSessions {
            guard let sourceDir = AttachmentStaging.existingStagingDir(for: source) else { continue }
            let destDir = inheritedRoot.appendingPathComponent(source.id.uuidString, isDirectory: true)
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            let files = (try? fileManager.contentsOfDirectory(
                at: sourceDir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where shouldCopy(file) {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                do {
                    let copied = try AttachmentStaging.stage(source: file, into: destDir, attachmentId: UUID())
                    stagedURLs.append(copied)
                    manifestEntries.append(Entry(
                        sourceSessionId: source.id,
                        originalName: file.lastPathComponent,
                        stagedPath: copied.path,
                        byteSize: values?.fileSize ?? 0,
                        error: nil
                    ))
                } catch {
                    manifestEntries.append(Entry(
                        sourceSessionId: source.id,
                        originalName: file.lastPathComponent,
                        stagedPath: nil,
                        byteSize: values?.fileSize ?? 0,
                        error: error.localizedDescription
                    ))
                }
            }
        }
        if !manifestEntries.isEmpty {
            let manifestURL = dir.appendingPathComponent(manifestFilename)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Manifest(entries: manifestEntries))
            try data.write(to: manifestURL, options: [.atomic])
            stagedURLs.append(manifestURL)
        }
        return stagedURLs
    }

    private static func shouldCopy(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == manifestFilename { return false }
        if name.hasPrefix("inherited-") && name.hasSuffix(".md") { return false }
        return true
    }
}
