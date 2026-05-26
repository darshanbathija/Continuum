// Renders an isolated proof PNG of the new "progress vs approved plan"
// sidebar bar. Runs as: `swift run -c release` from a tiny SwiftPM
// package OR directly via `swift .context/verification/render_bar_proof.swift`
// since the only deps are SwiftUI + AppKit.
//
// Faithfully replicates the SessionWorkspaceView.sessionRow construct
// the diff lands. Pixel match against the running Mac binary should be
// nearly exact since both use the same SwiftUI primitives.

import SwiftUI
import AppKit

// Tahoe theme tokens used by the production row, hard-coded here so we
// don't drag in the Tahoe module (the bar uses `t.accent` and `t.fg3`).
private extension Color {
    // Claude provider color slots — production picks these from
    // `TahoeProvider.halo / .glow / .deep` per `session.agent`. The
    // proof uses Claude's pair (orange family).
    static let tahoeHalo   = Color(.sRGB, red: 0xFF / 255.0,
                                          green: 0x8B / 255.0,
                                          blue:  0x4F / 255.0, opacity: 1)
    static let tahoeGlow   = Color(.sRGB, red: 0xD9 / 255.0,
                                          green: 0x57 / 255.0,
                                          blue:  0x34 / 255.0, opacity: 1)
    /// TahoeProvider.deep for .claude → OKLCH(l: 0.48, c: 0.14, h: 35).
    /// Approximated to sRGB for the proof.
    static let tahoeDeep   = Color(.sRGB, red: 0xA0 / 255.0,
                                          green: 0x4F / 255.0,
                                          blue:  0x28 / 255.0, opacity: 1)
    /// Bumped from fg3 → fg2 per WCAG contrast (4.5:1 body text).
    static let tahoeFG2    = Color(.sRGB, red: 0.36, green: 0.36, blue: 0.36, opacity: 1)
    static let tahoeFG3    = Color(.sRGB, red: 0.55, green: 0.55, blue: 0.55, opacity: 1)
    static let tahoeFG     = Color(.sRGB, red: 0.15, green: 0.15, blue: 0.15, opacity: 1)
    static let rowBG       = Color(.sRGB, red: 0.97, green: 0.96, blue: 0.94, opacity: 1)
}

private struct Row: View {
    let title: String
    let subtitle: String
    let completed: Int
    let total: Int
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Status dot (faked since we don't import the provider glyph).
            Circle()
                .fill(Color.tahoeGlow)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.tahoeFG)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.tahoeFG3)
                }
                // The bar — proof replica of `TahoePillBar(percent:provider:height:)`.
                // Production code in `SessionWorkspaceView.sessionRow`
                // uses the real TahoePillBar; this proof reproduces its
                // visual shape (capsule background + halo gradient capsule
                // fill + 5pt halo shadow) without dragging in the module.
                let isComplete = completed >= total && total > 0
                HStack(spacing: 6) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color(.sRGB, white: 15.0 / 255.0, opacity: 0.08))
                            Capsule(style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color.tahoeHalo, Color.tahoeGlow],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(proxy.size.width * CGFloat(fraction),
                                                  fraction > 0 ? 6 : 0))
                                .shadow(color: Color.tahoeHalo.opacity(0.45), radius: 5)
                        }
                    }
                    .frame(height: 6)
                    .frame(maxWidth: .infinity)
                    if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.tahoeHalo)
                            .padding(.leading, 2)
                    }
                    Text("\(completed)/\(total)")
                        .font(.system(size: 10.5,
                                       weight: isComplete ? .bold : .semibold).monospacedDigit())
                        .foregroundStyle(isComplete ? Color.tahoeHalo : Color.tahoeFG2)
                        .frame(minWidth: 44, alignment: .trailing)
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 280)
        .background(Color.rowBG)
    }
}

private struct Strip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row(title: "Refactor settlement dedupe", subtitle: "running · 2m ago",
                completed: 3, total: 8)
            Divider()
            Row(title: "Wire WS reconnect backoff", subtitle: "running · 14s ago",
                completed: 6, total: 6)
            Divider()
            Row(title: "Tahoe-style redesign pass", subtitle: "running · 1m ago",
                completed: 0, total: 5)
        }
        .frame(width: 280)
    }
}

@MainActor
func renderPNG(to url: URL) {
    let renderer = ImageRenderer(content: Strip())
    renderer.scale = 2.0
    guard let cg = renderer.cgImage else {
        FileHandle.standardError.write("ImageRenderer produced no cgImage.\n".data(using: .utf8)!)
        exit(2)
    }
    let bitmap = NSBitmapImageRep(cgImage: cg)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Could not encode PNG.\n".data(using: .utf8)!)
        exit(3)
    }
    try? png.write(to: url)
    FileHandle.standardOutput.write("OK \(url.path)\n".data(using: .utf8)!)
}

let outURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                  ?? "plan-progress-bar-mac-final.png")
DispatchQueue.main.async {
    renderPNG(to: outURL)
    exit(0)
}
RunLoop.main.run()
