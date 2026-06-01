#if canImport(SwiftUI)
import SwiftUI

/// A shimmering placeholder block for loading states. Replaces the bare
/// "Loading…" text / lone `ProgressView` that made panes look *stalled*
/// rather than *filling in* — the audit flagged this across Diff / Sources /
/// PR / Artifacts / Terminal.
///
/// The left→right sweep runs at the DESIGN.md spinner cadence (0.9s). Under
/// Reduce Motion the sweep is dropped and a static muted block remains, so the
/// shape still communicates "content loading here" without animation.
public struct SkeletonBlock: View {
    public var width: CGFloat?
    public var height: CGFloat
    public var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    public init(width: CGFloat? = nil, height: CGFloat = 12,
                cornerRadius: CGFloat = SessionsV2Theme.Radius.chip) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let w = geo.size.width
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.16), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: max(w * 0.5, 40))
                        .offset(x: animate ? w : -w)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: SessionsV2Theme.AnimationDuration.spinner)
                    .repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}

/// A few stacked skeleton lines — the common "this pane is loading" placeholder.
/// Last line is shorter to read as a paragraph tail.
public struct SkeletonLines: View {
    public var count: Int
    public var label: String?
    public init(count: Int = 3, label: String? = nil) {
        self.count = count
        self.label = label
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<max(count, 1), id: \.self) { i in
                SkeletonBlock(width: i == count - 1 ? 140 : nil, height: 11)
            }
            if let label {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(label ?? "Loading")
    }
}
#endif
