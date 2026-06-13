import Foundation

/// Spawn mode (Mac Code tab): the user picks a total terminal count (1/2/4/6/8)
/// and an agent mix ("4 Claude, 2 Codex, 2 Cursor"); the Mac opens that many
/// interactive agent CLIs in PTY tiles, all cwd'd to the home directory.
///
/// `SpawnPlan` is the pure value half — allocation expansion, most-to-least
/// ordering, per-tile labels, and grid shape — so the PTY-owning Mac store
/// stays a thin shell and this logic is testable from the shared package.
public struct SpawnAgentAllocation: Equatable, Sendable {
    public let agent: AgentKind
    public let count: Int

    public init(agent: AgentKind, count: Int) {
        self.agent = agent
        self.count = count
    }
}

public enum SpawnPlan {
    /// One terminal tile to open: which agent CLI and its display label
    /// ("Claude 1", "Codex 2", …).
    public struct Slot: Equatable, Sendable {
        public let agent: AgentKind
        public let title: String

        public init(agent: AgentKind, title: String) {
            self.agent = agent
            self.title = title
        }
    }

    /// Terminal counts offered in the spawn config page. The first entry is
    /// the default selection on a fresh page.
    public static let sessionCountOptions: [Int] = [1, 2, 4, 6, 8]

    /// Agents offered in the spawn config page, in display order.
    /// `.unknown` is already excluded by `AgentKind.allCases`.
    public static let selectableAgents: [AgentKind] = AgentKind.allCases

    /// Expand an allocation into ordered slots. Agents with the LARGEST
    /// count spawn first ("start with the most to least"); ties keep the
    /// caller's order. Slots of the same kind are numbered within the kind.
    /// Duplicate entries for the same agent are merged (counts summed, first
    /// position kept) so numbering never restarts mid-kind.
    public static func slots(for allocations: [SpawnAgentAllocation]) -> [Slot] {
        var mergedCounts: [AgentKind: Int] = [:]
        var firstSeen: [AgentKind] = []
        for allocation in allocations where allocation.count > 0 {
            if mergedCounts[allocation.agent] == nil { firstSeen.append(allocation.agent) }
            mergedCounts[allocation.agent, default: 0] += allocation.count
        }
        let ordered = firstSeen
            .enumerated()
            .sorted { lhs, rhs in
                let lhsCount = mergedCounts[lhs.element] ?? 0
                let rhsCount = mergedCounts[rhs.element] ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        var slots: [Slot] = []
        for agent in ordered {
            guard let count = mergedCounts[agent], count > 0 else { continue }
            let name = AgentKindUI.displayName(for: agent)
            for index in 1...count {
                slots.append(Slot(agent: agent, title: "\(name) \(index)"))
            }
        }
        return slots
    }

    // MARK: - Config-page allocation bookkeeping (pure, testable)

    /// Default allocation for a fresh config page: the whole batch goes to
    /// the first spawnable agent (Claude when installed) so "just spawn 4"
    /// is a two-click flow. Empty when nothing is spawnable.
    public static func seededAllocation(
        total: Int,
        availableAgents: [AgentKind]
    ) -> [AgentKind: Int] {
        guard total > 0, let first = availableAgents.first else { return [:] }
        return [first: total]
    }

    /// Keep an allocation consistent when the total changes: grow into the
    /// first available agent; shrink from the bottom of the display order
    /// upward. Returns the input unchanged when already consistent.
    public static func rebalancedAllocation(
        _ counts: [AgentKind: Int],
        total: Int,
        availableAgents: [AgentKind],
        displayOrder: [AgentKind] = selectableAgents
    ) -> [AgentKind: Int] {
        var counts = counts
        var allocated = counts.values.reduce(0, +)
        if allocated < total {
            if let first = availableAgents.first {
                counts[first, default: 0] += total - allocated
            }
            return counts
        }
        for agent in displayOrder.reversed() {
            guard allocated > total else { break }
            let current = counts[agent] ?? 0
            guard current > 0 else { continue }
            let trim = min(current, allocated - total)
            counts[agent] = current - trim
            allocated -= trim
        }
        return counts
    }

    /// Bump `agent` up by one against a FIXED total. When unallocated slots
    /// remain, consume one. When the batch is already full, steal a slot from
    /// a donor so "+" is never a dead button — clicking it on a second agent
    /// auto-debits the default (first available) agent, e.g. Claude. Falls
    /// back to the first OTHER agent in display order that still holds a slot
    /// when the default can't donate. A no-op only when `agent` already owns
    /// every slot (nothing left to take).
    public static func incrementAllocation(
        _ counts: [AgentKind: Int],
        agent: AgentKind,
        total: Int,
        availableAgents: [AgentKind],
        displayOrder: [AgentKind] = selectableAgents
    ) -> [AgentKind: Int] {
        var counts = counts
        let allocated = counts.values.reduce(0, +)
        if allocated < total {
            counts[agent, default: 0] += 1
            return counts
        }
        func holdsSlot(_ candidate: AgentKind) -> Bool {
            candidate != agent && (counts[candidate] ?? 0) > 0
        }
        let donor: AgentKind?
        if let preferred = availableAgents.first, holdsSlot(preferred) {
            donor = preferred
        } else {
            donor = displayOrder.first(where: holdsSlot)
        }
        guard let donor else { return counts }
        counts[donor, default: 0] -= 1
        counts[agent, default: 0] += 1
        return counts
    }

    /// Grid shape for a tile count: 4 → 2×2, 6 → 3×2, 8 → 4×2. Counts in
    /// between (tiles closed mid-session) round to the nearest shape that
    /// keeps at most two rows.
    public static func gridColumns(forTileCount count: Int) -> Int {
        switch count {
        case ..<2:  return 1
        case 2...4: return 2
        case 5...6: return 3
        default:    return 4
        }
    }
}
