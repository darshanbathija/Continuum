#if canImport(SwiftUI)
import SwiftUI

/// A brief, single-shot success flash for high-frequency actions that are too
/// cheap to deserve a toast (effort bumps, mode flips, bookmarks). When `trigger`
/// changes, a success-tinted ring + check fades in over the content and fades out
/// ~0.6s later — enough to confirm "that landed" without stealing focus.
///
/// Single-shot by construction (no `repeatForever`), so it's safe under Reduce
/// Motion; in that mode the scale is dropped and only opacity changes.
public extension View {
    func confirmationPulse<T: Equatable>(
        _ trigger: T,
        cornerRadius: CGFloat = SessionsV2Theme.Radius.chip,
        tint: Color = SessionsV2Theme.success
    ) -> some View {
        modifier(ConfirmationPulseModifier(trigger: trigger, cornerRadius: cornerRadius, tint: tint))
    }
}

private struct ConfirmationPulseModifier<T: Equatable>: ViewModifier {
    let trigger: T
    let cornerRadius: CGFloat
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashing = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if flashing {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(tint, lineWidth: 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.14))
                        )
                        .shadow(color: tint.opacity(0.45), radius: 5)
                        .transition(.opacity.combined(with: reduceMotion ? .identity : .scale(scale: 0.92)))
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: trigger) { _, _ in
                guard !flashing else { return }
                withAnimation(SessionsV2Theme.disclosureToggle(reduceMotion: reduceMotion)) {
                    flashing = true
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    withAnimation(SessionsV2Theme.disclosureToggle(reduceMotion: reduceMotion)) {
                        flashing = false
                    }
                }
            }
    }
}
#endif
