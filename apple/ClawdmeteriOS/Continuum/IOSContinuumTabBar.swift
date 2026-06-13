import SwiftUI
import ClawdmeterShared

/// Continuum Mobile thumb bar — Home / Usage / Code / Chat on `surface-2`.
public struct IOSContinuumTabBar: View {
    @Environment(\.theme) private var theme
    @Binding var tab: IOSRootView.Tab

    private let items: [IOSRootView.Tab] = [.home, .usage, .code, .chat]

    public init(tab: Binding<IOSRootView.Tab>) {
        _tab = tab
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { key in
                let active = tab == key
                Button(action: ContinuumAnalytics.wrapButton("tab_\(key.rawValue)", { tab = key })) {
                    ZStack {
                        if active {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.selection)
                                .padding(.horizontal, 2)
                        }
                        VStack(spacing: 4) {
                            tabIcon(key, active: active)
                            Text(label(for: key))
                                .font(ContinuumFont.body(10.5, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? theme.fg : theme.fg4)
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(for: key))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .frame(height: 62)
        .padding(.horizontal, 8)
        .background(theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 32, y: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5)
        }
    }

    private func label(for tab: IOSRootView.Tab) -> String {
        switch tab {
        case .home: return "Home"
        case .usage: return "Usage"
        case .code: return "Code"
        case .chat: return "Chat"
        }
    }

    @ViewBuilder
    private func tabIcon(_ tab: IOSRootView.Tab, active: Bool) -> some View {
        let c = active ? theme.fg : theme.fg4
        switch tab {
        case .home:
            HomeTabIcon(color: c).frame(width: 23, height: 23)
        case .usage:
            UsageTabIcon(color: c).frame(width: 23, height: 23)
        case .code:
            CodeTabIcon(color: c).frame(width: 23, height: 23)
        case .chat:
            ChatTabIcon(color: c).frame(width: 23, height: 23)
        }
    }
}

private struct HomeTabIcon: View {
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ opacity: Double = 1) {
                var path = Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s), cornerSize: CGSize(width: 1.6 * s, height: 1.6 * s))
                ctx.fill(path, with: .color(color.opacity(opacity)))
            }
            rect(3.5, 3.5, 7.5, 7.5)
            rect(13, 3.5, 7.5, 4.5, 0.55)
            rect(3.5, 13, 7.5, 4.5, 0.55)
            rect(13, 10, 7.5, 7.5)
        }
    }
}

private struct UsageTabIcon: View {
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
                var path = Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: 3 * s), cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s))
                ctx.fill(path, with: .color(color))
            }
            bar(3, 6, 14)
            bar(3, 11, 18)
            bar(3, 16, 9)
        }
    }
}

private struct CodeTabIcon: View {
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            var path = Path()
            path.move(to: CGPoint(x: 8 * s, y: 6 * s))
            path.addLine(to: CGPoint(x: 4 * s, y: 12 * s))
            path.addLine(to: CGPoint(x: 8 * s, y: 18 * s))
            path.move(to: CGPoint(x: 16 * s, y: 6 * s))
            path.addLine(to: CGPoint(x: 20 * s, y: 12 * s))
            path.addLine(to: CGPoint(x: 16 * s, y: 18 * s))
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct ChatTabIcon: View {
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            let rect = CGRect(x: 3 * s, y: 4 * s, width: 18 * s, height: 13 * s)
            var bubble = Path(roundedRect: rect, cornerSize: CGSize(width: 4 * s, height: 4 * s))
            bubble.move(to: CGPoint(x: 8 * s, y: 17 * s))
            bubble.addLine(to: CGPoint(x: 6 * s, y: 21 * s))
            bubble.addLine(to: CGPoint(x: 12 * s, y: 17 * s))
            ctx.fill(bubble, with: .color(color))
        }
    }
}
