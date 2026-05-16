import SwiftUI
import ClawdmeterShared

/// Sessions v2 Phase 8 — soft-warn cost banner for the iOS new-session
/// sheet (D3 + D11). Renders the daemon's pre-flight estimate:
/// - Estimated USD for the session (best-effort from past-7d history)
/// - Weekly-cap projection (current usage + this session)
/// - "Switch to <cheaper model>" CTA when the projection would push
///   weekly usage past 95%
///
/// Per D11 the banner is a soft warn — it never blocks Start. The CTA
/// flips the parent's `modelId` binding to the suggested model.
struct CostBannerView: View {
    let response: PreflightResponse
    let currentModel: String
    let onSwap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if response.wouldCap {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SessionsV2Theme.warn)
                } else {
                    Image(systemName: "dollarsign.circle")
                        .foregroundStyle(SessionsV2Theme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let cost = response.estimatedCostUSD {
                        Text(formatCost(cost))
                            .font(.headline)
                            .monospacedDigit()
                    } else {
                        Text("No history yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    if let pct = response.weeklyCapPct {
                        Text(weeklyLine(pct))
                            .font(.caption)
                            .foregroundStyle(response.wouldCap ? SessionsV2Theme.warn : .secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
            }
            if response.wouldCap, let swap = response.suggestedSwap, swap != currentModel {
                Button {
                    onSwap(swap)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Switch to \(prettyModel(swap))")
                            .font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(SessionsV2Theme.accent.opacity(0.15))
                    .foregroundStyle(SessionsV2Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private func formatCost(_ dollars: Double) -> String {
        if dollars < 0.01 {
            return "< $0.01 / session"
        } else if dollars < 1 {
            return String(format: "~$%.2f / session", dollars)
        } else if dollars < 100 {
            return String(format: "~$%.2f / session", dollars)
        } else {
            return String(format: "~$%.0f / session", dollars)
        }
    }

    private func weeklyLine(_ projected: Double) -> String {
        let pct = Int((projected * 100).rounded())
        if response.wouldCap {
            return "Would push weekly usage to ~\(pct)% — at cap"
        }
        return "Projected weekly usage: ~\(pct)%"
    }

    private func prettyModel(_ id: String) -> String {
        switch id {
        case "claude-opus-4-7-1m": return "Opus 4.7 (1M)"
        case "claude-opus-4-7": return "Opus 4.7"
        case "claude-opus-4-6-1m": return "Opus 4.6 (1M)"
        case "claude-sonnet-4-6": return "Sonnet 4.6"
        case "claude-haiku-4-5-20251001": return "Haiku 4.5"
        default: return id
        }
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let cost = response.estimatedCostUSD {
            parts.append("Estimated cost \(formatCost(cost))")
        } else {
            parts.append("No history for this repo")
        }
        if let pct = response.weeklyCapPct {
            parts.append("Projected weekly usage \(Int((pct * 100).rounded())) percent")
        }
        if response.wouldCap, let swap = response.suggestedSwap {
            parts.append("Suggests switching to \(prettyModel(swap))")
        }
        return parts.joined(separator: ", ")
    }
}
