import Foundation

public struct ResolvablePathLink: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(path):\(lineStart)-\(lineEnd ?? lineStart)" }
    public var originalText: String
    public var path: String
    public var absolutePath: String
    public var lineStart: Int
    public var lineEnd: Int?
    public var column: Int?

    public init(
        originalText: String,
        path: String,
        absolutePath: String,
        lineStart: Int,
        lineEnd: Int? = nil,
        column: Int? = nil
    ) {
        self.originalText = originalText
        self.path = path
        self.absolutePath = absolutePath
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.column = column
    }
}

public enum ResolvablePathLinkParser {
    private static let allowedExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "json",
        "jsx", "kt", "m", "md", "mm", "mjs", "py", "rb", "rs", "sh", "sql", "swift",
        "toml", "ts", "tsx", "txt", "vue", "xml", "yaml", "yml"
    ]

    public static func first(in text: String, repoRoot: URL) -> ResolvablePathLink? {
        links(in: text, repoRoot: repoRoot).first
    }

    public static func links(in text: String, repoRoot: URL) -> [ResolvablePathLink] {
        let pattern = #"(?<![\w/.-])((?:~|/|\./|\.\./)?[\w.@()+={}\[\],%-]+(?:/[\w.@()+={}\[\],%-]+)*\.[A-Za-z0-9_+-]+):([0-9]{1,7})(?:-([0-9]{1,7}))?(?::([0-9]{1,5}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let pathRange = Range(match.range(at: 1), in: text),
                  let lineRange = Range(match.range(at: 2), in: text),
                  let line = Int(text[lineRange]),
                  line > 0
            else { return nil }
            let rawPath = String(text[pathRange])
            let ext = URL(fileURLWithPath: rawPath).pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { return nil }
            let lineEnd: Int?
            if let range = Range(match.range(at: 3), in: text), let parsed = Int(text[range]), parsed >= line {
                lineEnd = parsed
            } else {
                lineEnd = nil
            }
            let column: Int?
            if let range = Range(match.range(at: 4), in: text), let parsed = Int(text[range]), parsed > 0 {
                column = parsed
            } else {
                column = nil
            }
            let original = String(text[Range(match.range(at: 0), in: text)!])
            return resolve(rawPath, originalText: original, lineStart: line, lineEnd: lineEnd, column: column, repoRoot: repoRoot)
        }
    }

    public static func resolve(
        _ rawPath: String,
        originalText: String? = nil,
        lineStart: Int,
        lineEnd: Int? = nil,
        column: Int? = nil,
        repoRoot: URL
    ) -> ResolvablePathLink? {
        guard lineStart > 0 else { return nil }
        let root = repoRoot.standardizedFileURL
        let candidate: URL
        if rawPath.hasPrefix("/") || rawPath.hasPrefix("~") {
            candidate = URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath).standardizedFileURL
        } else {
            candidate = root.appendingPathComponent(rawPath).standardizedFileURL
        }
        let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        let relative = candidatePath == rootPath
            ? "."
            : String(candidatePath.dropFirst(rootPath.count + 1))
        return ResolvablePathLink(
            originalText: originalText ?? "\(rawPath):\(lineStart)",
            path: relative,
            absolutePath: candidatePath,
            lineStart: lineStart,
            lineEnd: lineEnd,
            column: column
        )
    }
}
