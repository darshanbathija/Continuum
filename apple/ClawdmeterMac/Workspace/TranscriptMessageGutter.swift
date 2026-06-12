import SwiftUI
import ClawdmeterShared

/// Reports the scroll-content Y offset of a user prompt row so the gutter can
/// place markers at the correct height once the row has been laid out.
struct TranscriptMessagePositionKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TranscriptGutterMarker: Identifiable, Equatable {
    let id: String
    let preview: String
    /// Normalized position in the scroll content (0 = top, 1 = bottom).
    let fraction: CGFloat
}

/// Conductor-style transcript minimap on the right edge of the chat scroll
/// view. Each user prompt gets a horizontal tick; hover shows a preview of
/// the first few words, click scrolls the transcript to that message.
struct TranscriptMessageGutter: View {
    let markers: [TranscriptGutterMarker]
    let onSelect: (String) -> Void

    @State private var hoveredId: String?
    @Environment(\.tahoe) private var t

    var body: some View {
        GeometryReader { geo in
            let trackHeight = max(geo.size.height, 1)
            let trackWidth = geo.size.width

            ZStack(alignment: .topLeading) {
                gutterTrack

                ForEach(markers) { marker in
                    TranscriptGutterMarkerButton(
                        marker: marker,
                        isHovered: hoveredId == marker.id,
                        trackWidth: trackWidth,
                        y: marker.fraction * trackHeight,
                        onSelect: onSelect,
                        onHoverChange: { hovering in
                            hoveredId = hovering ? marker.id : (hoveredId == marker.id ? nil : hoveredId)
                        }
                    )
                }

                if let hoveredId,
                   let marker = markers.first(where: { $0.id == hoveredId }) {
                    TranscriptGutterHoverPreview(
                        preview: marker.preview,
                        y: min(max(marker.fraction * trackHeight, 36), trackHeight - 36)
                    )
                }
            }
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .padding(.trailing, 2)
        .animation(.easeOut(duration: 0.12), value: hoveredId)
    }

    private var gutterTrack: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.secondary.opacity(0.10))
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .padding(.leading, 4)
    }
}

private struct TranscriptGutterMarkerButton: View {
    let marker: TranscriptGutterMarker
    let isHovered: Bool
    let trackWidth: CGFloat
    let y: CGFloat
    let onSelect: (String) -> Void
    let onHoverChange: (Bool) -> Void

    @Environment(\.tahoe) private var t

    var body: some View {
        Button(action: ContinuumAnalytics.wrapButton(
                "gutter_marker_select",
                {
            onSelect(marker.id)
        
                }
            )) {
            Capsule(style: .continuous)
                .fill(isHovered ? t.fg2 : t.fg4.opacity(0.55))
                .frame(width: isHovered ? 10 : 8, height: isHovered ? 2 : 1)
        }
        .buttonStyle(.plain)
        .position(x: trackWidth / 2, y: y)
        .onHover(perform: onHoverChange)
        .accessibilityIdentifier("code.transcript.gutter.\(marker.id)")
        .accessibilityLabel(marker.preview)
        .help(marker.preview)
    }
}

private struct TranscriptGutterHoverPreview: View {
    let preview: String
    let y: CGFloat

    @Environment(\.tahoe) private var t

    var body: some View {
        Text(preview)
            .font(TahoeFont.body(11))
            .foregroundStyle(t.fg)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ContinuumTokens.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            .fixedSize(horizontal: false, vertical: true)
            .offset(x: -236, y: y - 18)
            .allowsHitTesting(false)
            .transition(.opacity)
            .zIndex(1)
    }
}

enum TranscriptGutterPreview {
    static func text(for body: String, limit: Int = 80) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    static func markers(
        turns: [TranscriptTurn],
        measuredPositions: [String: CGFloat],
        contentHeight: CGFloat
    ) -> [TranscriptGutterMarker] {
        let promptTurns = turns.enumerated().compactMap { index, turn -> (Int, TranscriptTurn)? in
            guard turn.prompt != nil else { return nil }
            return (index, turn)
        }
        guard !promptTurns.isEmpty else { return [] }

        let count = promptTurns.count
        return promptTurns.map { index, turn in
            let prompt = turn.prompt!
            let messageId = prompt.id

            let fraction: CGFloat
            if contentHeight > 1, let measuredY = measuredPositions[messageId] {
                fraction = min(max(measuredY / contentHeight, 0.02), 0.98)
            } else {
                fraction = CGFloat(index + 1) / CGFloat(count + 1)
            }

            return TranscriptGutterMarker(
                id: messageId,
                preview: text(for: prompt.body),
                fraction: fraction
            )
        }
    }
}
