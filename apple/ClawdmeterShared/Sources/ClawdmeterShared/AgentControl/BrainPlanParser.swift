// Parses the contents of `~/.gemini/antigravity/brain/<uuid>/` into a
// structured `PlanState` for rendering in the Mac Plan pane (Commit 8)
// and iOS Plan tab (Commit 9).
//
// Antigravity 2 creates a `brain/<uuid>/` directory the moment a session
// starts, BEFORE the first turn. On a fresh session you see just an
// empty dir with a `.system_generated/` placeholder. After the first
// agent turn writes `task.md` and `implementation_plan.md`, the parser
// switches from `.awaitingFirstTurn` to `.ready(BrainPlan)`.
//
// Files we read:
//   - `task.md`                              — headline + body
//   - `implementation_plan.md`               — markdown checklist
//   - `*.metadata.json`                      — artifact metadata
//   - `annotations/*.pbtxt`  (optional)       — text-proto annotations
//   - `.system_generated/logs/transcript.jsonl` line 0 — fallback cwd
//
// The Markdown parsing uses Apple's `swift-markdown` library (CommonMark)
// so we handle nesting, fenced code blocks, and intermixed prose
// correctly. The previous regex-based shim only handled flat top-level
// `- [ ] task` lines and would crash on nested sub-steps.

import Foundation
import Markdown
#if canImport(OSLog)
import OSLog
#endif

private let brainPlanLogger = Logger(subsystem: "com.clawdmeter.shared", category: "BrainPlanParser")

