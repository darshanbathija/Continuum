import Foundation

/// Deterministic pseudo-random number generator for perf-fixture
/// generation. Uses xorshift128+ so fixtures are bit-stable across
/// machines + OS upgrades — required for the A0 "ranked top-10 hotspots"
/// table to be reproducible.
///
/// Not suitable for security-sensitive work (cryptography uses
/// CryptoKit). This is purely for "give me the same 10,000 mock chat
/// items every run."
///
/// Plan: A0 (Phase 0) — see .claude/plans/study-this-codebase-crystalline-shore.md
public struct SeededPRNG: RandomNumberGenerator {
    private var state0: UInt64
    private var state1: UInt64

    /// Seed with any non-zero value. Distinct seeds produce distinct
    /// streams; identical seeds produce identical streams.
    public init(seed: UInt64) {
        // xorshift128+ requires non-zero state.
        let seed = seed == 0 ? 0x1234_5678_9ABC_DEF0 : seed
        state0 = seed
        state1 = seed &+ 0xDEAD_BEEF_CAFE_BABE
        // Mix the state a few times so adjacent seeds don't yield
        // correlated streams.
        for _ in 0..<8 { _ = next() }
    }

    public mutating func next() -> UInt64 {
        var s1 = state0
        let s0 = state1
        state0 = s0
        s1 ^= s1 << 23
        state1 = s1 ^ s0 ^ (s1 >> 17) ^ (s0 >> 26)
        return state1 &+ s0
    }

    /// Uniform integer in `0..<upperBound`.
    public mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    /// Uniform double in `[0, 1)`. Useful for distribution shaping.
    public mutating func nextDouble() -> Double {
        // Divide by 2^53 to land in [0, 1) without precision loss.
        return Double(next() >> 11) * (1.0 / Double(1 << 53))
    }

    /// Pick a random element from `array`. Returns nil for empty input.
    public mutating func pick<T>(_ array: [T]) -> T? {
        guard !array.isEmpty else { return nil }
        return array[nextInt(upperBound: array.count)]
    }
}
