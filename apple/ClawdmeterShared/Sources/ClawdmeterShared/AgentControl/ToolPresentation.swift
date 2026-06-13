import Foundation

public enum TranscriptDensity: String, Codable, CaseIterable, Sendable {
    case compact
    case balanced
    case detailed

    public var label: String {
        switch self {
        case .compact: return "Compact"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .balanced
    }
}

public enum ToolPresentationTone: String, Codable, Sendable {
    case neutral
    case read
    case write
    case shell
    case web
    case agent
    case search
    case explore
    case thinking
    case delete
    case warning
}

public struct ToolPresentation: Codable, Hashable, Sendable {
    public let normalizedKind: String
    public let displayName: String
    public let systemImageName: String
    public let tone: ToolPresentationTone
    public let summary: String
    public let detail: String?
    public let defaultExpanded: Bool

    public init(
        normalizedKind: String,
        displayName: String,
        systemImageName: String,
        tone: ToolPresentationTone,
        summary: String,
        detail: String? = nil,
        defaultExpanded: Bool = false
    ) {
        self.normalizedKind = normalizedKind
        self.displayName = displayName
        self.systemImageName = systemImageName
        self.tone = tone
        self.summary = summary
        self.detail = detail
        self.defaultExpanded = defaultExpanded
    }
}

public enum ToolPresentationCatalog {
    public static func normalizedKind(for rawName: String) -> String {
        let lowered = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowered {
        case "bash", "shell", "exec", "exec_command", "command_execution",
             "run_terminal_cmd", "runterminalcmd", "terminal":
            return "bash"
        case "read", "view_file", "open_file", "read_file":
            return "read"
        case "grep", "rg", "ripgrep":
            return "grep"
        case "glob", "glob_file_search", "file_search":
            return "glob"
        case "list_dir", "listdir", "ls", "list_directory":
            return "list_dir"
        case "write", "file_change", "write_file", "create_file":
            return "write"
        case "edit", "strreplace", "searchreplace", "search_replace", "notebookedit":
            return "edit"
        case "multiedit", "multi_edit":
            return "multiedit"
        case "apply_patch", "applypatch":
            return "apply_patch"
        case "delete", "delete_file", "remove", "deletefile":
            return "delete"
        case "webfetch", "web_fetch", "fetch":
            return "web_fetch"
        case "websearch", "web_search", "search", "codebase_search",
             "semanticsearch", "semantic_search":
            return "web_search"
        case "task", "spawn_agent", "subagent", "agent":
            return "task"
        case "askuserquestion", "ask_user_question":
            return "ask_user"
        case "think", "thinking", "reasoning", "extended_thinking":
            return "thinking"
        case "mcp_call_tool", "call_mcp_tool", "mcp", "list_mcp_resources",
             "fetch_mcp_resource", "listmcptools":
            return "mcp"
        case "generate_image", "generateimage", "image_generation":
            return "generate_image"
        case "todowrite", "todo_write", "todo":
            return "todo"
        case "switchmode", "switch_mode", "plan":
            return "switch_mode"
        case "skill", "invokeskill":
            return "skill"
        case "await", "sleep", "wait":
            return "await"
        default:
            return lowered.isEmpty ? "tool" : lowered
        }
    }

    public static func presentation(
        for rawName: String,
        summary: String = "",
        detail: String? = nil,
        isError: Bool = false
    ) -> ToolPresentation {
        let kind = normalizedKind(for: rawName)
        let metadata = metadata(for: kind, rawName: rawName, isError: isError)
        return ToolPresentation(
            normalizedKind: kind,
            displayName: metadata.displayName,
            systemImageName: metadata.systemImageName,
            tone: metadata.tone,
            summary: summary,
            detail: detail,
            defaultExpanded: metadata.defaultExpanded
        )
    }

