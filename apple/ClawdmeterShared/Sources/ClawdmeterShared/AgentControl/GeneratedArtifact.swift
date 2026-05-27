import Foundation

public struct GeneratedArtifact: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case markdownDocument
    }

    public let kind: Kind
    public let path: String
    public let sourceToolName: String?

    public var id: String { "\(kind.rawValue):\(path)" }

    public init(kind: Kind, path: String, sourceToolName: String? = nil) {
        self.kind = kind
        self.path = path
        self.sourceToolName = sourceToolName
    }
}

public enum GeneratedArtifactDetector {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]
    private static let pathKeys: Set<String> = [
        "path", "file", "file_path", "filePath", "filepath",
        "target", "target_path", "targetPath", "destination",
        "destination_path", "destinationPath", "output", "output_path",
        "outputPath", "filename", "name"
    ]
    private static let metadataKeys: Set<String> = [
        "metadata", "artifact", "artifact_metadata", "artifactMetadata",
        "file_metadata", "fileMetadata"
    ]
    private static let markdownMetadataKeys: Set<String> = [
        "kind", "type", "mime", "mime_type", "mimeType",
        "content_type", "contentType", "language", "format",
        "artifactKind", "artifact_kind"
    ]

    public static func isMarkdownPath(_ path: String) -> Bool {
        markdownExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func artifacts(fromToolInput input: Any?, toolName: String) -> [GeneratedArtifact] {
        var artifacts: [GeneratedArtifact] = []
        if isPatchLike(toolName: toolName),
           let patch = patchText(from: input) {
            artifacts.append(contentsOf: markdownPaths(inPatch: patch).map {
                GeneratedArtifact(kind: .markdownDocument, path: $0, sourceToolName: toolName)
            })
        }

        guard isWriteLike(toolName: toolName) else {
            return dedupe(artifacts)
        }

        if let dict = dictionary(from: input) {
            artifacts.append(contentsOf: artifactsInDictionary(dict, toolName: toolName))
        } else if let string = input as? String,
                  let dict = dictionary(fromJSONString: string) {
            artifacts.append(contentsOf: artifactsInDictionary(dict, toolName: toolName))
        }
        return dedupe(artifacts)
    }

    public static func artifactsFromDisplay(title: String, body: String, detail: String?) -> [GeneratedArtifact] {
        guard isWriteLike(toolName: title) else { return [] }
        let text = [body, detail].compactMap { $0 }.joined(separator: "\n")
        var paths: [String] = []
        for candidate in markdownPathCandidates(in: text) where isMarkdownPath(candidate) {
            paths.append(candidate)
        }
        return dedupe(paths.map {
            GeneratedArtifact(kind: .markdownDocument, path: $0, sourceToolName: title)
        })
    }

    private static func artifactsInDictionary(_ dict: [String: Any], toolName: String) -> [GeneratedArtifact] {
        var artifacts: [GeneratedArtifact] = []
        collectPathArtifacts(in: dict, inheritedMarkdownMetadata: dictionaryMarksMarkdown(dict), into: &artifacts, toolName: toolName)
        return artifacts
    }

    private static func collectPathArtifacts(
        in value: Any,
        inheritedMarkdownMetadata: Bool,
        into artifacts: inout [GeneratedArtifact],
        toolName: String
    ) {
        if let dict = value as? [String: Any] {
            let marksMarkdown = inheritedMarkdownMetadata || dictionaryMarksMarkdown(dict)
            for (key, raw) in dict {
                if metadataKeys.contains(key) {
                    collectPathArtifacts(in: raw, inheritedMarkdownMetadata: marksMarkdown, into: &artifacts, toolName: toolName)
                    continue
                }
                if pathKeys.contains(key), let path = stringPath(from: raw),
                   isMarkdownCandidate(path, metadataMarksMarkdown: marksMarkdown) {
                    artifacts.append(GeneratedArtifact(kind: .markdownDocument, path: path, sourceToolName: toolName))
                }
                collectPathArtifacts(in: raw, inheritedMarkdownMetadata: marksMarkdown, into: &artifacts, toolName: toolName)
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectPathArtifacts(in: item, inheritedMarkdownMetadata: inheritedMarkdownMetadata, into: &artifacts, toolName: toolName)
            }
        }
    }

    private static func isMarkdownCandidate(_ path: String, metadataMarksMarkdown: Bool) -> Bool {
        if isMarkdownPath(path) { return true }
        let ext = (path as NSString).pathExtension
        return ext.isEmpty && metadataMarksMarkdown
    }

    private static func dictionaryMarksMarkdown(_ dict: [String: Any]) -> Bool {
        for (key, value) in dict where markdownMetadataKeys.contains(key) {
            if valueMarksMarkdown(value) { return true }
        }
        for key in metadataKeys {
            if let nested = dict[key] as? [String: Any], dictionaryMarksMarkdown(nested) {
                return true
            }
        }
        return false
    }

    private static func valueMarksMarkdown(_ value: Any) -> Bool {
        if let string = value as? String {
            return string.range(of: "markdown", options: .caseInsensitive) != nil
                || string.range(of: "text/x-markdown", options: .caseInsensitive) != nil
                || string.range(of: "text/markdown", options: .caseInsensitive) != nil
        }
        if let dict = value as? [String: Any] {
            return dictionaryMarksMarkdown(dict)
        }
        if let array = value as? [Any] {
            return array.contains(where: valueMarksMarkdown)
        }
        return false
    }

    private static func isWriteLike(toolName: String) -> Bool {
        let normalized = toolName
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        if isPatchLike(toolName: toolName) { return true }
        return normalized.contains("write")
            || normalized.contains("create")
            || normalized.contains("save")
            || normalized.contains("artifact")
            || normalized.contains("file_change")
            || normalized == "edit"
            || normalized == "multiedit"
            || normalized == "multi_edit"
    }

    private static func isPatchLike(toolName: String) -> Bool {
        let normalized = toolName
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        return normalized.contains("apply_patch")
            || normalized.contains("patch")
            || normalized == "edit"
            || normalized == "multiedit"
            || normalized == "multi_edit"
    }

    private static func patchText(from input: Any?) -> String? {
        if let string = input as? String { return string }
        if let dict = dictionary(from: input) {
            for key in ["patch", "diff", "input", "changes", "content"] {
                if let text = dict[key] as? String { return text }
            }
        }
        return nil
    }

    private static func markdownPaths(inPatch patch: String) -> [String] {
        var paths: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line).trimmingCharacters(in: .whitespaces)
            let candidates = [
                stripPrefix("*** Add File: ", from: raw),
                stripPrefix("*** Update File: ", from: raw),
                stripPrefix("*** Delete File: ", from: raw),
                diffPath(from: raw, prefix: "+++ b/"),
                diffPath(from: raw, prefix: "--- b/")
            ].compactMap { $0 }
            for path in candidates where isMarkdownPath(path) {
                paths.append(path)
            }
        }
        return paths
    }

    private static func stripPrefix(_ prefix: String, from line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func diffPath(from line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return rest == "/dev/null" ? nil : rest
    }

    private static func markdownPathCandidates(in text: String) -> [String] {
        let pattern = #"(?i)(?:^|[\s"'`(])((?:(?:~|/|\.{1,2}/|[A-Za-z0-9_.-]+/)[^\s"'`()<>]+|[A-Za-z0-9_.-]+)\.(?:md|markdown|mdown))(?=$|[\s"'`),.])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let pathRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[pathRange])
        }
    }

    private static func stringPath(from value: Any) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
        return trimmed
    }

    private static func dictionary(from input: Any?) -> [String: Any]? {
        input as? [String: Any]
    }

    private static func dictionary(fromJSONString string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func dedupe(_ artifacts: [GeneratedArtifact]) -> [GeneratedArtifact] {
        var seen: Set<String> = []
        var out: [GeneratedArtifact] = []
        for artifact in artifacts {
            let key = "\(artifact.kind.rawValue):\(artifact.path)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(artifact)
        }
        return out
    }
}
