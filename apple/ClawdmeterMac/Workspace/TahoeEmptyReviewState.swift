import SwiftUI
import AppKit
import ClawdmeterShared

struct TahoeEmptyReviewState: View {
    @Environment(\.tahoe) private var t
    let icon: String
    let title: String
    let message: String

    init(icon: String, title: String, body: String) {
        self.icon = icon
        self.title = title
        self.message = body
    }

    var body: some View {
        VStack(spacing: 8) {
            TahoeIcon(icon, size: 22)
                .foregroundStyle(t.fg4)
            Text(title)
                .font(TahoeFont.body(13, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text(message)
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}