    private static func metadata(
        for kind: String,
        rawName: String,
        isError: Bool
    ) -> (displayName: String, systemImageName: String, tone: ToolPresentationTone, defaultExpanded: Bool) {
        if isError {
            return (displayName(rawName), "exclamationmark.triangle.fill", .warning, true)
        }
        switch kind {
        case "bash":
            return ("Bash", "terminal.fill", .shell, false)
        case "read":
            return ("Read", "doc.text", .read, false)
        case "grep":
            return ("Grep", "line.3.horizontal.decrease.circle", .search, false)
        case "glob":
            return ("Glob", "sparkle.magnifyingglass", .explore, false)
        case "list_dir":
            return ("List", "folder", .explore, false)
        case "write":
            return ("Write", "square.and.pencil", .write, false)
        case "edit":
            return ("Edit", "pencil", .write, false)
        case "multiedit":
            return ("MultiEdit", "pencil.and.scribble", .write, false)
        case "apply_patch":
            return ("Patch", "doc.badge.gearshape", .write, false)
        case "delete":
            return ("Delete", "trash", .delete, false)
        case "web_fetch":
            return ("Web fetch", "arrow.down.circle", .web, false)
        case "web_search":
            return ("Web search", "globe.americas.fill", .web, false)
        case "task":
            return ("Agent", "person.2.fill", .agent, false)
        case "ask_user":
            return ("Question", "questionmark.bubble.fill", .agent, false)
        case "thinking":
            return ("Thinking", "brain.head.profile", .thinking, false)
        case "mcp":
            return ("MCP", "puzzlepiece.extension.fill", .neutral, false)
        case "generate_image":
            return ("Image", "photo.artframe", .neutral, false)
        case "todo":
            return ("Todo", "checklist", .neutral, false)
        case "switch_mode":
            return ("Mode", "arrow.triangle.2.circlepath", .neutral, false)
        case "skill":
            return ("Skill", "sparkles", .agent, false)
        case "await":
            return ("Wait", "hourglass", .neutral, false)
        default:
            return (displayName(rawName), "wrench.adjustable", .neutral, false)
        }
    }

    private static func displayName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "web_search": return "Web search"
        case "web_fetch": return "Web fetch"
        case "exec_command": return "Bash"
        case "glob_file_search": return "Glob"
        case "list_dir": return "List"
        case "askuserquestion", "ask_user_question": return "Question"
        case "multiedit", "multi_edit": return "MultiEdit"
        case "apply_patch": return "Patch"
        default:
            if raw.isEmpty { return "Tool" }
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

public struct EditDiff: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case edit
        case multiEdit
        case write
        case applyPatch
    }

    public static let previewCharacterLimit = 16_384

    public let kind: Kind
    public let filePath: String?
    public let additions: Int
    public let deletions: Int
    public let preview: String?
    public let isTruncated: Bool

    public init(
        kind: Kind,
        filePath: String?,
        additions: Int,
        deletions: Int,
        preview: String? = nil,
        isTruncated: Bool = false
    ) {
        self.kind = kind
        self.filePath = filePath
        self.additions = additions
        self.deletions = deletions
        self.preview = preview
        self.isTruncated = isTruncated
    }

    public static func fromClaudeInput(_ input: Any?, toolName: String) -> EditDiff? {
        guard let dict = input as? [String: Any] else { return nil }
        switch toolName {
        case "Edit":
            guard let path = dict["file_path"] as? String,
                  let oldStr = dict["old_string"] as? String,
                  let newStr = dict["new_string"] as? String else { return nil }
            return EditDiff(
                kind: .edit,
                filePath: path,
                additions: lineCount(newStr),
                deletions: lineCount(oldStr),
                preview: capped(newStr).text,
                isTruncated: capped(newStr).truncated
            )
        case "MultiEdit":
            guard let path = dict["file_path"] as? String,
                  let edits = dict["edits"] as? [[String: Any]] else { return nil }
            var add = 0
            var del = 0
            var previewParts: [String] = []
            for edit in edits {
                if let oldStr = edit["old_string"] as? String { del += lineCount(oldStr) }
                if let newStr = edit["new_string"] as? String {
                    add += lineCount(newStr)
                    previewParts.append(newStr)
                }
            }
            let cappedPreview = capped(previewParts.joined(separator: "\n"))
            return EditDiff(
                kind: .multiEdit,
                filePath: path,
                additions: add,
                deletions: del,
                preview: cappedPreview.text,
                isTruncated: cappedPreview.truncated
            )
        case "Write":
            guard let path = dict["file_path"] as? String,
                  let content = dict["content"] as? String else { return nil }
            let cappedPreview = capped(content)
            return EditDiff(
                kind: .write,
                filePath: path,
                additions: lineCount(content),
                deletions: 0,
                preview: cappedPreview.text,
                isTruncated: cappedPreview.truncated
            )
        default:
            return nil
        }
    }

