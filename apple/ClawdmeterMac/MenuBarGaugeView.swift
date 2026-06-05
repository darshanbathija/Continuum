import SwiftUI
import AppKit
import ClawdmeterShared

/// Menu bar label renderer:
///
///   27% 2h 00m 20s  ✦  28% 5d 16h
///
/// MenuBarExtra under macOS Tahoe truncates anything past the first ~1 Text or
/// Image inside its label. The reliable pattern is to render the ENTIRE label
/// (text + inline burst + text) to a single NSImage via AppKit and pass that
/// to the status item directly. `MenuBarGaugeView` is a static-helper namespace
/// (kept as a `struct` rather than `enum` only because `AppDelegate` calls the
/// statics as `MenuBarGaugeView.renderLabel(...)`).
///
/// The Tahoe redesign retired the previous SwiftUI View body — every call site
/// now lives in `AppDelegate.ProviderStatusController.currentImage()`. Keep
/// this file as a renderer-only helper.
struct MenuBarGaugeView {
    // MARK: - Composite label renderer

    /// Cache key for the rendered menu-bar label. Two renders with the same
    /// key must return the SAME `NSImage` reference, otherwise SwiftUI's diff
    /// will see the label as changed, assign a new image to the underlying
    /// `NSStatusItem`, fire KVO, and re-enter `MenuBarExtraController` →
    /// `scenesDidChange` → `makeMainMenu` indefinitely (Tahoe behavior,
    /// confirmed via `sample`).
    private struct LabelKey: Hashable {
        let sessionPct: Int
        let sessionResetMins: Int
        let weeklyPct: Int
        let weeklyResetMins: Int
        let assetName: String
        let template: Bool
        let notStarted: Bool
        // Part of the key: a no-weekly provider renders a different label
        // (session-only, no phantom weekly), so it can't share a cache slot.
        let hasWeekly: Bool
    }
    nonisolated(unsafe) private static var labelCache: [LabelKey: NSImage] = [:]

    /// Render "{pct}% {compact}  [badge]  {pct}% {compact}" as one NSImage.
    ///
    /// Deterministic in its inputs: the same `(sessionPct, sessionResetMins,
    /// weeklyPct, weeklyResetMins, assetName, template)` always returns the
    /// SAME cached `NSImage`. This is load-bearing — see `LabelKey` doc.
    ///
    /// The countdown uses `usage.sessionResetMins`/`usage.weeklyResetMins`,
    /// which the poller fills in at poll time. They're stable until the next
    /// poll (60s cadence), which matches the label's minute precision.
    ///
    /// `hasWeekly` mirrors `ProviderConfig.hasWeeklyWindow`: providers without
    /// a weekly window (Gemini/Antigravity) must NOT render a weekly segment,
    /// otherwise the label shows a phantom "0% —" reading.
    static func renderLabel(for usage: UsageData, assetName: String, template: Bool, hasWeekly: Bool) -> NSImage {
        let notStarted = (usage.status == .notStarted)
        let key = LabelKey(
            sessionPct: usage.sessionPct,
            sessionResetMins: usage.sessionResetMins,
            weeklyPct: usage.weeklyPct,
            weeklyResetMins: usage.weeklyResetMins,
            assetName: assetName,
            template: template,
            notStarted: notStarted,
            hasWeekly: hasWeekly
        )
        cacheLock.lock()
        if let cached = labelCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]

        let composite = NSMutableAttributedString()

        let badgeSize: CGFloat = 18
        let badge = NSTextAttachment()
        badge.image = providerBadgeImage(
            assetName: assetName,
            size: badgeSize,
            template: template
        )
        badge.bounds = CGRect(x: 0, y: -4, width: badgeSize, height: badgeSize)

        // Providers with no weekly window (Antigravity/Cursor) still need
        // their provider badge; otherwise a lone Cursor item renders as
        // text-only and looks like the logo/toggle failed.
        if !hasWeekly {
            composite.append(NSAttributedString(attachment: badge))
            composite.append(NSAttributedString(string: "  ", attributes: textAttrs))
        }

