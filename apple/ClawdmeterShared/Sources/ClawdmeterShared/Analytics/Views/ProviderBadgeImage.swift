#if !os(watchOS)
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Small SwiftUI badge that loads a provider logo (`ClaudeLogo` or
/// `CodexLogo`) from the host app's bundle. Lives in ClawdmeterShared
/// so analytics views (`AnalyticsTotalsGrid`, `AnalyticsDailyChart`'s
/// custom legend) can show the same icons the iOS Live tab + Mac
/// dashboard use.
///
/// Why a custom view instead of `Image(_ name:)` directly:
/// - iOS ships logos in `Assets.xcassets`; Mac ships them as PNGs/SVGs
///   under `Resources/`. SwiftUI's `Image(_ name:)` finds both via
///   `Bundle.main`, but it can't apply `.isTemplate` to NSImages, which
///   is required for the Codex silhouette to render correctly on dark
///   backgrounds (without it, the black-on-transparent glyph
///   disappears).
/// - Falls back to a colored rounded rectangle so the layout doesn't
///   collapse if an asset is missing.
@available(macOS 13, iOS 16, *)
public struct ProviderBadgeImage: View {
    public let assetName: String
    public let isTemplate: Bool
    public let size: CGFloat

    public init(assetName: String, isTemplate: Bool, size: CGFloat) {
        self.assetName = assetName
        self.isTemplate = isTemplate
        self.size = size
    }

    public var body: some View {
#if canImport(AppKit)
        if let nsImage = NSImage(named: assetName) {
            let resolved: NSImage = {
                if isTemplate, let copy = nsImage.copy() as? NSImage {
                    copy.isTemplate = true
                    return copy
                }
                return nsImage
            }()
            Image(nsImage: resolved)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
        } else {
            placeholder
        }
#elseif canImport(UIKit)
        if let uiImage = UIImage(named: assetName) {
            let rendered = isTemplate
                ? uiImage.withRenderingMode(.alwaysTemplate)
                : uiImage
            Image(uiImage: rendered)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
        } else {
            placeholder
        }
#else
        placeholder
#endif
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.secondary.opacity(0.2))
            .frame(width: size, height: size)
    }
}
#endif
