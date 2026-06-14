#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// "Steady Tenths Stream" — the working / loading indicator for the Chat and
/// Code tabs (desktop + mobile). It replaces every spinner / pulsing-dots /
/// "Thinking…" affordance while an agent session is actively working.
///
/// Two coupled parts, laid out left → right:
///   1. **The stream** — discrete data packets riding a faint center bus,
///      fading in at the left edge and dissolving into the readout at the
///      right. This is the "life" of the indicator: it never stops while the
///      session is working. Packet sizes / positions / speeds come from a
///      seeded deterministic PRNG, so the field is stable across re-renders.
///   2. **The readout** — a live elapsed-time counter in `m, ss.s` word
///      format, tabular numerals, swapping instantly every 100 ms (no
///      odometer roll). The *stream* carries the sense of motion, not the
///      digits.
///
/// Color encodes **focus**, not activity (matching the worktree/branch-tab
/// rule elsewhere in Continuum): a background session's packets are white
/// (`monochrome: true`); the focused session's packets take the provider tint
/// (`monochrome: false`). The readout digits are always the foreground color
/// in both states.
///
/// Reduced motion: the packet animation freezes in its seeded positions while
/// the readout keeps ticking — liveness is still conveyed by the changing
/// number, which is information rather than decoration.
///
/// Canonical spec: "Steady Tenths Stream — Loading / Active-Session Indicator".
public struct SteadyTenthsStream: View {
    /// Provider tint for the packets when focused (e.g. Claude `#D97757`).
    public let color: Color
    /// Background (unfocused) session → white packets; focused → `color`.
    public let monochrome: Bool
    /// When the agent started this work. `nil` → count from first render
    /// (the indicator only mounts while working, so first render ≈ work start).
    public let startedAt: Date?
    /// Readout digit color. Defaults to `.primary` so it adapts across the
    /// Quiet Black / Quiet White themes; callers with a resolved foreground
    /// token (e.g. `t.fg`) may pass it for the exact 0.94 alpha.
    public let digitColor: Color

    // Geometry — compact by default (sized to an in-thread row). The spec's
    // 58×16 / 21px "chip" proportions scale up via the initializer.
    public let streamWidth: CGFloat
    public let streamHeight: CGFloat
    public let packetCount: Int
    public let readoutSize: CGFloat
    public let gap: CGFloat
    public let seed: UInt64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stable work-start fallback. `@State` is initialized once when the view
    /// is first created and survives re-renders, so the readout counts from
    /// the moment the indicator appeared rather than resetting on each tick.
    @State private var fallbackStart = Date()

    public init(
        color: Color,
        monochrome: Bool = false,
        startedAt: Date? = nil,
        digitColor: Color = .primary,
        streamWidth: CGFloat = 46,
        streamHeight: CGFloat = 14,
        packetCount: Int = 9,
        readoutSize: CGFloat = 13,
        gap: CGFloat = 9,
        seed: UInt64 = 9
    ) {
        self.color = color
        self.monochrome = monochrome
        self.startedAt = startedAt
        self.digitColor = digitColor
        self.streamWidth = streamWidth
        self.streamHeight = streamHeight
        self.packetCount = packetCount
        self.readoutSize = readoutSize
        self.gap = gap
        self.seed = seed
    }

    private var effectiveStart: Date { startedAt ?? fallbackStart }

