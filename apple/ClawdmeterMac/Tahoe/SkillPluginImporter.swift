import Foundation
import ClawdmeterShared

enum SkillPluginImportError: LocalizedError, Equatable {
    case emptyInput
    case unrecognizedURL(String)
    case cloneFailed(String)
    case noSkillsFound(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Paste a GitHub or skills.sh link to import."
        case .unrecognizedURL(let input):
            return "Could not parse “\(input)” as a GitHub or skills.sh link."
        case .cloneFailed(let detail):
            return detail
        case .noSkillsFound(let path):
            return "No SKILL.md files were found under \(path)."
        }
    }
}

struct SkillPluginImportSource: Equatable {
    let title: String
    let cloneSpec: String
    let repositorySubpath: String?
    let requestedSkillName: String?
    let sourceURL: String
}

enum SkillPluginImporter {
    static let pluginsRootRelative = "~/.clawdmeter/skills/plugins"

    static var pluginsRoot: String {
        NSString(string: pluginsRootRelative).expandingTildeInPath
    }

    static func parse(_ raw: String) throws -> SkillPluginImportSource {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { throw SkillPluginImportError.emptyInput }

        if (input.hasPrefix("\"") && input.hasSuffix("\"")) || (input.hasPrefix("'") && input.hasSuffix("'")) {
            input = String(input.dropFirst().dropLast())
        }

        if let source = parseSkillsShURL(input) ?? parseGitHubTreeURL(input) {
            return source
        }

        if let atIndex = input.lastIndex(of: "@"), !input.contains("://") {
            let repoPart = String(input[..<atIndex])
            let skillPart = String(input[input.index(after: atIndex)...]).trimmingCharacters(in: .whitespaces)
            let cloneSpec = try normalizeCloneSpec(repoPart)
            let title = skillPart.isEmpty ? cloneSpec : "\(cloneSpec) · \(skillPart)"
            return SkillPluginImportSource(
                title: title,
                cloneSpec: cloneSpec,
                repositorySubpath: skillPart.isEmpty ? nil : skillPart,
                requestedSkillName: skillPart.isEmpty ? nil : skillPart,
                sourceURL: input
            )
        }

        let cloneSpec = try normalizeCloneSpec(input)
        return SkillPluginImportSource(
            title: cloneSpec,
            cloneSpec: cloneSpec,
            repositorySubpath: nil,
            requestedSkillName: nil,
            sourceURL: input
        )
    }

    static func importPlugin(from raw: String) async throws -> SkillPluginRecord {
        let source = try parse(raw)
        let slug = directorySlug(for: source)
        let destination = (pluginsRoot as NSString).appendingPathComponent(slug)

        try ensurePluginsRootExists()
        if FileManager.default.fileExists(atPath: destination) {
            try FileManager.default.removeItem(atPath: destination)
        }

        try await cloneRepository(spec: source.cloneSpec, destination: destination)
        let effectiveRoot = try resolveSkillsRoot(
            cloneRoot: destination,
            repositorySubpath: source.repositorySubpath,
            requestedSkillName: source.requestedSkillName
        )

        guard SkillCatalog.pluginRootContainsSkills(effectiveRoot) else {
            // Don't leave a useless clone parked on disk after a failed import.
            try? FileManager.default.removeItem(atPath: destination)
            throw SkillPluginImportError.noSkillsFound(effectiveRoot)
        }

        return SkillPluginRecord(
            id: UUID().uuidString.lowercased(),
            title: source.title,
            rootPath: effectiveRoot,
            sourceURL: source.sourceURL
        )
    }

    // MARK: - URL parsing

    private static func parseSkillsShURL(_ input: String) -> SkillPluginImportSource? {
        guard let url = URL(string: input),
              let host = url.host?.lowercased(),
              host == "skills.sh" || host.hasSuffix(".skills.sh")
        else { return nil }

        var parts = url.path.split(separator: "/").map(String.init)
        if parts.first == "b" { parts.removeFirst() }
        guard parts.count >= 2 else { return nil }

        let owner = parts[0]
        let repo = parts[1]
        let cloneSpec = "\(owner)/\(repo)"
        let remainder = parts.dropFirst(2).joined(separator: "/")
        let title = remainder.isEmpty ? cloneSpec : "\(cloneSpec) · \(remainder)"
        return SkillPluginImportSource(
            title: title,
            cloneSpec: cloneSpec,
            repositorySubpath: remainder.isEmpty ? nil : remainder,
            requestedSkillName: remainder.isEmpty ? nil : remainder.split(separator: "/").last.map(String.init),
            sourceURL: input
        )
    }

    private static func parseGitHubTreeURL(_ input: String) -> SkillPluginImportSource? {
        guard input.contains("github.com"), input.contains("/tree/") else { return nil }
        let pattern = #"github\.com/([^/]+)/([^/]+)/tree/[^/]+/(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges == 4,
              let ownerRange = Range(match.range(at: 1), in: input),
              let repoRange = Range(match.range(at: 2), in: input),
              let pathRange = Range(match.range(at: 3), in: input)
        else { return nil }

        let owner = String(input[ownerRange])
        let repo = String(input[repoRange]).replacingOccurrences(of: ".git", with: "")
        let subpath = String(input[pathRange])
        let cloneSpec = "\(owner)/\(repo)"
        let title = "\(cloneSpec) · \(subpath)"
        return SkillPluginImportSource(
            title: title,
            cloneSpec: cloneSpec,
            repositorySubpath: subpath,
            requestedSkillName: subpath.split(separator: "/").last.map(String.init),
            sourceURL: input
        )
    }

