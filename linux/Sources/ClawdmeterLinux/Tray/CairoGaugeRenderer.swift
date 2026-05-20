import Foundation
import ClawdmeterShared

/// Renders the live menu-bar gauge to a 32×32 PNG that AppIndicator can
/// display. Port of [apple/ClawdmeterMac/MenuBarGaugeView.swift] render
/// math (arc + percentage text + provider color).
///
/// **Why an on-disk PNG and not in-band pixel data?** AppIndicator only
/// takes an icon NAME (theme lookup) or a file PATH. SNI does support
/// in-band pixmaps over D-Bus but that's ~1.5 weeks of marshalling code
/// for zero user benefit. Atomic write + rename at 60s cadence on tmpfs
/// is sub-millisecond.
///
/// **Pitfall fix.** The PNG path must change on every refresh
/// (`gauge-{provider}-<seq>.png`) — AppIndicator caches by path and
/// will skip reload if the path didn't change.
///
/// Phase 4 build-out: actual Cairo calls under `#if os(Linux)`. The
/// `#else` branch returns the empty Data so dev builds on macOS work.
public final class CairoGaugeRenderer: @unchecked Sendable {
    public enum Provider: String, Sendable {
        case claude
        case codex
    }

    /// Monotonic counter — drives the `<seq>` in the output filename so
    /// AppIndicator's icon cache doesn't skip the reload.
    private static let counter = Counter()
    private actor Counter {
        private var n: UInt64 = 0
        func next() -> UInt64 {
            n &+= 1
            return n
        }
    }

    public init() {}

    /// Render a 32×32 PNG for the given provider + usage data; write
    /// atomically to `$XDG_RUNTIME_DIR/clawdmeter/gauge/<provider>-<seq>.png`.
    /// Returns the new file path. Caller passes the path to
    /// `app_indicator_set_icon_full`.
    public func renderAndWrite(provider: Provider, usage: UsageData) async throws -> URL {
        let seq = await Self.counter.next()
        try LinuxConfigPaths.ensureDirectory(LinuxConfigPaths.gaugePNGDir)
        let filename = "\(provider.rawValue)-\(seq).png"
        let url = LinuxConfigPaths.gaugePNGDir.appendingPathComponent(filename)
        let bytes = renderPNG(provider: provider, usage: usage)
        // P0-2: avoid FileManager.replaceItem on Linux — Swift Corelibs
        // Foundation throws when the destination doesn't exist yet, which
        // is exactly the first-run state for the gauge directory. `Data.write`
        // with `.atomic` writes to a sibling temp and renames into place on
        // both Darwin and Linux, and handles the missing-destination case.
        try bytes.write(to: url, options: .atomic)
        // Prune previous gauge files (older than 60s) so tmpfs doesn't fill.
        pruneOldFiles(for: provider, keeping: url)
        return url
    }

    /// 32×32 RGBA PNG bytes. Phase 4 wires the actual Cairo calls.
    private func renderPNG(provider: Provider, usage: UsageData) -> Data {
        #if os(Linux)
        // TODO(Phase 4): Cairo render path
        //   let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 32, 32)
        //   let cr = cairo_create(surface)
        //   // background transparent; foreground arc (Claude terra-cotta #d97757
        //   // or Codex slate blue #5C9DFF); text label "Cl 42%" / "Cx 17%"
        //   ...
        //   cairo_surface_write_to_png(surface, ...)  → temp PNG, slurp bytes
        return Data()
        #else
        // macOS dev: write a placeholder 32x32 PNG header so the rename
        // pipeline still works for unit tests.
        return placeholderPNG()
        #endif
    }

    /// Tiny valid 32×32 PNG (transparent). Used only in dev builds when
    /// Cairo isn't available, so visual tests can still assert atomic-rename.
    private func placeholderPNG() -> Data {
        // Hand-rolled 1×1 transparent PNG. Not 32×32; placeholder only.
        // Visual regression tests on Linux replace this with the real
        // Cairo output via golden-image diff.
        return Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  // PNG sig
            0x00, 0x00, 0x00, 0x0D,                          // IHDR len
            0x49, 0x48, 0x44, 0x52,                          // IHDR
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  // 1x1
            0x08, 0x06, 0x00, 0x00, 0x00,                    // RGBA
            0x1F, 0x15, 0xC4, 0x89,                          // CRC
            0x00, 0x00, 0x00, 0x0D,                          // IDAT len
            0x49, 0x44, 0x41, 0x54,                          // IDAT
            0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05,
            0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,              // payload + CRC
            0x00, 0x00, 0x00, 0x00,                          // IEND len
            0x49, 0x45, 0x4E, 0x44,                          // IEND
            0xAE, 0x42, 0x60, 0x82                           // CRC
        ])
    }

    /// Remove gauge files older than 60s for this provider (except the
    /// freshly-written one). Keeps tmpfs bounded.
    private func pruneOldFiles(for provider: Provider, keeping current: URL) {
        let dir = LinuxConfigPaths.gaugePNGDir
        let prefix = "\(provider.rawValue)-"
        let cutoff = Date().addingTimeInterval(-60)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries {
            guard url.lastPathComponent.hasPrefix(prefix), url != current else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if mtime < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
