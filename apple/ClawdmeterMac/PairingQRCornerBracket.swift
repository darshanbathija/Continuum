import SwiftUI

/// Four L-shaped accent brackets that frame the QR tile, mirroring the
/// iOS `IOSPairingView` spec. Each bracket is 32×32, 3px stroke, with an
/// asymmetric corner radius that bends inward toward the QR.
struct QRCornerBracketSpec: Hashable {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    let corner: Corner
}

struct PairingQRCornerBracket: View {
    let spec: QRCornerBracketSpec
    let color: Color

    var body: some View {
        let s: CGFloat = 32
        let stroke: CGFloat = 3
        let r: CGFloat = 10
        Path { p in
            switch spec.corner {
            case .topLeft:
                p.move(to: CGPoint(x: s, y: 0))
                p.addLine(to: CGPoint(x: r, y: 0))
                p.addArc(center: CGPoint(x: r, y: r), radius: r,
                         startAngle: .degrees(-90), endAngle: .degrees(180),
                         clockwise: true)
                p.addLine(to: CGPoint(x: 0, y: s))
            case .topRight:
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: s - r, y: 0))
                p.addArc(center: CGPoint(x: s - r, y: r), radius: r,
                         startAngle: .degrees(-90), endAngle: .degrees(0),
                         clockwise: false)
                p.addLine(to: CGPoint(x: s, y: s))
            case .bottomLeft:
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: s - r))
                p.addArc(center: CGPoint(x: r, y: s - r), radius: r,
                         startAngle: .degrees(180), endAngle: .degrees(90),
                         clockwise: true)
                p.addLine(to: CGPoint(x: s, y: s))
            case .bottomRight:
                p.move(to: CGPoint(x: s, y: 0))
                p.addLine(to: CGPoint(x: s, y: s - r))
                p.addArc(center: CGPoint(x: s - r, y: s - r), radius: r,
                         startAngle: .degrees(0), endAngle: .degrees(90),
                         clockwise: false)
                p.addLine(to: CGPoint(x: 0, y: s))
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
        .frame(width: s, height: s)
        .shadow(color: color.opacity(0.5), radius: 5)
        .offset(offset(for: spec.corner))
        .accessibilityHidden(true)
    }

    private func offset(for corner: QRCornerBracketSpec.Corner) -> CGSize {
        let inset: CGFloat = 280 / 2 - 16 + 6  // tile half - bracket half + 6 outward
        switch corner {
        case .topLeft:     return CGSize(width: -inset, height: -inset)
        case .topRight:    return CGSize(width: inset,  height: -inset)
        case .bottomLeft:  return CGSize(width: -inset, height: inset)
        case .bottomRight: return CGSize(width: inset,  height: inset)
        }
    }
}