    public var body: some View {
        HStack(alignment: .center, spacing: gap) {
            DataBus(
                color: monochrome ? .white : color,
                railColor: digitColor.opacity(0.075),
                minOpacity: monochrome ? 0.42 : 0.50,
                maxOpacity: 1.0,
                width: streamWidth,
                height: streamHeight,
                count: packetCount,
                seed: seed
            )
            readout
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var readout: some View {
        // The digits update 10×/s; under Reduce Motion drop to 1 Hz (the
        // changing number is still the liveness signal). No transition on the
        // text — the new value replaces the old one each tick.
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1.0 : 0.1)) { context in
            Text(formatted(elapsed(at: context.date)))
                .font(.system(size: readoutSize, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(digitColor)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func elapsed(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(effectiveStart))
    }

    /// `{m}m, {s}s` when minutes > 0, else `{s}s`; seconds always one decimal.
    /// Floors to a tenth (integer math) so the minute boundary reads
    /// `59.9s → 1m, 0.0s` with no transient `60.0s` frame.
    private func formatted(_ elapsed: TimeInterval) -> String {
        let tenths = max(0, Int((elapsed * 10).rounded(.down)))
        let minutes = tenths / 600
        let rem = tenths % 600
        let seconds = rem / 10
        let frac = rem % 10
        let secondsString = "\(seconds).\(frac)"
        return minutes > 0 ? "\(minutes)m, \(secondsString)s" : "\(secondsString)s"
    }

    private var accessibilityLabel: String {
        let total = Int(elapsed(at: Date()))
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return "Working — \(minutes) minute\(minutes == 1 ? "" : "s") \(seconds) second\(seconds == 1 ? "" : "s") elapsed"
        }
        return "Working — \(seconds) second\(seconds == 1 ? "" : "s") elapsed"
    }
}

// MARK: - The stream

/// A fixed-size region of N absolutely-positioned square packets, each riding
/// the bus on its own looped timeline. Positions are computed analytically
/// from a continuous clock so the field is always mid-flight (full the instant
/// it mounts) and never desyncs or restarts on re-render.
private struct DataBus: View {
    let color: Color
    let railColor: Color
    let minOpacity: Double
    let maxOpacity: Double
    let width: CGFloat
    let height: CGFloat
    let count: Int
    let seed: UInt64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Packet {
        let size: CGFloat
        let opacity: Double
        let duration: Double
        /// Magnitude of the (negative) animation delay → a positive phase that
        /// pre-seeds the packet mid-flight so the field looks full on mount.
        let phase: Double
        /// Vertical center as a fraction of height (16%–84%).
        let y: CGFloat
    }

    /// Deterministic packet field (seeded LCG — same constants as the web
    /// reference; the exact sequence is incidental, the distribution is what
    /// matters and stays stable across re-renders).
    private var packets: [Packet] {
        var state: UInt64 = seed == 0 ? 1 : seed
        func next() -> Double {
            state = (state &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
            return Double(state) / Double(0x7fff_ffff)
        }
        let big: CGFloat = 4.0
        let small: CGFloat = 2.3
        let speed = 1.7
        return (0..<count).map { _ in
            let isBig = next() > 0.66                       // ~34% are "big"
            let size = isBig ? big : small
            let band = isBig ? (maxOpacity - minOpacity) : (maxOpacity - minOpacity) * 0.45
            let opacity = minOpacity + band * (0.7 + next() * 0.3)
            let duration = (1.25 + next() * 1.5) * speed    // 2.1s … 4.7s per loop
            let phase = next() * 2.7 * speed                // |negative delay| pre-seed
            let y = 0.16 + next() * 0.68
            return Packet(size: size, opacity: opacity, duration: duration, phase: phase, y: y)
        }
    }

    var body: some View {
        let field = packets
        Group {
            if reduceMotion {
                // Freeze the field in its seeded positions (still reads as a
                // stream, just static) — the readout keeps conveying liveness.
                Canvas { context, size in
                    draw(context, size: size, packets: field, clock: 0)
                }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(
                            context,
                            size: size,
                            packets: field,
                            clock: timeline.date.timeIntervalSinceReferenceDate
                        )
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .mask(edgeFade)              // packets materialize left, dissolve right
        .accessibilityHidden(true)   // decorative; the container carries the label
    }

    private func draw(_ context: GraphicsContext, size: CGSize, packets: [Packet], clock: Double) {
        // The barely-visible center "bus" rail the packets ride.
        var rail = Path()
        rail.move(to: CGPoint(x: 0, y: size.height / 2))
        rail.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(rail, with: .color(railColor), lineWidth: 0.5)

        for packet in packets {
            // Each packet translates from -8 to +width, linearly, forever.
            var progress = ((clock + packet.phase) / packet.duration).truncatingRemainder(dividingBy: 1)
            if progress < 0 { progress += 1 }
            let x = -8 + (size.width + 8) * progress
            let centerY = packet.y * size.height
            let rect = CGRect(x: x, y: centerY - packet.size / 2, width: packet.size, height: packet.size)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 0.5),
                with: .color(color.opacity(packet.opacity))
            )
        }
    }

    /// `linear-gradient(90deg, transparent, opaque 16%, opaque 84%, transparent)`
    private var edgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .white, location: 0.16),
                .init(color: .white, location: 0.84),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
#endif
