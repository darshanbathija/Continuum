import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Usage tab section: run time by execution host (R1 1E).
public struct HostRunMinutesSection: View {
    public let response: HostRunMinutesResponse
    public let hostNames: [UUID: String]

    public init(response: HostRunMinutesResponse, hostNames: [UUID: String]) {
        self.response = response
        self.hostNames = hostNames
    }

    private var maxMinutes: Int {
        max(response.hosts.map(\.billableMinutes).max() ?? 1, 1)
    }

    public var body: some View {
        if !response.hosts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Run time by device")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    #if os(macOS)
                    if !response.records.isEmpty {
                        Button("Export CSV") {
                            exportCSV()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                    }
                    #endif
                }
                ForEach(response.hosts.sorted(by: { $0.billableMinutes > $1.billableMinutes })) { summary in
                    hostRow(summary)
                }
            }
        }
    }

    #if os(macOS)
    private func exportCSV() {
        let csv = HostRunMinuteCSV.export(records: response.records)
        let panel = NSSavePanel()
        panel.title = "Export host run minutes"
        panel.nameFieldStringValue = "clawdmeter-host-run-minutes.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    private func hostRow(_ summary: HostRunMinuteSummary) -> some View {
        let label = hostNames[summary.executionHostId] ?? summary.executionHostLabel
        let fraction = Double(summary.billableMinutes) / Double(maxMinutes)
        return HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(4, geo.size.width * fraction))
            }
            .frame(height: 8)
            Text("\(summary.billableMinutes)m")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            if summary.activeSessionCount > 0 {
                Text("\(summary.activeSessionCount) live")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
    }
}
