#if canImport(SwiftUI)
import SwiftUI

/// Pill segmented control (DESIGN.md "Segmented Controls"): pill track
/// (`surface-1` + hairline), active segment fill + a 0.5px inner seam, SF Mono
/// labels, 160ms matched-geometry slide. Used for range (24h/7d/30d/90d/All),
/// mode (Broadcast/Solo), and provider selection.
public struct TahoeSegmentedControl<T: Hashable>: View {
    @Environment(\.theme) private var t
    public var items: [T]
    public var label: (T) -> String
    @Binding public var selection: T
    public var leading: ((T) -> AnyView)?

    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ items: [T], selection: Binding<T>, label: @escaping (T) -> String, leading: ((T) -> AnyView)? = nil) {
        self.items = items
        self._selection = selection
        self.label = label
        self.leading = leading
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                segmentButton(for: item)
            }
        }
        .padding(2)
        .background {
            Capsule(style: .continuous)
                .fill(t.surface1)
                .overlay(Capsule(style: .continuous).strokeBorder(t.hairline, lineWidth: 0.5))
        }
    }

    private func segmentButton(for item: T) -> some View {
        let isSel = item == selection
        return Button(action: ContinuumAnalytics.wrapButton("segment_\(label(item).lowercased().replacingOccurrences(of: " ", with: "_"))", {
            withAnimation(ContinuumMotion.segmented(reduceMotion: reduceMotion)) { selection = item }
        })) {
            segmentLabel(for: item, selected: isSel)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func segmentLabel(for item: T, selected isSel: Bool) -> some View {
        HStack(spacing: 5) {
            if let leading { leading(item) }
            Text(label(item))
                .font(ContinuumFont.mono(11, weight: isSel ? .semibold : .regular))
        }
        .foregroundStyle(isSel ? t.fg : t.fg2)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background {
            if isSel {
                Capsule(style: .continuous)
                    .fill(t.segmentActiveFill)
                    .overlay(Capsule(style: .continuous).strokeBorder(t.hair2, lineWidth: 0.5))
                    .matchedGeometryEffect(id: "seg", in: ns)
            }
        }
        .contentShape(Capsule())
    }
}
#endif
