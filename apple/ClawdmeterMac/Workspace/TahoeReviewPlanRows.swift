import SwiftUI
import AppKit
import ClawdmeterShared

struct TahoeReviewPlanRows: View {
    @Environment(\.tahoe) private var t
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(index == 0 ? t.accentAlpha(0.18) : t.hair2)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Text("\(index + 1)")
                                .font(TahoeFont.mono(11, weight: .bold))
                                .foregroundStyle(index == 0 ? t.accent : t.fg2)
                        )
                    Text(step)
                        .font(TahoeFont.body(12.5))
                        .foregroundStyle(t.fg)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
                if index < steps.count - 1 {
                    TahoeHairline()
                }
            }
        }
    }
}
