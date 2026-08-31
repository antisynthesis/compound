import Foundation

// Retrieval quality is measured on ranked id lists, not on model text, so
// none of this needs a model, a device, or a network: it is pure,
// deterministic arithmetic over `[String]` and `[String: Double]`. That is
// what makes retrieval regressions cheap to gate in CI.

/// Deterministic ranking metrics for retrieval evaluation.
///
/// Every function here is pure and total: same inputs, same output, no
/// clock, no randomness, no I/O.
///
/// **Undefined vs. zero.** Each metric returns `Double?` and yields `nil`
/// exactly when the metric is *undefined* for the inputs, rather than
/// silently coercing to `0.0` or `1.0`:
///
/// - ``recallAtK(retrieved:relevant:k:)`` is `nil` when nothing is
///   relevant (there is no denominator).
/// - ``precisionAtK(retrieved:relevant:k:)`` is `nil` when nothing was
///   retrieved (there is nothing to judge). With a non-empty result list
///   and an empty relevant set it is a genuine `0.0`.
/// - ``ndcgAtK(retrieved:gains:k:)`` is `nil` when the ideal DCG is zero
///   (no positive gain exists to normalize against).
/// - ``reciprocalRankAtK(retrieved:relevant:k:)`` is `nil` when nothing is
///   relevant; it is `0.0` when relevant documents exist but none appear
///   in the top `k` — the standard convention.
///
/// This distinction is load-bearing for the abstention suite, where cases
/// deliberately have no relevant documents: those cases must be *excluded*
/// from a mean recall, not folded in as zeros (which would understate the
/// system) or as ones (which would flatter it). ``mean(_:)`` skips `nil`s
/// for exactly this reason.
public enum RetrievalMetrics {
    /// Returns the first `k` distinct ids of `retrieved`, preserving order.
    ///
    /// Duplicate ids are dropped, keeping the best (earliest) occurrence: a
    /// retriever that returns the same document twice must not be credited
    /// twice for it, and must not have a rank slot consumed by its own
    /// duplicate. This is the same defect class ``HybridRetriever`` guards
    /// against when fusing.
    ///
    /// - Precondition: `k > 0`.
    public static func topK(_ retrieved: [String], k: Int) -> [String] {
        precondition(k > 0, "k must be positive")
        var seen = Set<String>()
        seen.reserveCapacity(min(k, retrieved.count))
        var out: [String] = []
        out.reserveCapacity(min(k, retrieved.count))
        for id in retrieved {
            guard seen.insert(id).inserted else { continue }
            out.append(id)
            if out.count == k { break }
        }
        return out
    }

    /// Fraction of the relevant set that appears in the top `k`.
    ///
    /// `k` larger than the result list is not an error — the list is simply
    /// consumed in full.
    ///
    /// - Returns: `hits / |relevant|`, or `nil` if `relevant` is empty.
    /// - Precondition: `k > 0`.
    public static func recallAtK(retrieved: [String], relevant: Set<String>, k: Int) -> Double? {
        precondition(k > 0, "k must be positive")
        guard !relevant.isEmpty else { return nil }
        let top = topK(retrieved, k: k)
        return Double(hitCount(top, relevant)) / Double(relevant.count)
    }

    /// Fraction of the top `k` that is relevant.
    ///
    /// The denominator is `min(k, distinct results)`, not `k`. A retriever
    /// that returns three good results when asked for ten scores `1.0`, not
    /// `0.3` — padding a result list with known-irrelevant filler to fill
    /// the `k` slots should never be the score-maximizing move, because the
    /// abstention suite exists to reward exactly the opposite behavior.
    ///
    /// - Returns: `hits / min(k, distinct results)`, or `nil` if nothing
    ///   was retrieved.
    /// - Precondition: `k > 0`.
    public static func precisionAtK(retrieved: [String], relevant: Set<String>, k: Int) -> Double? {
        let top = topK(retrieved, k: k)
        guard !top.isEmpty else { return nil }
        return Double(hitCount(top, relevant)) / Double(top.count)
    }

    /// Normalized discounted cumulative gain at `k`, with graded relevance.
    ///
    /// `DCG@k = Σ gain(dᵢ) / log₂(i + 1)` over the 1-based ranks `i ≤ k`,
    /// normalized by the ideal DCG obtained by ranking the `k` highest
    /// gains first. Ids absent from `gains` contribute zero.
    ///
    /// The *linear* gain form is used. Callers who want the exponential
    /// form (`2^rel − 1`, which sharpens the reward for the top grade) pass
    /// pre-transformed gains — the transform is a property of the judgment
    /// scale, not of the metric.
    ///
    /// - Returns: `DCG@k / IDCG@k` in `[0, 1]`, or `nil` when no positive
    ///   gain exists (nothing to normalize against).
    /// - Precondition: `k > 0`, and every gain is non-negative.
    public static func ndcgAtK(retrieved: [String], gains: [String: Double], k: Int) -> Double? {
        precondition(gains.values.allSatisfy { $0 >= 0 }, "gains must be non-negative")
        let top = topK(retrieved, k: k)
        var dcg = 0.0
        for (index, id) in top.enumerated() {
            guard let gain = gains[id], gain > 0 else { continue }
            dcg += gain / discount(rank: index + 1)
        }
        var idcg = 0.0
        for (index, gain) in gains.values.filter({ $0 > 0 }).sorted(by: >).prefix(k).enumerated() {
            idcg += gain / discount(rank: index + 1)
        }
        guard idcg > 0 else { return nil }
        return dcg / idcg
    }