    public static func fromCodexInput(_ input: [String: Any], toolName: String) -> EditDiff? {
        if toolName == "apply_patch", let patch = stringValue(input["patch"]) ?? stringValue(input["input"]) {
            return fromPatch(patch)
        }
        if toolName == "exec_command" || toolName == "shell" {
            let command = stringValue(input["cmd"]) ?? stringValue(input["command"])
            if let command, command.contains("apply_patch") {
                return fromPatch(command)
            }
        }
        return nil
    }

    public static func fromPatch(_ patch: String) -> EditDiff {
        var filePath: String?
        var additions = 0
        var deletions = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("*** Update File: ") {
                filePath = String(line.dropFirst("*** Update File: ".count))
            } else if line.hasPrefix("*** Add File: ") {
                filePath = String(line.dropFirst("*** Add File: ".count))
            } else if line.hasPrefix("+++ b/") {
                filePath = String(line.dropFirst("+++ b/".count))
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                additions += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                deletions += 1
            }
        }
        let cappedPreview = capped(patch)
        return EditDiff(
            kind: .applyPatch,
            filePath: filePath,
            additions: additions,
            deletions: deletions,
            preview: cappedPreview.text,
            isTruncated: cappedPreview.truncated
        )
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let string = any as? String {
            return string
        }
        if let array = any as? [String] {
            return array.joined(separator: " ")
        }
        return nil
    }

    private static func capped(_ text: String) -> (text: String?, truncated: Bool) {
        guard !text.isEmpty else { return (nil, false) }
        if text.count <= previewCharacterLimit {
            return (text, false)
        }
        return (String(text.prefix(previewCharacterLimit)), true)
    }

    private static func lineCount(_ s: String) -> Int {
        if s.isEmpty { return 0 }
        var n = 1
        for c in s where c == "\n" { n += 1 }
        if s.hasSuffix("\n") { n -= 1 }
        return max(n, 1)
    }
}

public struct BashResult: Codable, Hashable, Sendable {
    public static let outputCharacterLimit = 16_384

    public let command: String?
    public let exitCode: Int?
    public let cwd: String?
    public let durationMS: Int?
    public let stdout: String?
    public let stderr: String?
    public let isTruncated: Bool

    public init(
        command: String? = nil,
        exitCode: Int? = nil,
        cwd: String? = nil,
        durationMS: Int? = nil,
        stdout: String? = nil,
        stderr: String? = nil,
        isTruncated: Bool = false
    ) {
        self.command = command
        self.exitCode = exitCode
        self.cwd = cwd
        self.durationMS = durationMS
        self.stdout = stdout
        self.stderr = stderr
        self.isTruncated = isTruncated
    }

    public static func fromToolCallInput(_ input: [String: Any], toolName: String) -> BashResult? {
        guard ToolPresentationCatalog.normalizedKind(for: toolName) == "bash" else { return nil }
        let command = (input["command"] as? String)
            ?? (input["cmd"] as? String)
            ?? (input["cmd"] as? [String])?.joined(separator: " ")
        guard command != nil else { return nil }
        return BashResult(command: command, cwd: input["cwd"] as? String)
    }

    public static func fromOutputEnvelope(
        _ envelope: [String: Any],
        fallbackOutput: String? = nil,
        command: String? = nil
    ) -> BashResult {
        let stdoutRaw = (envelope["stdout"] as? String)
            ?? (envelope["output"] as? String)
            ?? fallbackOutput
        let stderrRaw = envelope["stderr"] as? String
        let stdout = capped(stdoutRaw)
        let stderr = capped(stderrRaw)
        return BashResult(
            command: command ?? (envelope["command"] as? String),
            exitCode: envelope["exit_code"] as? Int ?? envelope["exitCode"] as? Int,
            cwd: envelope["cwd"] as? String,
            durationMS: envelope["duration_ms"] as? Int ?? envelope["durationMS"] as? Int,
            stdout: stdout.text,
            stderr: stderr.text,
            isTruncated: stdout.truncated || stderr.truncated
        )
    }

    private static func capped(_ text: String?) -> (text: String?, truncated: Bool) {
        guard let text, !text.isEmpty else { return (nil, false) }
        if text.count <= outputCharacterLimit {
            return (text, false)
        }
        return (String(text.prefix(outputCharacterLimit)), true)
    }
}
