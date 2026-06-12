import Foundation

/// Formats human-readable primary labels for agent tool actions — the
/// Cursor-style "Read 80 lines", "grep", "Glob *.swift" headlines shown
/// beside each tool icon in the Code tab transcript.
public enum ToolActionSummary {
    public static func primaryLabel(
        toolName: String,
        callBody: String,
        resultBody: String? = nil
    ) -> String {
        let kind = ToolPresentationCatalog.normalizedKind(for: toolName)
        switch kind {
        case "read":
            if let count = lineCount(from: resultBody) {
                return "Read \(count) line\(count == 1 ? "" : "s")"
            }
            return "Read"
        case "grep":
            let pattern = callBody.trimmingCharacters(in: .whitespacesAndNewlines)
            return pattern.isEmpty ? "grep" : "grep \(pattern)"
        case "glob":
            let pattern = callBody.trimmingCharacters(in: .whitespacesAndNewlines)
            return pattern.isEmpty ? "Glob" : "Glob \(pattern)"
        case "list_dir":
            return "List"
        case "bash":
            let command = callBody.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? "Bash" : command
        case "web_search":
            let query = callBody.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? "Web search" : query
        case "web_fetch":
            return "Web fetch"
        case "thinking":
            return "Thinking"
        default:
            return ToolPresentationCatalog.presentation(for: toolName).displayName
        }
    }

    public static func filePath(
        toolName: String,
        callBody: String,
        detail: String? = nil
    ) -> String? {
        TechStackIconCatalog.filePathHint(toolTitle: toolName, body: callBody, detail: detail)
    }

    public static func showsFileChip(toolName: String) -> Bool {
        switch ToolPresentationCatalog.normalizedKind(for: toolName) {
        case "read", "write", "edit", "multiedit", "apply_patch", "delete":
            return true
        default:
            return false
        }
    }

    public static func rendersFlatRow(toolName: String) -> Bool {
        ToolPresentationCatalog.normalizedKind(for: toolName) != "bash"
    }

    private static func lineCount(from resultBody: String?) -> Int? {
        guard let resultBody else { return nil }
        let text = resultBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*lines?"#, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[numberRange])
    }
}