    /// Reciprocal rank of the first relevant document within the top `k`.
    ///
    /// - Returns: `1 / rank` of the first hit, `0.0` if relevant documents
    ///   exist but none is in the top `k`, or `nil` if `relevant` is empty.
    /// - Precondition: `k > 0`.
    public static func reciprocalRankAtK(retrieved: [String], relevant: Set<String>, k: Int) -> Double? {
        precondition(k > 0, "k must be positive")
        guard !relevant.isEmpty else { return nil }
        let top = topK(retrieved, k: k)
        for (index, id) in top.enumerated() where relevant.contains(id) {
            return 1.0 / Double(index + 1)
        }
        return 0.0
    }

    /// Arithmetic mean of the defined values, skipping `nil`s.
    ///
    /// This is how a per-query metric becomes a suite-level one: the mean
    /// of ``reciprocalRankAtK(retrieved:relevant:k:)`` over a suite *is*
    /// MRR.
    ///
    /// - Returns: The mean, or `nil` if no value is defined.
    public static func mean(_ values: [Double?]) -> Double? {
        let defined = values.compactMap { $0 }
        guard !defined.isEmpty else { return nil }
        return defined.reduce(0, +) / Double(defined.count)
    }

    /// Builds a binary graded-relevance table: every id in `relevantIDs`
    /// gets gain `1.0`.
    public static func binaryGains(_ relevantIDs: Set<String>) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: relevantIDs.map { ($0, 1.0) })
    }

    private static func hitCount(_ ids: [String], _ relevant: Set<String>) -> Int {
        ids.reduce(into: 0) { $0 += relevant.contains($1) ? 1 : 0 }
    }

    // Rank 1 must not be discounted, so the divisor is log₂(rank + 1):
    // log₂(2) = 1.
    private static func discount(rank: Int) -> Double {
        log2(Double(rank) + 1.0)
    }
}

/// The metric set computed for one query at a fixed cutoff.
///
/// Bundled (rather than returned as four loose optionals) so a report row,
/// a CI baseline, and a log line all describe the same numbers.
public struct RetrievalScores: Sendable, Codable, Equatable {
    /// Cutoff the ranked metrics were evaluated at.
    public let k: Int
    /// ``RetrievalMetrics/recallAtK(retrieved:relevant:k:)``.
    public let recall: Double?
    /// ``RetrievalMetrics/precisionAtK(retrieved:relevant:k:)``.
    public let precision: Double?
    /// ``RetrievalMetrics/ndcgAtK(retrieved:gains:k:)``.
    public let ndcg: Double?
    /// ``RetrievalMetrics/reciprocalRankAtK(retrieved:relevant:k:)``.
    public let reciprocalRank: Double?
    /// Number of results the retriever actually returned, before
    /// de-duplication and before the `k` cutoff. Kept raw because the
    /// abstention suite asks "did it return anything at all?".
    public let retrievedCount: Int
    /// Size of the ground-truth relevant set (`0` for an abstention case).
    public let relevantCount: Int
    /// Highest score among the returned results, or `nil` if the retriever
    /// reported no scores. Used to check an abstention floor.
    public let topScore: Double?

    /// Creates a metric set from already-computed values.
    public init(
        k: Int,
        recall: Double?,
        precision: Double?,
        ndcg: Double?,
        reciprocalRank: Double?,
        retrievedCount: Int,
        relevantCount: Int,
        topScore: Double?
    ) {
        self.k = k
        self.recall = recall
        self.precision = precision
        self.ndcg = ndcg
        self.reciprocalRank = reciprocalRank
        self.retrievedCount = retrievedCount
        self.relevantCount = relevantCount
        self.topScore = topScore
    }

    /// Scores a ranked result list against a graded ground truth.
    ///
    /// Relevance for the binary metrics (recall, precision, reciprocal
    /// rank) is "gain strictly greater than zero", so a judgment table may
    /// carry explicit `0.0` entries for documents that were assessed and
    /// found irrelevant without them counting as hits.
    ///
    /// - Precondition: `k > 0`.
    public static func compute(retrieved: [RetrievedSource], gains: [String: Double], k: Int) -> RetrievalScores {
        precondition(k > 0, "k must be positive")
        let ids = retrieved.map(\.id)
        let relevant = Set(gains.filter { $0.value > 0 }.keys)
        return RetrievalScores(
            k: k,
            recall: RetrievalMetrics.recallAtK(retrieved: ids, relevant: relevant, k: k),
            precision: RetrievalMetrics.precisionAtK(retrieved: ids, relevant: relevant, k: k),
            ndcg: RetrievalMetrics.ndcgAtK(retrieved: ids, gains: gains, k: k),
            reciprocalRank: RetrievalMetrics.reciprocalRankAtK(retrieved: ids, relevant: relevant, k: k),
            retrievedCount: retrieved.count,
            relevantCount: relevant.count,
            topScore: retrieved.compactMap(\.score).max()
        )
    }
}