        // Session portion. When the 5h/monthly window isn't active, show a
        // dash instead of a misleading "0% 5h" reading.
        if notStarted {
            composite.append(NSAttributedString(string: "—", attributes: textAttrs))
        } else {
            composite.append(NSAttributedString(
                string: "\(usage.sessionPct)% \(compactTime(usage.sessionResetMins))",
                attributes: textAttrs
            ))
        }

        // Weekly-cap providers use the badge as a separator between session
        // and weekly readings.
        if hasWeekly {
            composite.append(NSAttributedString(string: "  ", attributes: textAttrs))
            composite.append(NSAttributedString(attachment: badge))
            composite.append(NSAttributedString(string: "  ", attributes: textAttrs))
            composite.append(NSAttributedString(
                string: "\(usage.weeklyPct)% \(compactTime(usage.weeklyResetMins))",
                attributes: textAttrs
            ))
        }

        let image = imageFromAttributedString(composite)
        cacheLock.lock()
        labelCache[key] = image
        cacheLock.unlock()
        return image
    }

    /// Empty-state label. Cached because, like `renderLabel`, MenuBarExtra
    /// must see the same `NSImage` reference across body re-evaluations.
    static func renderEmptyLabel(assetName: String, template: Bool) -> NSImage {
        let cacheKey = "empty-\(assetName)-\(template ? "t" : "c")"
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let composite = NSMutableAttributedString()

        let badgeSize: CGFloat = 18
        let attach = NSTextAttachment()
        attach.image = providerBadgeImage(
            assetName: assetName,
            size: badgeSize,
            template: template
        )
        attach.bounds = CGRect(x: 0, y: -4, width: badgeSize, height: badgeSize)
        composite.append(NSAttributedString(attachment: attach))

        composite.append(NSAttributedString(string: "  —", attributes: attrs))
        let image = imageFromAttributedString(composite)
        cacheLock.lock()
        cache[cacheKey] = image
        cacheLock.unlock()
        return image
    }

    /// Badge + short text label for providers whose menu-bar surface is
    /// historical analytics rather than a live quota gauge.
    static func renderHistoryLabel(assetName: String, text: String, template: Bool) -> NSImage {
        let cacheKey = "history-\(assetName)-\(template ? "t" : "c")-\(text)"
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let composite = NSMutableAttributedString()
        let badgeSize: CGFloat = 18
        let attach = NSTextAttachment()
        attach.image = providerBadgeImage(assetName: assetName, size: badgeSize, template: template)
        attach.bounds = CGRect(x: 0, y: -4, width: badgeSize, height: badgeSize)
        composite.append(NSAttributedString(attachment: attach))
        composite.append(NSAttributedString(string: "  \(text)", attributes: attrs))
        let image = imageFromAttributedString(composite)
        cacheLock.lock()
        cache[cacheKey] = image
        cacheLock.unlock()
        return image
    }

    private static func imageFromAttributedString(_ attr: NSAttributedString) -> NSImage {
        let size = attr.size()
        let width = ceil(size.width) + 4
        let height: CGFloat = 22  // matches menu bar usable height; lets the 18pt burst breathe
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let y = (height - size.height) / 2
            attr.draw(at: CGPoint(x: 2, y: y))
            return true
        }
        // Status-item images must be template masks so AppKit can tint them
        // against both light and dark menu-bar/wallpaper appearances. The
        // provider attachment above may choose its own asset loading mode, but
        // the final composite is a single menu-bar glyph.
        img.isTemplate = true
        return img
    }

    // MARK: - Countdowns

    static func compactTime(_ mins: Int) -> String {
        guard mins > 0 else { return "now" }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        let m = mins % 60
        if h < 24 { return m == 0 ? "\(h)h" : "\(h)h \(m)m" }
        let d = h / 24
        let hRem = h % 24
        return hRem == 0 ? "\(d)d" : "\(d)d \(hRem)h"
    }

    // MARK: - Burst rasterizer (cached by tint)

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    /// Plain burst, used for in-text inline rendering only (no background).
    static func burstNSImage(tint: NSColor, size: CGFloat = 14) -> NSImage {
        let key = "burst-\(tint.cgColor.components ?? [])-\(size)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            Self.drawBurst(tint: tint, in: rect)
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }

    /// Per-provider logo (loaded from bundled SVG: ClaudeLogo.svg, CodexLogo.svg, …).
    ///
    /// Template-mode is opt-in: only meaningful for monochrome marks (the Claude
    /// burst is alpha-shaped). The ChatGPT/Codex logo is a colored composition
    /// of teal background + white swirl — alpha is uniformly opaque so template
    /// would flatten it to a solid square. Render Codex with original colors.
    static func providerBadgeImage(assetName: String, size: CGFloat = 18, template: Bool = false) -> NSImage {
        let key = "\(assetName)-\(size)-\(template ? "t" : "c")"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache[key] { return cached }

        guard let source = NSImage(named: assetName) else {
            let fallback = NSImage(size: NSSize(width: size, height: size))
            fallback.isTemplate = template
            cache[key] = fallback
            return fallback
        }
        // Copy so isTemplate/size tweaks don't poison the shared bundle image.
        // Audit P1 fix: `NSImage.copy()` returns `Any` and may yield a
        // non-NSImage for proxy-backed images. Fall back to mutating the
        // shared image when copy doesn't produce an NSImage — better
        // a slightly-shared instance than a crash on every menu-bar
        // refresh tick.
        let copy: NSImage = (source.copy() as? NSImage) ?? source
        copy.size = NSSize(width: size, height: size)
        copy.isTemplate = template
        cache[key] = copy
        return copy
    }

    /// Whether to render this provider's badge in monochrome template mode.
    /// All current assets are alpha-only marks designed for menu bar tinting:
    ///   - ClaudeLogo: the Anthropic burst (SVG, fill auto-tinted)
    ///   - CodexLogo: sourced from /Applications/Codex.app — codexTemplate.png
    ///     is Apple's standard "template" PNG (alpha mask, tints with menu bar)
    ///   - GeminiLogo: 4-pointed Gemini star (SVG, fill auto-tinted)
    static func isTemplateAsset(_ name: String) -> Bool {
        name == "ClaudeLogo" || name == "CodexLogo" || name == "GeminiLogo" || name == "GrokLogo"
    }

    /// Backwards-compat shim until callers migrate to `providerBadgeImage`.
    static func claudeBadgeImage(size: CGFloat = 18) -> NSImage {
        providerBadgeImage(assetName: "ClaudeLogo", size: size)
    }

    /// Shared petal drawing routine — fills `rect` with an 8-petal burst.
    private static func drawBurst(
        tint: NSColor,
        in rect: CGRect,
        petalLengthRatio: CGFloat = 0.95,
        petalWidthRatio: CGFloat = 0.18
    ) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let petalLength = radius * petalLengthRatio
        let petalHalfWidth = petalLength * petalWidthRatio

        ctx.setFillColor(tint.cgColor)
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4
            let cos_ = cos(angle)
            let sin_ = sin(angle)
            let perpCos = -sin_
            let perpSin = cos_
            let tip = CGPoint(x: center.x + cos_ * petalLength, y: center.y + sin_ * petalLength)
            let baseLeft = CGPoint(x: center.x + perpCos * petalHalfWidth, y: center.y + perpSin * petalHalfWidth)
            let baseRight = CGPoint(x: center.x - perpCos * petalHalfWidth, y: center.y - perpSin * petalHalfWidth)
            let midLeft = CGPoint(
                x: center.x + cos_ * petalLength * 0.55 + perpCos * petalHalfWidth * 0.45,
                y: center.y + sin_ * petalLength * 0.55 + perpSin * petalHalfWidth * 0.45
            )
            let midRight = CGPoint(
                x: center.x + cos_ * petalLength * 0.55 - perpCos * petalHalfWidth * 0.45,
                y: center.y + sin_ * petalLength * 0.55 - perpSin * petalHalfWidth * 0.45
            )
            let path = CGMutablePath()
            path.move(to: baseLeft)
            path.addQuadCurve(to: tip, control: midLeft)
            path.addQuadCurve(to: baseRight, control: midRight)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

}

private extension Color {
    var nsColor: NSColor { NSColor(self) }
}
