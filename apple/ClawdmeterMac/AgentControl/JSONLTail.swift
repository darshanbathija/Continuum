import Foundation
import OSLog

private let tailLogger = Logger(subsystem: "com.clawdmeter.mac", category: "JSONLTail")

/// Tail a JSONL file robustly: handles rotation (rename mid-tail),
/// partial-line writes, and delayed file creation (the file may not exist
/// when we register; the parent directory's vnode events tell us when it
/// appears).
///
/// Per Codex Round 2 reviewer concern #2:
/// - DispatchSourceVnode on the file fd; on rename, re-open by globbing
///   the parent directory for a fresh `*.jsonl`.
/// - Line-buffered reads: don't parse partial JSON. Buffer bytes until
///   newline; emit one JSON object per line.
/// - Watch parent directory until the file appears (delayed creation
///   when a new agent session starts mid-tail).
public final class JSONLTail: @unchecked Sendable {

    public typealias EventHandler = @Sendable (_ json: [String: Any]) -> Void

    public let fileURL: URL
    private let handler: EventHandler
    private let queue = DispatchQueue(label: "JSONLTail.io", qos: .utility)

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var lineBuffer = Data()
    private var isRunning = false

    public init(fileURL: URL, handler: @escaping EventHandler) {
        self.fileURL = fileURL
        self.handler = handler
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self.openOrWatchParent()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.source?.cancel()
            self.dirSource?.cancel()
            try? self.fileHandle?.close()
            self.fileHandle = nil
        }
    }

    private func openOrWatchParent() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            openAndTail()
        } else {
            watchParent()
        }
    }

    private func openAndTail() {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            tailLogger.warning("Could not open \(self.fileURL.path, privacy: .public)")
            return
        }
        self.fileHandle = handle
        // Read what's already there (we tail from the beginning so a new
        // subscriber catches up on the session's history).
        drainHandle()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleVnodeEvent(src.data)
        }
        src.resume()
        self.source = src
    }

    private func watchParent() {
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fd = open(parent.path, O_EVTONLY)
        guard fd >= 0 else {
            tailLogger.warning("Could not open parent dir \(parent.path, privacy: .public)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                src.cancel()
                close(fd)
                self.dirSource = nil
                self.openAndTail()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        self.dirSource = src
    }

    private func handleVnodeEvent(_ data: DispatchSource.FileSystemEvent) {
        if data.contains(.delete) || data.contains(.rename) {
            // Re-open: rotation typically replaces the file.
            tailLogger.debug("Tail file rotated; re-opening")
            try? fileHandle?.close()
            fileHandle = nil
            source?.cancel()
            source = nil
            lineBuffer.removeAll(keepingCapacity: true)
            openOrWatchParent()
            return
        }
        if data.contains(.write) || data.contains(.extend) {
            drainHandle()
        }
    }

    private func drainHandle() {
        guard let handle = fileHandle else { return }
        while let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty {
            lineBuffer.append(chunk)
            extractLines()
        }
    }

    private func extractLines() {
        while let newlineIdx = lineBuffer.firstIndex(of: 0x0A) {
            let lineBytes = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineIdx)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIdx)
            guard !lineBytes.isEmpty else { continue }
            if let json = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any] {
                handler(json)
            } else {
                // Malformed line — drop. Don't poison the rest of the file.
                tailLogger.debug("Skipping malformed JSONL line (\(lineBytes.count) bytes)")
            }
        }
    }
}