    // MARK: - Install

    private static func directorySlug(for source: SkillPluginImportSource) -> String {
        var slug = source.cloneSpec.replacingOccurrences(of: "/", with: "-")
        if let skill = source.requestedSkillName, !skill.isEmpty {
            slug += "-\(skill)"
        }
        return slug
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func ensurePluginsRootExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: pluginsRoot) {
            try fm.createDirectory(atPath: pluginsRoot, withIntermediateDirectories: true)
        }
    }

    private static func cloneRepository(spec: String, destination: String) async throws {
        let ghPath = ShellRunner.locateBinary("gh")
        let gitPath = ShellRunner.locateBinary("git")
        let executable: String
        let args: [String]
        if let gh = ghPath {
            executable = gh
            args = ["repo", "clone", spec, destination]
        } else if let git = gitPath {
            executable = git
            args = ["clone", "https://github.com/\(spec).git", destination]
        } else {
            throw SkillPluginImportError.cloneFailed("Neither `gh` nor `git` is installed.")
        }

        do {
            let result = try await ShellRunner.shared.run(
                executable: executable,
                arguments: args,
                timeout: 300
            )
            if result.exitStatus != 0 {
                let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SkillPluginImportError.cloneFailed(
                    stderr.isEmpty ? "Clone failed for \(spec)." : stderr
                )
            }
        } catch let error as SkillPluginImportError {
            throw error
        } catch {
            throw SkillPluginImportError.cloneFailed(error.localizedDescription)
        }
    }

    static func resolveSkillsRoot(
        cloneRoot: String,
        repositorySubpath: String?,
        requestedSkillName: String?
    ) throws -> String {
        let fm = FileManager.default

        if let subpath = repositorySubpath, !subpath.isEmpty, !hasPathTraversal(subpath) {
            let candidate = (cloneRoot as NSString).appendingPathComponent(subpath)
            if fm.fileExists(atPath: candidate) {
                if fm.fileExists(atPath: (candidate as NSString).appendingPathComponent("SKILL.md")) {
                    return (candidate as NSString).deletingLastPathComponent
                }
                return candidate
            }
        }

        let skillsDir = (cloneRoot as NSString).appendingPathComponent("skills")
        if directoryContainsSkillFolders(skillsDir) {
            return skillsDir
        }

        if fm.fileExists(atPath: (cloneRoot as NSString).appendingPathComponent("SKILL.md")) {
            return cloneRoot
        }

        if directoryContainsSkillFolders(cloneRoot) {
            return cloneRoot
        }

        if let requestedSkillName, !requestedSkillName.isEmpty, !hasPathTraversal(requestedSkillName) {
            let nested = (skillsDir as NSString).appendingPathComponent(requestedSkillName)
            if fm.fileExists(atPath: (nested as NSString).appendingPathComponent("SKILL.md")) {
                return skillsDir
            }
            let flat = (cloneRoot as NSString).appendingPathComponent(requestedSkillName)
            if fm.fileExists(atPath: (flat as NSString).appendingPathComponent("SKILL.md")) {
                return cloneRoot
            }
        }

        return cloneRoot
    }

    private static func directoryContainsSkillFolders(_ path: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return entries.contains { entry in
            FileManager.default.fileExists(
                atPath: (path as NSString).appendingPathComponent("\(entry)/SKILL.md")
            )
        }
    }

    /// Reject a `..` component so a crafted import string (e.g.
    /// `owner/repo@../../etc`) can't repoint the indexed skill root outside
    /// the cloned plugin directory.
    static func hasPathTraversal(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func normalizeCloneSpec(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { throw SkillPluginImportError.unrecognizedURL(raw) }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        if s.hasPrefix("git@github.com:") {
            let body = String(s.dropFirst("git@github.com:".count))
            return try stripDotGitAndValidate(body, original: raw)
        }
        for prefix in ["https://github.com/", "http://github.com/", "git://github.com/"] {
            if s.hasPrefix(prefix) {
                let body = String(s.dropFirst(prefix.count))
                return try stripDotGitAndValidate(body, original: raw)
            }
        }
        return try stripDotGitAndValidate(s, original: raw)
    }

    private static func stripDotGitAndValidate(_ s: String, original: String) throws -> String {
        let stripped = s.hasSuffix(".git") ? String(s.dropLast(4)) : s
        let parts = stripped.split(separator: "/", omittingEmptySubsequences: true)
        // Reject a leading "-" so the owner/repo can't be parsed as a flag by
        // `gh repo clone <spec>` (the git fallback embeds it in a URL, safe).
        if parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty,
           !parts[0].contains(" "), !parts[1].contains(" "),
           !parts[0].hasPrefix("-"), !parts[1].hasPrefix("-") {
            return "\(parts[0])/\(parts[1])"
        }
        throw SkillPluginImportError.unrecognizedURL(original)
    }
}
