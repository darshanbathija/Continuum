import Foundation

/// Permissive parser for the `name:` + `description:` fields of a
/// Claude-Code-style `SKILL.md` YAML frontmatter. Lives in the shared
/// package so the Mac `SkillCatalog` can call it from its `nonisolated`
/// background scan AND the `ClawdmeterSharedTests` target can exercise
/// every branch (block-scalar, missing-fence, name-only, etc.).
///
/// Returns `nil` for malformed input. Callers swallow that quietly (the
/// CommandPalette skips the skill and logs a warning).
public enum SkillFrontmatter {

    /// Parse the leading `---\n...\n---` block. Returns
    /// `(name, description)` or `nil` if the frontmatter is missing or
    /// the required `name:` key is absent / empty.
    public static func parse(_ content: String) -> (name: String, description: String)? {
        guard content.hasPrefix("---\n") else { return nil }
        let body = content.dropFirst(4)
        guard let endRange = body.range(of: "\n---") else { return nil }
        let header = body[body.startIndex..<endRange.lowerBound]
        var name: String?
        var description: String?
        var inDescriptionBlock = false
        var descLines: [String] = []
        for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if inDescriptionBlock {
                // Block-scalar continuation: indented content keeps streaming.
                if raw.hasPrefix("  ") {
                    descLines.append(raw.trimmingCharacters(in: .whitespaces))
                    continue
                }
                inDescriptionBlock = false
                description = descLines.joined(separator: " ")
            }
            if raw.hasPrefix("name:") {
                name = String(raw.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
            } else if raw.hasPrefix("description:") {
                let v = String(raw.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                if v == "|" || v == ">" {
                    inDescriptionBlock = true
                    descLines = []
                } else {
                    description = v
                }
            }
        }
        if inDescriptionBlock {
            description = descLines.joined(separator: " ")
        }
        guard let name, !name.isEmpty else { return nil }
        return (name, description ?? "")
    }
}
