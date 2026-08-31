import Foundation

/// Reciprocal Rank Fusion across multiple ``Retriever``s — typically a
/// lexical ``BM25Retriever`` and a dense ``DenseRetriever``. Each member
/// contributes `1 / (k + rank)` per result it returns and the
/// contributions are summed per document id, so fusion needs no
/// cross-retriever score normalization — only rank order, which is
/// comparable across retrievers whose raw scores are not.
///
/// Fusion is by ``RetrievedSource/id``, which is why chunk ids must be
/// stable: ``DocumentChunker`` derives them deterministically from
/// content so the same chunk reached through the lexical and the dense
/// path fuses instead of appearing twice at half weight.
///
/// ## Optional rerank stage
///
/// Supply a ``Reranker`` to add a precision pass on top of fusion: the
/// retriever then fuses to `limit` × ``rerankCandidateMultiplier``
/// candidates, reranks that deeper list, and truncates to `limit`. The
/// trade-off is latency for ordering quality — fusion is microseconds,
/// while a ``ModelReranker`` pass costs one model call per batch of
/// candidates (hundreds of milliseconds each, on device). Prefer the
/// deterministic ``LexicalProximityReranker`` where its positional signal
/// is enough; reach for a model reranker only when it is not.
public struct HybridRetriever: Retriever {
    /// Member retrievers; results are fused in parallel.
    public let retrievers: [any Retriever]
    /// Number of candidates pulled from each member before fusion.
    ///
    /// When a ``reranker`` is configured this is a floor, not a cap: the
    /// per-member fetch widens to the rerank candidate depth when that is
    /// larger, since fusing fewer candidates than the reranker is asked to
    /// consider would starve it. Fetching deeper only appends lower-ranked
    /// results, so the ranks the RRF weights are computed from do not move.
    public let perRetrieverLimit: Int
    /// RRF rank-discounting constant — the `k` in `1 / (k + rank)`.
    ///
    /// It sets how flat the per-rank weights are. Small `k` makes rank 1
    /// dominate (at `k = 0`, rank 1 scores 1.0 and rank 2 only 0.5, so a
    /// single retriever's top hit can outweigh agreement between two
    /// others); large `k` flattens the curve until fusion approaches a
    /// plain vote count over the candidate sets. The default `60` is the
    /// value Cormack, Clarke, and Buettcher reported as robust across
    /// TREC collections, and it is what most RRF implementations ship.
    /// Must be non-negative — with `k = 0` the formula is still
    /// well-defined because ranks are 1-based.
    public let k: Int
    /// Optional second-stage reranker. `nil` (the default) skips the
    /// stage entirely and returns the fused ordering.
    public let reranker: (any Reranker)?
    /// How much deeper than `limit` the fused candidate list runs when a
    /// ``reranker`` is configured.
    ///
    /// The reranker can only reorder what fusion hands it, so a
    /// multiplier of 1 lets it permute the top-`limit` set but never
    /// promote a result fusion ranked below the cut — which is most of the
    /// value. Larger multipliers give it more to work with at
    /// proportionally more cost (for ``ModelReranker``, proportionally
    /// more model calls). Defaults to 3.
    public let rerankCandidateMultiplier: Int

    /// Creates a hybrid retriever.
    ///
    /// - Parameters:
    ///   - retrievers: Member retrievers, queried concurrently.
    ///   - perRetrieverLimit: Candidates pulled from each member.
    ///   - k: RRF rank-discounting constant. Must be non-negative.
    ///   - reranker: Optional second-stage reranker.
    ///   - rerankCandidateMultiplier: Candidate depth multiplier for the
    ///     rerank stage. Must be positive. Ignored when `reranker` is nil.
    public init(
        retrievers: [any Retriever],
        perRetrieverLimit: Int = 20,
        k: Int = 60,
        reranker: (any Reranker)? = nil,
        rerankCandidateMultiplier: Int = 3
    ) {
        precondition(k >= 0, "RRF k must be non-negative")
        precondition(rerankCandidateMultiplier > 0, "rerank candidate multiplier must be positive")
        self.retrievers = retrievers
        self.perRetrieverLimit = perRetrieverLimit
        self.k = k
        self.reranker = reranker
        self.rerankCandidateMultiplier = rerankCandidateMultiplier
    }

    /// Runs every member retriever concurrently and fuses results by RRF,
    /// then applies the optional ``reranker``.
    ///
    /// Output is deterministic: ties on fused score break by source id,
    /// and the rerank stage is required to be deterministic too.
    public func retrieve(query: String, limit: Int) async throws -> [RetrievedSource] {
        guard limit > 0 else { return [] }
        // With a reranker, fuse deeper than the caller asked for so the
        // second stage has candidates it can actually promote, and widen
        // the per-member fetch to match.
        let candidateDepth = reranker == nil ? limit : Self.depth(limit: limit, multiplier: rerankCandidateMultiplier)
        // Fan out across member retrievers in parallel — they're independent
        // and the slowest one (usually the dense retriever) dictates latency
        // when run serially. The returned tuple preserves the original
        // retriever index so we can re-assemble in the configured order,
        // which keeps "first seen wins" semantics deterministic.
        let perRetrieverLimit = reranker == nil
            ? self.perRetrieverLimit
            : max(self.perRetrieverLimit, candidateDepth)
        let perRetriever: [[RetrievedSource]] = try await withThrowingTaskGroup(of: (Int, [RetrievedSource]).self) { group in
            for (i, r) in retrievers.enumerated() {
                group.addTask {
                    (i, try await r.retrieve(query: query, limit: perRetrieverLimit))
                }
            }
            var collected: [(Int, [RetrievedSource])] = []
            collected.reserveCapacity(retrievers.count)
            while let value = try await group.next() {
                collected.append(value)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var fusedScore: [String: Double] = [:]
        var firstSeen: [String: RetrievedSource] = [:]
        for results in perRetriever {
            // Dedupe *within* a member's result list before fusing. A
            // retriever that returns the same id twice (a corpus indexed
            // with duplicate ids, a union-style retriever) would otherwise
            // pay itself twice for one document and outvote genuine
            // cross-retriever agreement. Only its best rank counts.
            var creditedByThisRetriever: Set<String> = []
            creditedByThisRetriever.reserveCapacity(results.count)
            for (index, source) in results.enumerated() {
                guard creditedByThisRetriever.insert(source.id).inserted else { continue }
                let rank = index + 1
                fusedScore[source.id, default: 0] += 1.0 / Double(k + rank)
                if firstSeen[source.id] == nil {
                    firstSeen[source.id] = source
                }
            }
        }
        // Stable, deterministic order: primary by fused score descending,
        // tie-break by source id ascending so the same input always yields
        // the same output (Dictionary iteration order is not deterministic).
        let merged = fusedScore.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            return a.key < b.key
        }
        let fused: [RetrievedSource] = merged.prefix(candidateDepth).compactMap { entry in
            guard let base = firstSeen[entry.key] else { return nil }
            return RetrievedSource(id: base.id, title: base.title, content: base.content, score: entry.value)
        }
        guard let reranker else { return fused }
        return try await reranker.rerank(query: query, candidates: fused, limit: limit)
    }

    /// Candidate depth for the rerank stage, saturating rather than
    /// trapping on overflow — `limit` comes from callers and a huge one
    /// must degrade to "everything", not crash the run.
    static func depth(limit: Int, multiplier: Int) -> Int {
        let (product, overflow) = limit.multipliedReportingOverflow(by: multiplier)
        return overflow ? Int.max : product
    }
}
