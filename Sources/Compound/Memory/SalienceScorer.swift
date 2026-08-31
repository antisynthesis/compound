import Foundation

/// Ranks ``Fact`` records by recency, importance, and query relevance.
///
/// The shape is Generative Agents' retrieval function — a weighted sum
/// of three min-max-normalized components, with all weights at 1 — and
/// the reasons for keeping that shape are that it is cheap, explainable,
/// and needs no model call, which is what lets the read path stay at
/// zero model calls per turn.
///
/// **Recalibration note.** The 72-hour half-life is a
/// conversational-assistant starting point chosen here, *not* the
/// published `γ = 0.995` per simulated hour. That constant is expressed
/// in a simulation clock where an agent lives a compressed day per
/// episode; copying it into wall-clock hours would decay a real user's
/// memory roughly two orders of magnitude too aggressively. Treat 72
/// hours as a tunable default and re-fit it against
/// `MemoryEvalReport` before claiming anything about it.
///
/// Scoring is a pure function of the stored timestamps and the injected
/// `now`. Nothing here reads the system clock, so an eval replays byte
/// for byte.
public struct SalienceScorer: Sendable, Equatable {
    /// Per-component multipliers applied after normalization.
    public struct Weights: Sendable, Equatable, Codable {
        /// Weight on the recency term.
        public var recency: Double
        /// Weight on the importance term.
        public var importance: Double
        /// Weight on the relevance term.
        public var relevance: Double

        /// Creates a weight triple. All three default to 1, matching the
        /// published `α_recency = α_importance = α_relevance = 1`.
        public init(recency: Double = 1, importance: Double = 1, relevance: Double = 1) {
            self.recency = recency
            self.importance = importance
            self.relevance = relevance
        }
    }

    /// Component weights.
    public let weights: Weights
    /// Hours over which the recency term halves.
    public let recencyHalfLifeHours: Double

    /// Creates a scorer.
    ///
    /// - Precondition: `recencyHalfLifeHours` is positive.
    public init(weights: Weights = Weights(), recencyHalfLifeHours: Double = 72) {
        precondition(recencyHalfLifeHours > 0, "recencyHalfLifeHours must be positive")
        self.weights = weights
        self.recencyHalfLifeHours = recencyHalfLifeHours
    }

    /// Scores and ranks `facts`.
    ///
    /// Raw components, per fact:
    ///
    /// - recency: `pow(0.5, hours(lastAccessedAt → now) / halfLife)`,
    ///   with negative elapsed time (a fact touched "in the future"
    ///   relative to `now`) treated as zero hours, so a clock skew can
    ///   never produce a term above 1.
    /// - importance: `Double(fact.importance)`.
    /// - relevance: `relevance[fact.id] ?? 0`.
    ///
    /// Each component is then min-max normalized **across the supplied
    /// set** and multiplied by its weight. Normalizing across the set
    /// rather than against an absolute scale is what makes the three
    /// terms commensurable at all; the cost is that a score is only
    /// meaningful relative to the batch it was computed in, which is why
    /// ``ScoredFact/components`` are carried along.
    ///
    /// A component whose maximum equals its minimum normalizes to 0 for
    /// every fact rather than dividing by zero — so a single-fact input,
    /// or a set with no relevance signal at all, yields a finite score
    /// and never `NaN`.
    ///
    /// Results are sorted by score descending, ties broken on
    /// ``Fact/id`` ascending.
    public func score(_ facts: [Fact], relevance: [String: Double], now: Date) -> [ScoredFact] {
        guard !facts.isEmpty else { return [] }
        let rawRecency = facts.map { fact -> Double in
            let seconds = now.timeIntervalSince(fact.lastAccessedAt)
            let hours = max(0, seconds / 3600)
            return min(1, max(0, pow(0.5, hours / recencyHalfLifeHours)))
        }
        let rawImportance = facts.map { Double($0.importance) }
        let rawRelevance = facts.map { relevance[$0.id] ?? 0 }

        let recency = SalienceScorer.normalize(rawRecency)
        let importance = SalienceScorer.normalize(rawImportance)
        let relevanceN = SalienceScorer.normalize(rawRelevance)

        var scored: [ScoredFact] = []
        scored.reserveCapacity(facts.count)
        for i in facts.indices {
            let components = SalienceComponents(
                recency: recency[i],
                importance: importance[i],
                relevance: relevanceN[i]
            )
            let total = weights.recency * components.recency
                + weights.importance * components.importance
                + weights.relevance * components.relevance
            scored.append(ScoredFact(fact: facts[i], score: total, components: components))
        }
        scored.sort { a, b in
            a.score == b.score ? a.fact.id < b.fact.id : a.score > b.score
        }
        return scored
    }

    /// Min-max normalizes `values` to `[0, 1]`. A degenerate range
    /// (max == min, which includes the single-element case) maps every
    /// entry to 0: the component carries no discriminating information,
    /// so it should contribute nothing rather than a constant offset —
    /// and, critically, never a `NaN` that would poison the sort.
    static func normalize(_ values: [Double]) -> [Double] {
        guard let lo = values.min(), let hi = values.max() else { return [] }
        let span = hi - lo
        guard span > 0 else { return Array(repeating: 0, count: values.count) }
        return values.map { ($0 - lo) / span }
    }
}
