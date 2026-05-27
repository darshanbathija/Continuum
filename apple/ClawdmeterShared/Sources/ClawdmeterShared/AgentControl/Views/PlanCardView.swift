#if canImport(SwiftUI)
import SwiftUI

/// Cross-platform "Plan ready" card. Renders the structured plan text + a
/// list of file-diff cards (per P2 decision: collapsed file cards with
/// tap-to-expand). The Approve button is bottom-anchored.
///
/// Visual spec from /plan-design-review:
/// - Header: terra-cotta (#d97757) 12% tint background, 1pt terra-cotta border,
///   Tiempos-Text-style 17pt for "Plan ready"
/// - File diff cards: bg.secondary, SF Mono 13pt filename, +N/-N stats,
///   8pt corner radius. Tap to expand inline (unified diff).
/// - Approve button: full-width-minus-16pt, terra-cotta fill, white text,
///   17pt semibold, 8pt corner radius, 14pt vertical padding.
public struct PlanCardView: View {

    public struct PlanFile: Identifiable, Hashable, Sendable {
        public let id: String  // filename serves as id
        public let filename: String
        public let addedLines: Int
        public let removedLines: Int
        /// Unified-diff body (string, includes +/- markers per line).
        public let diff: String

        public init(filename: String, addedLines: Int, removedLines: Int, diff: String) {
            self.id = filename
            self.filename = filename
            self.addedLines = addedLines
            self.removedLines = removedLines
            self.diff = diff
        }
    }

    public let goal: String?
    public let planSummary: String
    public let files: [PlanFile]
    public let onApprove: () -> Void
    public let onReject: (() -> Void)?

    @State private var expandedFiles: Set<String> = []

    public init(
        goal: String?,
        planSummary: String,
        files: [PlanFile],
        onApprove: @escaping () -> Void,
        onReject: (() -> Void)? = nil
    ) {
        self.goal = goal
        self.planSummary = planSummary
        self.files = files
        self.onApprove = onApprove
        self.onReject = onReject
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !planSummary.isEmpty {
                Text(planSummary)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(files) { file in
                    fileCard(file)
                }
            }

            HStack(spacing: 12) {
                if let onReject {
                    Button("Reject", action: onReject)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Spacer()
                Button(action: onApprove) {
                    Text("Approve & run")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(terraCotta)
                .controlSize(.large)
            }
        }
        .padding(16)
        #if os(iOS)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        #else
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        #endif
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(terraCotta.opacity(0.4), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(terraCotta)
                .frame(width: 8, height: 8)
            Text("Plan ready")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
            Spacer()
            if let goal {
                Text(goal)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func fileCard(_ file: PlanFile) -> some View {
        let isExpanded = expandedFiles.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if isExpanded { expandedFiles.remove(file.id) } else { expandedFiles.insert(file.id) }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(file.filename)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Text("+\(file.addedLines)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green)
                    Text("-\(file.removedLines)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.red)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(file.diff)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(12)
                }
                .frame(maxHeight: 240)
            }
        }
        #if os(iOS)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        #else
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
        #endif
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}
#endif
