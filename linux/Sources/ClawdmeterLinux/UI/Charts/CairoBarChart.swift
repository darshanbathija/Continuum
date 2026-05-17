import Foundation
import ClawdmeterShared

/// Stacked bar chart for the daily-spend row in the dashboard.
///
/// Replaces Swift Charts (Apple-only) with Cairo on a `GtkDrawingArea`
/// (D10). ~80 LOC per the plan; the Cairo path is small because the
/// chart shape is fixed (30 days × 2 stacks = Claude + Codex).
///
/// Phase 5 build-out: real Cairo calls under `#if os(Linux)`.
public final class CairoBarChart {

    /// One day's data point.
    public struct Day: Equatable, Sendable {
        public let date: Date
        public let claudeUSD: Double
        public let codexUSD: Double
        public init(date: Date, claudeUSD: Double, codexUSD: Double) {
            self.date = date
            self.claudeUSD = claudeUSD
            self.codexUSD = codexUSD
        }
    }

    public let days: [Day]

    public init(days: [Day]) {
        self.days = days
    }

    /// Returns a `LinuxDrawingArea` widget wired to render this data set.
    public func widget() -> LinuxDrawingArea {
        let captured = days
        return LinuxUI.drawingArea { width, height, cr in
            CairoBarChart.draw(days: captured, width: width, height: height, cairoContext: cr)
        }
    }

    /// Pure draw function — pulled out so unit tests can render against
    /// a mock Cairo context, and the visual regression test can render
    /// against the real one.
    public static func draw(days: [Day], width: Int, height: Int, cairoContext: OpaquePointer) {
        #if os(Linux)
        // TODO(Phase 5): Cairo render math
        //   1. background fill (theme bg)
        //   2. iterate over `days`, compute bar height = (claudeUSD+codexUSD) / maxSpend * usableHeight
        //   3. fill bottom slice (claudeUSD) in terra-cotta #d97757
        //   4. fill top slice (codexUSD) in codex blue #5C9DFF
        //   5. PangoCairo for weekday labels every 7 bars
        //   6. axis line + dollar-axis labels
        #else
        // macOS dev: no-op. Visual tests skip on non-Linux.
        _ = (days, width, height, cairoContext)
        #endif
    }

    /// Returns the maximum daily total — useful for axis scale + tests.
    public var maxDailySpend: Double {
        days.map { $0.claudeUSD + $0.codexUSD }.max() ?? 0
    }
}
