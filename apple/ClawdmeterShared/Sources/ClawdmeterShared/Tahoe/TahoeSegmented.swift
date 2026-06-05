#if canImport(SwiftUI)
import SwiftUI

/// Pill segmented control (DESIGN.md "Segmented Controls"): pill track
/// (`surface-1` + hairline), active segment `white@10%` fill + a 0.5px inner
/// seam, SF Mono labels, 160ms matched-geometry slide. Used for range
/// (24h/7d/30d/90d/All), mode (Broadcast/Solo), and provider selection.
public struct TahoeSegmentedControl<T: Hashable>: View {
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
                let isSel = item == selection
                Button {
                    withAnimation(ContinuumMotion.segmented(reduceMotion: reduceMotion)) { selection = item }
                } label: {
                    HStack(spacing: 5) {
                        if let leading { leading(item) }
                        Text(label(item))
                            .font(ContinuumFont.mono(11, weight: isSel ? .semibold : .regular))
                    }
                    .foregroundStyle(isSel ? ContinuumTokens.fg : ContinuumTokens.fg2)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background {
                        if isSel {
                            Capsule(style: .continuous)
                                .fill(ContinuumTokens.white(0.10))
                                .overlay(Capsule(style: .continuous).strokeBorder(ContinuumTokens.hairline2, lineWidth: 0.5))
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background {
            Capsule(style: .continuous)
                .fill(ContinuumTokens.surface1)
                .overlay(Capsule(style: .continuous).strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5))
        }
    }
}
#endif
