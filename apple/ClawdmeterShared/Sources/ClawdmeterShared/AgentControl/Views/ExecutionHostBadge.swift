import SwiftUI

/// Session row pill showing which device is running the session (R1 1C).
public struct ExecutionHostBadge: View {
    public let label: String

    public init(label: String) {
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 8, weight: .semibold))
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.12), in: Capsule(style: .continuous))
        .accessibilityLabel("Running on \(label)")
    }
}
