import SwiftUI
import AppKit
import ClawdmeterShared

/// Draggable vertical divider between workspace panes. Click and drag to
/// resize the adjacent pane; the hit target is wider than the visible
/// hairline so grabbing the edge feels natural.
struct WorkbenchPaneResizeHandle: View {
    let getWidth: () -> CGFloat
    let setWidth: (CGFloat) -> Void
    let minWidth: CGFloat
    let maxWidth: CGFloat
    /// When `true`, dragging left widens the pane (handle sits on the pane's
    /// leading edge, e.g. the review column).
    var invertDrag: Bool = false
    /// Fired once when the drag finishes. Lets the caller fold the live
    /// drag-local width back into persisted state with a single write
    /// (the per-tick `setWidth` path stays disk- and observable-free).
    var onCommit: (() -> Void)? = nil
    var accessibilityIdentifier: String?

    @State private var widthAtDragStart: CGFloat?
    @State private var isDragging = false
    @Environment(\.tahoe) private var t

    var body: some View {
        ZStack {
            TahoeHairline(vertical: true)
            Rectangle()
                .fill(isDragging ? t.fg3.opacity(0.18) : Color.clear)
        }
        .frame(width: 5)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else if !isDragging {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if widthAtDragStart == nil {
                        widthAtDragStart = getWidth()
                        isDragging = true
                    }
                    let delta = invertDrag ? -value.translation.width : value.translation.width
                    let proposed = (widthAtDragStart ?? getWidth()) + delta
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        setWidth(clamped(proposed))
                    }
                }
                .onEnded { _ in
                    widthAtDragStart = nil
                    isDragging = false
                    NSCursor.pop()
                    onCommit?()
                }
        )
        .accessibilityIdentifier(accessibilityIdentifier ?? "code.workspace.resize-handle")
    }

    private func clamped(_ width: CGFloat) -> CGFloat {
        min(maxWidth, max(minWidth, width))
    }
}
