import SwiftUI
import ClawdmeterShared

/// `@`-triggered popover. Scope-cut per Codex P1 finding:
/// shows (a) supported provisioning vendors (env/credential sharing),
/// (b) other open sessions, (c) files the agent has already cited
/// in this session (`SourceEntry`s).
/// A full repo-file walker is deferred to a follow-up TODO.
struct MentionPicker: View {

    let openSessions: [AgentSession]
    let sourceEntries: [SourceEntry]
    let vendorStatuses: [String: VendorProvisioningStatus]
    @Binding var query: String
    let onSelect: (Suggestion) -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex: Int = 0

    enum Suggestion: Identifiable, Hashable {
        case vendor(VendorProvisioningVendor)
        case session(AgentSession)
        case file(path: String, label: String)

        var id: String {
            switch self {
            case .vendor(let v): return "v:\(v.id)"
            case .session(let s): return "s:\(s.id.uuidString)"
            case .file(let path, _): return "f:\(path)"
            }
        }
        var label: String {
            switch self {
            case .vendor(let v): return v.displayName
            case .session(let s): return s.goal ?? s.repoDisplayName
            case .file(_, let label): return label
            }
        }
        var sublabel: String {
            switch self {
            case .vendor(let v):
                return "@\(v.displayName)"
            case .session(let s): return "\(s.agent.rawValue.capitalized) · session"
            case .file(let path, _): return path
            }
        }
        var icon: String {
            switch self {
            case .vendor(let v): return VendorMentionSupport.iconName(for: v)
            case .session: return "bubble.left.and.bubble.right"
            case .file: return "doc"
            }
        }
    }

    var filtered: [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var all: [Suggestion] = []
        all.append(contentsOf: VendorProvisioningCatalog.vendors(matchingMentionQuery: q).map { .vendor($0) })
        all.append(contentsOf: openSessions.map { .session($0) })
        all.append(contentsOf: sourceEntries.map { .file(path: $0.payload, label: $0.label) })
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.label.lowercased().contains(q) || $0.sublabel.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "at")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Mention")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filtered.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if filtered.isEmpty {
                Text("No matches in vendors, open sessions, or agent-cited files.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { (idx, item) in
                            row(item, isSelected: idx == selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { onSelect(item) }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 460)
        .background(ContinuumTokens.surface3, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .background(KeyMonitor(
            up: { selectedIndex = max(0, selectedIndex - 1) },
            down: { selectedIndex = min(max(0, filtered.count - 1), selectedIndex + 1) },
            enter: { if let pick = pickerAt(selectedIndex) { onSelect(pick) } },
            escape: onDismiss
        ))
    }

    private func pickerAt(_ idx: Int) -> Suggestion? {
        guard idx >= 0, idx < filtered.count else { return nil }
        return filtered[idx]
    }

    @ViewBuilder
    private func row(_ item: Suggestion, isSelected: Bool) -> some View {
        switch item {
        case .vendor(let vendor):
            vendorRow(vendor, isSelected: isSelected)
        default:
            defaultRow(item, isSelected: isSelected)
        }
    }

    @ViewBuilder
    private func vendorRow(_ vendor: VendorProvisioningVendor, isSelected: Bool) -> some View {
        let status = vendorStatuses[vendor.id]
        let connected = status?.isMentionConnected == true
        let accent = connected ? Color.green : Color.orange
        HStack(spacing: 8) {
            Image(systemName: VendorMentionSupport.iconName(for: vendor))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 16)
            Text("@\(vendor.displayName)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent.opacity(0.95))
            Text("·")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent.opacity(0.55))
            Text(status?.mentionConnectionLabel ?? "not connected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent.opacity(0.75))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected ? accent.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(accent.opacity(0.45), lineWidth: 0.8)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityIdentifier("composer.mention.vendor.\(vendor.id)")
    }

    @ViewBuilder
    private func defaultRow(_ item: Suggestion, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: item.icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.sublabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .padding(.horizontal, 4)
    }
}

enum VendorMentionSupport {
    static func iconName(for vendor: VendorProvisioningVendor) -> String {
        switch vendor.category {
        case .storageDatabase: return "cylinder.split.1x2"
        case .computeHosting: return "terminal"
        case .domains: return "cloud"
        }
    }

    /// Parses a trailing `@<word>` token when `@` begins a whitespace-delimited token.
    static func trailingMentionQuery(in text: String) -> String? {
        guard let atRange = text.range(of: "@", options: .backwards),
              atRange.lowerBound == text.startIndex
                  || text[text.index(before: atRange.lowerBound)].isWhitespace
        else { return nil }
        let afterAt = String(text[atRange.upperBound...])
        guard !afterAt.contains(" "), !afterAt.contains("\n") else { return nil }
        return afterAt
    }
}

/// Floating preview chip shown above the composer text while typing `@Cloudflare`.
struct VendorMentionPreviewChip: View {
    let vendor: VendorProvisioningVendor
    let status: VendorProvisioningStatus?

    var body: some View {
        let connected = status?.isMentionConnected == true
        let accent = connected ? Color.green : Color.orange
        HStack(spacing: 6) {
            Image(systemName: VendorMentionSupport.iconName(for: vendor))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text("@\(vendor.displayName)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent.opacity(0.95))
            Text("·")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent.opacity(0.55))
            Text(status?.mentionConnectionLabel ?? "not connected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(accent.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(accent.opacity(0.42), lineWidth: 0.8))
        .accessibilityIdentifier("composer.mention.vendor-preview.\(vendor.id)")
    }
}