/// Wrap a throwing IO call and log the error on failure. Returns nil on
/// failure so callers can fall through with the same semantics as `try?`
/// — they just get a logged trail in Console.app for production triage.
@inline(__always)
private func loggedTry<T>(_ context: @autoclosure () -> String, _ body: () throws -> T) -> T? {
    do { return try body() }
    catch {
        let where_ = context()
        brainPlanLogger.error("\(where_, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

// MARK: - PlanState

/// Top-level state for a brain dir. Callers render different UI for each.
public enum PlanState: Equatable, Sendable {
    /// Brain dir doesn't exist on disk. Caller falls back to "Pick a task"
    /// or "Antigravity not running" CTAs.
    case absent
    /// Brain dir exists but task.md / implementation_plan.md haven't been
    /// written yet — happens on session start, before the first agent
    /// turn. The Plan pane renders a spinner + "Antigravity is preparing
    /// this task…" copy in this state. (Eng review 2A fix: explicit
    /// `.awaitingFirstTurn` case, not nil-coalesced from Optional.)
    case awaitingFirstTurn
    /// Fully populated plan with parsed content.
    case ready(BrainPlan)
}

// MARK: - BrainPlan

/// Parsed brain plan. Holds everything the Plan pane and Plan tab need
/// to render task + steps + annotations.
public struct BrainPlan: Equatable, Sendable {
    /// Brain UUID this plan belongs to.
    public let brainUUID: String
    /// `task.md` first non-blank line — the headline shown on the watch
    /// complication + Plan pane top section + Live Activity.
    public let taskHeadline: String
    /// `task.md` body — everything after the headline. Markdown source
    /// (caller renders).
    public let taskBody: String
    /// Parsed checklist from `implementation_plan.md`. Empty when the
    /// plan file is missing or contains no checklist markers.
    public let steps: [BrainPlanStep]
    /// `annotations/*.pbtxt` entries.
    public let annotations: [BrainAnnotation]
    /// Whether `*.metadata.json` reports `requestFeedback: true` on any
    /// active artifact. Strong signal that this is the active task.
    public let requestsFeedback: Bool
    /// Last-updated timestamp across all parsed files. Used by the watcher
    /// + UI for "updated 3s ago" copy.
    public let lastUpdated: Date

    public init(
        brainUUID: String,
        taskHeadline: String,
        taskBody: String,
        steps: [BrainPlanStep],
        annotations: [BrainAnnotation],
        requestsFeedback: Bool,
        lastUpdated: Date
    ) {
        self.brainUUID = brainUUID
        self.taskHeadline = taskHeadline
        self.taskBody = taskBody
        self.steps = steps
        self.annotations = annotations
        self.requestsFeedback = requestsFeedback
        self.lastUpdated = lastUpdated
    }
}

/// One step in `implementation_plan.md`. Steps can nest arbitrarily deep.
public struct BrainPlanStep: Equatable, Sendable, Identifiable {
    public let id: String
    /// Step text without the `- [ ]` marker.
    public let label: String
    /// `true` when the markdown checkbox is `[x]`, `false` for `[ ]`.
    public let isComplete: Bool
    /// Nesting depth (0 = top-level). Used by SwiftUI list indentation.
    public let depth: Int
    /// Child sub-steps, if any.
    public let children: [BrainPlanStep]

    public init(id: String, label: String, isComplete: Bool, depth: Int, children: [BrainPlanStep]) {
        self.id = id
        self.label = label
        self.isComplete = isComplete
        self.depth = depth
        self.children = children
    }
}

/// One annotation read from `annotations/*.pbtxt`. Currently we surface
/// the file's basename + raw body — when Antigravity ships a real schema
/// for these we'll structure them, but for v0.6.0 the raw body is good
/// enough for the Plan pane to render.
public struct BrainAnnotation: Equatable, Sendable, Identifiable {
    public let id: String
    /// Annotation filename basename (e.g. `408256c2-...pbtxt`).
    public let filename: String
    /// Raw text-proto body.
    public let body: String

    public init(id: String, filename: String, body: String) {
        self.id = id
        self.filename = filename
        self.body = body
    }
}

// MARK: - Parser

/// Pure-function parser for a brain dir. Take a `URL` pointing at
/// `brain/<uuid>/`, return a `PlanState`.
public enum BrainPlanParser {

    /// Parses the brain dir at the given URL. Never throws — every
    /// failure mode collapses into a `PlanState` the UI can render.
    public static func parse(
        brainURL: URL,
        fileManager: FileManager = .default
    ) -> PlanState {
        guard fileManager.fileExists(atPath: brainURL.path) else { return .absent }

        let brainUUID = brainURL.lastPathComponent

        // Read the two key files. Their presence is what flips us out of
        // `.awaitingFirstTurn`.
        let taskURL = brainURL.appendingPathComponent("task.md", isDirectory: false)
        let planURL = brainURL.appendingPathComponent("implementation_plan.md", isDirectory: false)
        let taskExists = fileManager.fileExists(atPath: taskURL.path)
        let planExists = fileManager.fileExists(atPath: planURL.path)

        // No task.md AND no plan.md → we're still waiting for the first turn.
        guard taskExists || planExists else { return .awaitingFirstTurn }

        let taskRaw = taskExists
            ? (loggedTry("read task.md @ \(taskURL.path)") { try String(contentsOf: taskURL, encoding: .utf8) } ?? "")
            : ""
        let planRaw = planExists
            ? (loggedTry("read implementation_plan.md @ \(planURL.path)") { try String(contentsOf: planURL, encoding: .utf8) } ?? "")
            : ""

        let (headline, body) = splitTaskMarkdown(taskRaw)
        let steps = parsePlanChecklist(planRaw)
        let annotations = parseAnnotations(brainURL: brainURL, fileManager: fileManager)
        let requestsFeedback = parseMetadataFlags(brainURL: brainURL, fileManager: fileManager)
        let lastUpdated = latestMTime(
            urls: [taskURL, planURL],
            fileManager: fileManager
        ) ?? Date()

        return .ready(BrainPlan(
            brainUUID: brainUUID,
            taskHeadline: headline,
            taskBody: body,
            steps: steps,
            annotations: annotations,
            requestsFeedback: requestsFeedback,
            lastUpdated: lastUpdated
        ))
    }

    // MARK: - task.md

    /// Splits raw `task.md` into a headline (first non-blank line) and
    /// body (everything after, including the line break). Strips leading
    /// `#`s from the headline so the rendered title doesn't include
    /// markdown syntax.
    static func splitTaskMarkdown(_ raw: String) -> (headline: String, body: String) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        var headline = ""
        var headlineIdx = -1
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                headline = stripHeadingPrefix(trimmed)
                headlineIdx = idx
                break
            }
        }
        if headlineIdx == -1 { return ("", raw) }
        // Body starts after the headline line. Use whitespacesAndNewlines
        // to strip the blank line separator that conventionally follows a
        // markdown heading (`# Title\n\nbody`).
        let bodyLines = lines[(headlineIdx + 1)...]
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (headline, body)
    }

    /// Strips leading `#`/`##`/`###` markdown heading syntax from a single
    /// line. Returns the trimmed text. Keeps the headline word-of-the-line
    /// for the watch complication's 18-char window.
    static func stripHeadingPrefix(_ line: String) -> String {
        var s = line
        while s.hasPrefix("#") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - implementation_plan.md

    /// Parses CommonMark checklist structure into a tree of `BrainPlanStep`.
    /// Walks every UnorderedList / OrderedList in the document and
    /// captures items whose first paragraph starts with `[ ]` / `[x]` /
    /// `[X]`. Items without checkbox markers are ignored (Antigravity's
    /// plan files mix prose with the checklist; we only surface real
    /// steps).
    static func parsePlanChecklist(_ raw: String) -> [BrainPlanStep] {
        guard !raw.isEmpty else { return [] }
        let document = Document(parsing: raw, options: [.parseBlockDirectives])
        var counter = 0
        var steps: [BrainPlanStep] = []
        for child in document.children {
            steps.append(contentsOf: collectSteps(from: child, depth: 0, counter: &counter))
        }
        return steps
    }

    /// Recursive walker. Visits lists, descending into nested lists.
    /// Ignores non-list children (paragraphs, code blocks, headings).
    static func collectSteps(from markup: Markup, depth: Int, counter: inout Int) -> [BrainPlanStep] {
        // List items only emerge as children of an UnorderedList / OrderedList.
        if let unordered = markup as? UnorderedList {
            return unordered.children.compactMap { stepFromListItem($0, depth: depth, counter: &counter) }
        }
        if let ordered = markup as? OrderedList {
            return ordered.children.compactMap { stepFromListItem($0, depth: depth, counter: &counter) }
        }
        // Other block types (headings, code, paragraphs) — descend into
        // their children in case a nested list got wrapped in a block
        // directive.
        var nested: [BrainPlanStep] = []
        for child in markup.children {
            nested.append(contentsOf: collectSteps(from: child, depth: depth, counter: &counter))
        }
        return nested
    }

    /// Pulls one BrainPlanStep from a ListItem if it carries a checkbox.
    /// Recursively descends into the item's children for sub-steps.
    static func stepFromListItem(_ markup: Markup, depth: Int, counter: inout Int) -> BrainPlanStep? {
        guard let item = markup as? ListItem else { return nil }
        // swift-markdown exposes the GitHub Flavored task list checkbox
        // via `item.checkbox`; when nil, the list item isn't a task.
        guard let checkbox = item.checkbox else { return nil }
        let isComplete = (checkbox == .checked)

        // The label is the inline text of the first paragraph child.
        var label = ""
        var childSteps: [BrainPlanStep] = []
        for child in item.children {
            if let paragraph = child as? Paragraph, label.isEmpty {
                label = inlineText(of: paragraph)
            } else {
                childSteps.append(contentsOf: collectSteps(from: child, depth: depth + 1, counter: &counter))
            }
        }
        // Skip whitespace-only labels.
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        counter += 1
        let id = "step-\(counter)"
        return BrainPlanStep(
            id: id,
            label: label,
            isComplete: isComplete,
            depth: depth,
            children: childSteps
        )
    }

    /// Recursively flattens inline markdown into plain text. We DON'T
    /// preserve emphasis / code spans / links — the Plan pane renders
    /// the label as plain text so the checkbox-toggle interaction is
    /// unambiguous.
    static func inlineText(of markup: Markup) -> String {
        var out = ""
        for child in markup.children {
            if let text = child as? Text {
                out += text.string
            } else if let code = child as? InlineCode {
                out += code.code
            } else if let link = child as? Link {
                out += inlineText(of: link)
            } else {
                out += inlineText(of: child)
            }
        }
        return out
    }

    // MARK: - annotations/

    /// Walks `<brain>/annotations/*.pbtxt`, returns one BrainAnnotation
    /// per file. Files outside the dir or unreadable files are skipped
    /// — but the failure is logged so we can spot recurring permission /
    /// schema issues in Console.app.
    static func parseAnnotations(brainURL: URL, fileManager: FileManager) -> [BrainAnnotation] {
        let dir = brainURL.appendingPathComponent("annotations", isDirectory: true)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        guard let entries = loggedTry("contentsOfDirectory \(dir.path)", {
            try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        }) else { return [] }
        var out: [BrainAnnotation] = []
        for url in entries where url.pathExtension == "pbtxt" {
            guard let body = loggedTry("read pbtxt \(url.path)", {
                try String(contentsOf: url, encoding: .utf8)
            }) else { continue }
            let base = url.lastPathComponent
            let id = url.deletingPathExtension().lastPathComponent
            out.append(BrainAnnotation(id: id, filename: base, body: body.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        // Sort by filename for stable diff across refreshes.
        return out.sorted { $0.filename < $1.filename }
    }

    // MARK: - metadata.json flags

    /// Sweeps `*.metadata.json` files for `"requestFeedback": true`.
    /// We don't decode every field — only this flag flips the active-
    /// task indicator. JSON decode failures are silently swallowed (the
    /// metadata format is forgiving and forward-compat with new keys).
    static func parseMetadataFlags(brainURL: URL, fileManager: FileManager) -> Bool {
        guard let entries = loggedTry("contentsOfDirectory \(brainURL.path)", {
            try fileManager.contentsOfDirectory(at: brainURL, includingPropertiesForKeys: nil)
        }) else { return false }
        for url in entries where url.pathExtension == "json" && url.lastPathComponent.hasSuffix(".metadata.json") {
            guard let data = loggedTry("read metadata \(url.path)", { try Data(contentsOf: url) }) else { continue }
            // JSON shape is forward-compat; treat decode failure as "no flag".
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                brainPlanLogger.debug("metadata.json @ \(url.path, privacy: .public) is not a JSON object — skipping")
                continue
            }
            if json["requestFeedback"] as? Bool == true { return true }
        }
        return false
    }

    // MARK: - mtime

    /// Returns the most recent mtime across the given URLs, or nil if
    /// none of them exist.
    static func latestMTime(urls: [URL], fileManager: FileManager) -> Date? {
        var latest: Date?
        for url in urls {
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let date = attrs[.modificationDate] as? Date else { continue }
            if let current = latest {
                if date > current { latest = date }
            } else {
                latest = date
            }
        }
        return latest
    }

    // MARK: - transcript.jsonl line 0 cwd

    /// Reads `<brain>/.system_generated/logs/transcript.jsonl` line 0
    /// and returns the `cwd` field. Used by SessionFileResolver Tier 2
    /// disambiguation in Commit 7. Bounded read — only the first 1 KB
    /// of the file, never the whole thing (eng review 4A fix).
    public static func readTranscriptCwd(brainURL: URL) -> URL? {
        let url = brainURL
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("transcript.jsonl", isDirectory: false)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read at most 1 KB then split on \n and take the first line.
        guard let prefix = try? handle.read(upToCount: 1024) else { return nil }
        guard let text = String(data: prefix, encoding: .utf8) else { return nil }
        guard let firstLine = text.split(separator: "\n").first else { return nil }
        guard let data = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // The cwd may appear under `cwd` (top-level) or `payload.cwd`.
        if let cwd = json["cwd"] as? String {
            return resolveCwdString(cwd)
        }
        if let payload = json["payload"] as? [String: Any], let cwd = payload["cwd"] as? String {
            return resolveCwdString(cwd)
        }
        return nil
    }

    /// Converts a cwd string into a URL — accepts both `file://...` and
    /// plain `/Users/...` paths.
    private static func resolveCwdString(_ cwd: String) -> URL? {
        if cwd.hasPrefix("file://") { return URL(string: cwd) }
        if cwd.hasPrefix("/") { return URL(fileURLWithPath: cwd) }
        return nil
    }
}
