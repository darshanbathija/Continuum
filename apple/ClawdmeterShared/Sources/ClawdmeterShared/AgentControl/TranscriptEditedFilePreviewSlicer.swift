import Foundation

/// Extracts the per-file preview slice from a multi-file patch payload.
public enum TranscriptEditedFilePreviewSlicer {
    public static func slice(preview: String, filePath: String) -> String {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return preview }

        if trimmed.contains("*** ") {
            let sliced = sliceApplyPatch(trimmed, filePath: filePath)
            if !sliced.isEmpty { return sliced }
        }
        if trimmed.contains("diff --git ") {
            let sliced = sliceUnifiedDiff(trimmed, filePath: filePath)
            if !sliced.isEmpty { return sliced }
        }
        return preview
    }

    private static func sliceApplyPatch(_ preview: String, filePath: String) -> String {
        let normalizedTarget = normalizePath(filePath)
        var currentPath: String?
        var currentLines: [String] = []
        var match: [String] = []

        func flush() {
            guard let currentPath, normalizePath(currentPath) == normalizedTarget else {
                currentLines = []
                return
            }
            match = currentLines
            currentLines = []
        }

        for rawLine in preview.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let path = applyPatchPath(from: line) {
                flush()
                currentPath = path
                currentLines = [rawLine]
                continue
            }
            if currentPath != nil {
                currentLines.append(rawLine)
            }
        }
        flush()
        return match.joined(separator: "\n")
    }

    private static func applyPatchPath(from line: String) -> String? {
        for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "] {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func sliceUnifiedDiff(_ preview: String, filePath: String) -> String {
        let normalizedTarget = normalizePath(filePath)
        let lines = preview.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [(path: String, lines: [String])] = []
        var currentPath: String?
        var currentLines: [String] = []

        func flush() {
            guard let currentPath else { return }
            sections.append((path: currentPath, lines: currentLines))
            currentLines = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = unifiedDiffPath(from: line) ?? currentPath
                currentLines = [line]
            } else if currentPath != nil {
                currentLines.append(line)
            }
            index += 1
        }
        flush()

        if let match = sections.first(where: { normalizePath($0.path) == normalizedTarget }) {
            return match.lines.joined(separator: "\n")
        }
        return ""
    }

    private static func unifiedDiffPath(from header: String) -> String? {
        let body = String(header.dropFirst("diff --git ".count))
        if let range = body.range(of: " b/"),
           body[..<range.lowerBound].hasPrefix("a/") {
            return String(body[range.upperBound...])
        }
        let parts = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let last = parts.last, last.hasPrefix("b/") {
            return String(last.dropFirst(2))
        }
        return nil
    }

    private static func normalizePath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
    }
}
