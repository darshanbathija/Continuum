import Foundation
import AppKit
import ClawdmeterShared
import OSLog

private let stagingLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AttachmentStaging")

/// Copies dropped/pasted/imported files into a per-session staging directory.
/// The new composer prefixes the prompt with `@<absolute-path>` for each
/// staged file so Claude Code / Codex Read tools can open them.
///
/// Path selection (Codex P1 sandbox fix):
/// - Claude session (any mode) OR Codex `.local` mode →
///     `~/Library/Application Support/Clawdmeter/attachments/<sessionId>/<uuid>.<ext>`
/// - Codex + worktree mode →
///     `<worktreePath>/.clawdmeter-attachments/<sessionId>/<uuid>.<ext>`
///   so the file lives inside Codex's read-only/workspace-write sandbox root
///   without sharing staged attachments across sibling sessions.
///
/// We deliberately read bytes via `Data(contentsOf:)` and write to the
/// destination instead of `ditto`/`copyItem`, so symlinks get resolved at
/// read time and don't carry through to the staging dir (§3 inline rescue).
enum AttachmentStaging {

    static let workspaceWorktreeSubdir = ".clawdmeter-attachments"

    private static func codexWorktreeStagingDir(for session: AgentSession) -> URL? {
        guard session.agent == .codex, session.mode == .worktree else { return nil }
        let workspacePath = (session.worktreePath ?? session.runtimeCwd ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspacePath.isEmpty else { return nil }
        return URL(fileURLWithPath: workspacePath)
            .appendingPathComponent(workspaceWorktreeSubdir, isDirectory: true)
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
    }

    /// Resolve the staging directory for the given session. Creates the
    /// dir tree if needed. Returns nil if the path cannot be created.
    static func stagingDir(for session: AgentSession) -> URL? {
        let url: URL
        if let codexDir = codexWorktreeStagingDir(for: session) {
            url = codexDir
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
            url = appSupport
                .appendingPathComponent("Clawdmeter", isDirectory: true)
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(session.id.uuidString, isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            return url
        } catch {
            stagingLogger.error("createDirectory failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func existingStagingDir(for session: AgentSession) -> URL? {
        let url: URL
        if let codexDir = codexWorktreeStagingDir(for: session) {
            url = codexDir
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
            url = appSupport
                .appendingPathComponent("Clawdmeter", isDirectory: true)
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(session.id.uuidString, isDirectory: true)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue
        else { return nil }
        return url
    }

    /// Empty-state staging dir — not yet bound to a session id. Files written
    /// here are migrated into the spawned session's dir on first-send success.
    static let emptyStateStagingDir: URL? = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = appSupport
            .appendingPathComponent("Clawdmeter", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("_pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }()

    static func makePendingStagingDir() throws -> URL {
        guard let root = emptyStateStagingDir else {
            throw NSError(domain: "ClawdmeterStaging", code: 2, userInfo: [NSLocalizedDescriptionKey: "Attachment staging root unavailable"])
        }
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    static func cleanupPendingStagingDir(_ url: URL) {
        guard let root = emptyStateStagingDir?.standardizedFileURL else { return }
        let target = url.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(rootPath) else { return }
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// Copy one source URL into the destination dir, resolving symlinks at
    /// read-time. Returns the staged URL or throws.
    static func stage(source: URL, into destDir: URL, attachmentId: UUID) throws -> URL {
        let ext = source.pathExtension
        let filename = ext.isEmpty ? attachmentId.uuidString : "\(attachmentId.uuidString).\(ext)"
        let dest = destDir.appendingPathComponent(filename)
        let data = try Data(contentsOf: source, options: [.alwaysMapped])
        try data.write(to: dest, options: [.atomic])
        return dest
    }

    /// Write raw bytes (e.g. from an iOS HTTP upload) to the staging dir
    /// under `<uuid>.<ext>`. `ext` is sanitised — anything that isn't
    /// alphanumeric falls back to no extension so a bad client can't
    /// smuggle path traversal via `../foo`.
    static func stage(data: Data, ext: String, into destDir: URL, attachmentId: UUID) throws -> URL {
        let safeExt = ext.filter(\.isLetter).lowercased()
        let filename = safeExt.isEmpty
            ? attachmentId.uuidString
            : "\(attachmentId.uuidString).\(safeExt)"
        let dest = destDir.appendingPathComponent(filename)
        try data.write(to: dest, options: [.atomic])
        return dest
    }

    /// Write an in-memory NSImage (e.g. from clipboard paste) to the staging
    /// dir as a PNG.
    static func stage(image: NSImage, into destDir: URL, attachmentId: UUID) throws -> URL {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ClawdmeterStaging", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't encode pasted image as PNG"])
        }
        let dest = destDir.appendingPathComponent("\(attachmentId.uuidString).png")
        try png.write(to: dest, options: [.atomic])
        return dest
    }

    /// Remove the session's staging dir on archive/end (§3A retention).
    static func cleanup(sessionId: UUID) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let url = appSupport
            .appendingPathComponent("Clawdmeter", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(sessionId.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Worktree-side cleanup: remove the session-specific
    /// `.clawdmeter-attachments/<sessionId>` directory inside the worktree.
    /// Passing nil keeps the legacy whole-root cleanup for callers that are
    /// explicitly removing a registry-owned worktree.
    static func cleanupWorktree(at worktreePath: String, sessionId: UUID? = nil) {
        var url = URL(fileURLWithPath: worktreePath)
            .appendingPathComponent(workspaceWorktreeSubdir, isDirectory: true)
        if let sessionId {
            url = url.appendingPathComponent(sessionId.uuidString, isDirectory: true)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
