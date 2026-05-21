#if canImport(SwiftUI)
import SwiftUI

/// iOS-native toggle geometry hand-built to match JSX `Toggle` from
/// `mac-dashboard.jsx`. Track 34×22, thumb 18×18, 2px padding all sides,
/// 12px horizontal travel. The chat history explicitly fixed this geometry
/// in chat3 ("AI-slop toggle") — keep it pixel-perfect.
public struct TahoeToggleView: View {
    @Environment(\.tahoe) private var t
    @Binding public var on: Bool

    public init(on: Binding<Bool>) { self._on = on }

    public var body: some View {
        let trackColor = on ? Color(.sRGB, red: 40.0/255, green: 200.0/255, blue: 64.0/255) : t.hair2
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(trackColor)
            Circle()
                .fill(Color.white)
                .frame(width: 18, height: 18)
                .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 1)
                .padding(2)
        }
        .frame(width: 34, height: 22)
        .animation(.easeOut(duration: 0.15), value: on)
        .contentShape(Capsule())
        .onTapGesture { on.toggle() }
    }
}

/// Non-interactive variant for chrome that just *displays* state.
public struct TahoeToggleDisplay: View {
    @Environment(\.tahoe) private var t
    public var on: Bool

    public init(on: Bool) { self.on = on }

    public var body: some View {
        let trackColor = on ? Color(.sRGB, red: 40.0/255, green: 200.0/255, blue: 64.0/255) : t.hair2
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule(style: .continuous).fill(trackColor)
            Circle()
                .fill(Color.white)
                .frame(width: 18, height: 18)
                .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 1)
                .padding(2)
        }
        .frame(width: 34, height: 22)
    }
}
#endif
