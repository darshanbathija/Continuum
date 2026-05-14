import Foundation

/// Aggregated token counts + computed cost, summable across records / files /
/// time windows.
///
/// Per plan A5 + A16: dollars are the primary surface number with adaptive
/// precision (2 decimals when ≥ $0.01, 4 decimals when < $0.01). Cost is
/// stored as `Decimal` to avoid binary-float drift when accumulating many
/// small currency values.
///
/// `+` and `+=` make window aggregation a one-liner:
///   `byDay.values.reduce(.zero, +)`
public struct TokenTotals: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var reasoningTokens: Int
    public var costUSD: Decimal

    public static let zero = TokenTotals(
        inputTokens: 0,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        reasoningTokens: 0,
        costUSD: 0
    )

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        costUSD: Decimal = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.costUSD = costUSD
    }

    /// Sum of all token kinds. Used as the "headline" tokens number in the UI.
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens + reasoningTokens
    }

    public static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            costUSD: lhs.costUSD + rhs.costUSD
        )
    }

    public static func += (lhs: inout TokenTotals, rhs: TokenTotals) {
        lhs = lhs + rhs
    }
}
