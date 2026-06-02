import SwiftUI
import AppKit
import ClawdmeterShared

struct TahoeReviewContentShell<Content: View>: View {
    @Environment(\.tahoe) private var t
    let title: String
    let icon: String
    let padded: Bool
    let content: Content

    init(title: String, icon: String, padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.padded = padded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                TahoeIcon(icon, size: 12)
                    .foregroundStyle(t.fg3)
                Text(title)
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(t.fg3)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            TahoeHairline()
            content
                .padding(padded ? 16 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
