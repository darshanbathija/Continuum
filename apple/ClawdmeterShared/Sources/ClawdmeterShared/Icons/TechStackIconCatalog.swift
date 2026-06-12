import Foundation

/// Maps file paths, extensions, and well-known filenames to bundled
/// technology-stack logos in `StackIcons.xcassets` (simple-icons, MIT).
///
/// Used beside file reads, edits, and grep hits in the Code tab transcript
/// so each touched file carries its stack's brand mark — the same visual
/// language Cursor and VS Code use in their agent transcripts.
public enum TechStackIconCatalog {
    /// Bundled asset name for a simple-icons slug, e.g. `stack-swift`.
    public static func assetName(for slug: String) -> String {
        "stack-\(slug)"
    }

    /// Resolve the best stack logo for a filesystem path or filename hint.
    public static func slug(for path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let url = URL(fileURLWithPath: trimmed)
        let basename = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        // Well-known filenames (checked before extension heuristics).
        if let byName = filenameMap[basename] { return byName }
        for (prefix, slug) in filenamePrefixMap where basename.hasPrefix(prefix) {
            return slug
        }

        if let byExt = extensionMap[ext] { return byExt }

        // Special compound names
        if basename == "dockerfile" { return "docker" }
        if basename.hasPrefix("docker-compose") { return "docker" }
        if basename.hasPrefix("vite.config") { return "vite" }
        if basename.hasPrefix("webpack.config") { return "webpack" }
        if basename.hasPrefix("tailwind.config") { return "tailwindcss" }
        if basename.hasPrefix("next.config") { return "nextdotjs" }
        if basename == "nginx.conf" { return "nginx" }

        return nil
    }

    public static func assetName(forPath path: String) -> String? {
        slug(for: path).map(assetName(for:))
    }

    /// Pull a file path out of a tool call's title/body for icon resolution.
    public static func filePathHint(toolTitle: String, body: String, detail: String? = nil) -> String? {
        for candidate in [detail, body] {
            guard let candidate, !candidate.isEmpty else { continue }
            if let path = extractPath(from: candidate) { return path }
        }
        let title = toolTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.contains("/") || title.contains(".") {
            if let path = extractPath(from: title) { return path }
        }
        return nil
    }

    private static func extractPath(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Absolute or relative paths with an extension.
        if trimmed.contains("/") || trimmed.contains(".") {
            let token = trimmed
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .first { $0.contains("/") || $0.contains(".") }
            if let token, slug(for: token) != nil || token.contains(".") {
                return token
            }
            if trimmed.contains("/") || trimmed.contains(".") {
                return trimmed
            }
        }
        return nil
    }

    // MARK: - Lookup tables

    private static let filenameMap: [String: String] = [
        "package.json": "nodedotjs",
        "package-lock.json": "nodedotjs",
        "pnpm-lock.yaml": "nodedotjs",
        "yarn.lock": "nodedotjs",
        "cargo.toml": "rust",
        "cargo.lock": "rust",
        "go.mod": "go",
        "go.sum": "go",
        "gemfile": "ruby",
        "gemfile.lock": "ruby",
        "requirements.txt": "python",
        "pyproject.toml": "python",
        "pipfile": "python",
        "pipfile.lock": "python",
        "composer.json": "php",
        "composer.lock": "php",
        "pubspec.yaml": "flutter",
        "pubspec.lock": "flutter",
        "package.swift": "swift",
        "podfile": "swift",
        "podfile.lock": "swift",
        "build.gradle": "openjdk",
        "build.gradle.kts": "kotlin",
        "settings.gradle": "openjdk",
        "settings.gradle.kts": "kotlin",
        "pom.xml": "openjdk",
        "angular.json": "angular",
        "manage.py": "python",
        "artisan": "php",
        "dockerfile": "docker",
        "makefile": "gnubash",
        "cmakelists.txt": "cplusplus",
        "tsconfig.json": "typescript",
        "jsconfig.json": "javascript",
        "deno.json": "deno",
        "deno.jsonc": "deno",
        "bun.lockb": "bun",
        "bunfig.toml": "bun",
    ]

    private static let filenamePrefixMap: [(String, String)] = [
        ("docker-compose", "docker"),
        ("vite.config", "vite"),
        ("webpack.config", "webpack"),
        ("tailwind.config", "tailwindcss"),
        ("next.config", "nextdotjs"),
        (".github/workflows/", "githubactions"),
    ]

    private static let extensionMap: [String: String] = [
        // Languages
        "swift": "swift",
        "ts": "typescript",
        "tsx": "typescript",
        "mts": "typescript",
        "cts": "typescript",
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "py": "python",
        "pyw": "python",
        "pyi": "python",
        "go": "go",
        "rs": "rust",
        "rb": "ruby",
        "erb": "ruby",
        "java": "openjdk",
        "kt": "kotlin",
        "kts": "kotlin",
        "cs": "csharp",
        "fs": "dotnet",
        "fsx": "dotnet",
        "fsi": "dotnet",
        "cpp": "cplusplus",
        "cc": "cplusplus",
        "cxx": "cplusplus",
        "hpp": "cplusplus",
        "hh": "cplusplus",
        "h": "c",
        "c": "c",
        "php": "php",
        "dart": "dart",
        "scala": "scala",
        "sc": "scala",
        "lua": "lua",
        "ex": "elixir",
        "exs": "elixir",
        "hs": "haskell",
        "zig": "zig",
        "r": "python",
        "pl": "perl",
        "pm": "perl",
        // Markup & styling
        "html": "html5",
        "htm": "html5",
        "css": "css3",
        "scss": "css3",
        "sass": "css3",
        "less": "css3",
        "vue": "vuedotjs",
        "svelte": "svelte",
        "md": "markdown",
        "mdx": "markdown",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "yaml",
        "json": "javascript",
        // Infra & ops
        "tf": "terraform",
        "tfvars": "terraform",
        "graphql": "graphql",
        "gql": "graphql",
        "sql": "postgresql",
        "sh": "gnubash",
        "bash": "gnubash",
        "zsh": "gnubash",
        "fish": "gnubash",
        "ps1": "powershell",
        "psm1": "powershell",
        // Project / config
        "sln": "dotnet",
        "csproj": "csharp",
        "fsproj": "dotnet",
        "xcodeproj": "swift",
        "xcworkspace": "swift",
        "podspec": "swift",
    ]
}
