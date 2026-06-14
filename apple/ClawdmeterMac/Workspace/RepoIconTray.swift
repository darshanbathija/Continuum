import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClawdmeterShared

/// Identifies which project's icon tray is open. Drives `.popover(item:)` off
/// the repo-header glyph. Equatable + Identifiable on the repo key so the
/// popover re-presents cleanly when the user clicks a different project.
struct RepoIconTrayTarget: Identifiable, Equatable {
    let repoKey: String
    let displayName: String
    var id: String { repoKey }
}

/// Emoji / custom-image picker for a Code-sidebar project icon. Clicking the
/// repo monogram opens this tray; a pick replaces the auto hue+initial glyph
/// across the header and that repo's session rows. Persisted via
/// `SessionPresentationStore.repoIconOverrides` (keyed by repo key), kept
/// separate from the git-resolved `repoIdentityBadges` so a remote re-resolve
/// never clobbers the user's choice.
struct RepoIconTray: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var presentationStore: SessionPresentationStore
    let target: RepoIconTrayTarget
    let onClose: () -> Void

    @State private var pasteField: String = ""
    @State private var importing = false
    @State private var importError: String?

    /// One-click common picks. The free-form paste field below covers every
    /// other emoji via the system picker (⌃⌘Space) or paste.
    private static let curated: [String] = [
        "🚀", "🐙", "🦊", "📁", "🧪", "🛠️", "🎨", "📦",
        "🔥", "⚡️", "🌊", "🪐", "🤖", "🧠", "💎", "🌙",
        "🐧", "🦀", "🐍", "☕️", "📊", "🔒", "🧩", "🎯",
    ]

    private var currentOverride: RepoIconOverride? {
        presentationStore.snapshot.repoIconOverrides[target.repoKey]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            emojiGrid
            pasteRow
            TahoeHairline()
            footer
            if let importError {
                Text(importError)
                    .font(TahoeFont.body(10))
                    .foregroundStyle(t.error)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: 268)
        .background(t.surface3)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("PROJECT ICON")
                .font(TahoeFont.mono(10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.fg3)
            Spacer(minLength: 6)
            Text(target.displayName)
                .font(TahoeFont.body(10.5))
                .foregroundStyle(t.fg3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 8), spacing: 4) {
            ForEach(Self.curated, id: \.self) { emoji in
                let selected = currentOverride?.emoji == emoji
                Button {
                    assign(emoji: emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 16))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? t.hover : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(selected ? t.accent.opacity(0.7) : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Use \(emoji)")
            }
        }
    }

    private var pasteRow: some View {
        HStack(spacing: 6) {
            TextField("Paste or type any emoji", text: $pasteField)
                .textFieldStyle(.plain)
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(t.surface2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(t.hair2, lineWidth: 0.7)
                )
                .onSubmit { assignPastedEmoji() }
            Button("Set", action: assignPastedEmoji)
                .buttonStyle(.plain)
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(firstEmoji(in: pasteField) == nil ? t.fg3 : t.fg)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(t.surface2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .disabled(firstEmoji(in: pasteField) == nil)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                importError = nil
                importing = true
            } label: {
                Label("Custom Image…", systemImage: "photo")
                    .font(TahoeFont.body(11, weight: .medium))
                    .foregroundStyle(t.fg2)
            }
            .buttonStyle(.plain)
            .help("Use a custom image (logo / icon) for this project")

            Spacer(minLength: 0)

            if currentOverride != nil {
                Button(role: .destructive) {
                    RepoIconStaging.removeImage(at: currentOverride?.imagePath)
                    try? presentationStore.clearRepoIcon(repoKey: target.repoKey)
                    onClose()
                } label: {
                    Text("Remove")
                        .font(TahoeFont.body(11, weight: .medium))
                        .foregroundStyle(t.fg3)
                }
                .buttonStyle(.plain)
                .help("Remove the custom icon and restore the lettered monogram")
            }
        }
    }

    // MARK: - Actions

    private func assign(emoji: String) {
        // Drop any prior staged image so we don't orphan files on disk.
        RepoIconStaging.removeImage(at: currentOverride?.imagePath)
        try? presentationStore.setRepoIconEmoji(repoKey: target.repoKey, emoji: emoji)
        onClose()
    }

    private func assignPastedEmoji() {
        guard let emoji = firstEmoji(in: pasteField) else { return }
        assign(emoji: emoji)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let source = urls.first else { return }
            do {
                let staged = try RepoIconStaging.stageImage(from: source, repoKey: target.repoKey)
                try presentationStore.setRepoIconImagePath(repoKey: target.repoKey, path: staged)
                onClose()
            } catch {
                importError = "Couldn't use that image: \(error.localizedDescription)"
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// First grapheme that is an emoji presentation, so pasting "🚀 my repo"
    /// yields just "🚀".
    private func firstEmoji(in text: String) -> String? {
        for character in text where character.isLikelyEmoji {
            return String(character)
        }
        return nil
    }
}

private extension Character {
    /// True when the character renders as a color emoji (excludes plain ASCII
    /// digits / `#` / `*`, which carry the `isEmoji` scalar property but aren't
    /// what the user means when "assigning an emoji"). Handles both
    /// emoji-default scalars and text-default scalars promoted by a U+FE0F
    /// variation selector (e.g. "⚡️").
    var isLikelyEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation
            || unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || (scalar.properties.isEmoji && scalar.value > 0x238C)
    }
}

/// The repo-header monogram, made clickable: tapping it opens the icon tray
/// anchored to the glyph. Each instance owns its own `.popover(isPresented:)`
/// so we never bind N sidebar headers to one shared optional (the documented
/// per-row dialog anti-pattern elsewhere in this pane).
struct RepoGlyphButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var presentationStore: SessionPresentationStore
    let repo: AgentRepo
    @State private var trayOpen = false

    var body: some View {
        Button { trayOpen = true } label: {
            RepoProjectGlyph(
                repoKey: repo.key,
                displayName: repo.displayName,
                override: presentationStore.snapshot.repoIconOverrides[repo.key],
                colorScheme: colorScheme
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Set an icon for \(repo.displayName)")
        .accessibilityLabel("Set project icon for \(repo.displayName)")
        .accessibilityIdentifier("code.repo.icon")
        .popover(isPresented: $trayOpen, arrowEdge: .bottom) {
            RepoIconTray(
                presentationStore: presentationStore,
                target: RepoIconTrayTarget(repoKey: repo.key, displayName: repo.displayName),
                onClose: { trayOpen = false }
            )
        }
    }
}

/// Renders a project's sidebar glyph: a user-chosen custom image or emoji when
/// set, otherwise the auto hue+initial monogram (hue seeded off the repo key so
/// each project keeps a stable color). Shared by the header button; the
/// monogram math is identical to the prior inline `projectGlyph`.
struct RepoProjectGlyph: View {
    let repoKey: String
    let displayName: String
    let override: RepoIconOverride?
    let colorScheme: ColorScheme
    var size: CGFloat = 22

    var body: some View {
        let tint = Self.tint(forKey: repoKey, colorScheme: colorScheme)
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(colorScheme == .dark ? 0.28 : 0.20))
            .overlay(content(tint: tint))
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func content(tint: Color) -> some View {
        if let path = override?.imagePath, !path.isEmpty, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else if let emoji = override?.emoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: size * 0.62))
        } else {
            Text(initial)
                .font(TahoeFont.body(max(9, size * 0.45), weight: .bold))
                .foregroundStyle(tint)
        }
    }

    private var initial: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)?.uppercased() ?? "*"
    }

    static func tint(forKey key: String, colorScheme: ColorScheme) -> Color {
        let hueSeed = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let hue = Double(hueSeed % 360) / 360.0
        return Color(hue: hue, saturation: 0.52, brightness: colorScheme == .dark ? 0.86 : 0.78)
    }
}

/// Copies user-picked project images into
/// `~/Library/Application Support/Clawdmeter/repo-icons/` and cleans them up.
/// Filenames are an FNV-1a hash of the repo key so re-picking overwrites in
/// place rather than accumulating orphans.
enum RepoIconStaging {
    static func iconsDirectory() -> URL {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("Clawdmeter/repo-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func fileStem(for repoKey: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in repoKey.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(format: "%016llx", hash)
    }

    /// Copy a picked image into the icons dir, returning the destination path.
    /// Any prior icon for the same repo (regardless of extension) is removed
    /// first so a JPG→PNG swap doesn't leave a stale file behind.
    static func stageImage(from source: URL, repoKey: String) throws -> String {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let stem = fileStem(for: repoKey)
        let dir = iconsDirectory()
        if let existing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in existing where url.deletingPathExtension().lastPathComponent == stem {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("\(stem).\(ext)")
        let data = try Data(contentsOf: source)
        try data.write(to: dest, options: [.atomic])
        return dest.path
    }

    static func removeImage(at path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
