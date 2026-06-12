import Foundation

/// ccusage-style CSV export for host run-minute records (R1 1E).
public enum HostRunMinuteCSV {

    public static func export(records: [HostRunRecord]) -> String {
        var lines = [headerRow]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for record in records.sorted(by: { $0.startedAt < $1.startedAt }) {
            let stopped = record.stoppedAt.map { formatter.string(from: $0) } ?? ""
            lines.append([
                record.sessionId.uuidString,
                record.executionHostId.uuidString,
                escape(record.executionHostLabel),
                escape(record.cloudProvider ?? ""),
                formatter.string(from: record.startedAt),
                stopped,
                String(record.billableMinutes)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let headerRow =
        "session_id,execution_host_id,execution_host_label,cloud_provider,started_at,stopped_at,billable_minutes"

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
