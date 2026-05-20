#if canImport(SwiftUI)
import SwiftUI

/// v0.5.5 chat row for an `Edit` / `MultiEdit` / `Write` tool call.
///
/// Replaces the generic "Ran 1 command" grouping for file-edit tool
/// uses — matches Claude Code's own CLI rendering: `Edited <basename>
/// +N -M ›`. For `Write` we render `Wrote <basename> +N` (no `-M` part,
/// since the prior content isn't known at parse time so deletions are
/// always reported as zero).
///
/// Tap → toggles a disclosure that surfaces the full file path and the
/// matched tool_result body. Deeper diff rendering (per-hunk context)
/// would need a richer parse pipeline; out of scope for v1.
public struct EditDiffRow: View {
    /// Structured summary parsed at ingest time from the tool_use input.
    public let stats: EditStats
    /// Companion result (if it's already landed) — its body becomes the
    /// inline "result" view when the row is expanded. May be nil while
    /// the agent is still applying the edit.
    public let resultBody: String?

    @State private var isExpanded: Bool = false

    public init(stats: EditStats, resultBody: String?) {
        self.stats = stats
        self.resultBody = resultBody
    }

    public var body: some View {
        #if os(watchOS)
        // watchOS has no DisclosureGroup; the chat thread doesn't render
        // on Watch today, so a compact summary line is enough here as a
        // future-proof placeholder if a Watch chat tab ever lands.
        HStack(spacing: 6) {
            Image(systemName: verbIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(verb) \(stats.basename)")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if stats.additions > 0 {
                Text("+\(stats.additions)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(additionsColor)
            }
            if stats.deletions > 0 {
                Text("-\(stats.deletions)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(deletionsColor)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        #else
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(stats.filePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let resultBody, !resultBody.isEmpty {
                    Text(resultBody)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(8)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: verbIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text("\(verb) \(stats.basename)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if stats.additions > 0 {
                    Text("+\(stats.additions)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(additionsColor)
                        .monospacedDigit()
                }
                if stats.deletions > 0 {
                    Text("-\(stats.deletions)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(deletionsColor)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        #endif
    }

    private var verb: String {
        switch stats.kind {
        case .edit, .multiEdit: return "Edited"
        case .write:            return "Wrote"
        }
    }

    private var verbIcon: String {
        switch stats.kind {
        case .edit:      return "pencil"
        case .multiEdit: return "pencil.and.scribble"
        case .write:     return "square.and.pencil"
        }
    }

    private var additionsColor: Color {
        // Matches the green/red Claude Code's CLI uses for unified diffs.
        Color(red: 0x52 / 255.0, green: 0xC4 / 255.0, blue: 0x1A / 255.0)
    }

    private var deletionsColor: Color {
        Color(red: 0xE6 / 255.0, green: 0x4B / 255.0, blue: 0x4B / 255.0)
    }
}
#endif
