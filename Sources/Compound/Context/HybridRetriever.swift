import Foundation

/// Reciprocal Rank Fusion across multiple ``Retriever``s — typically a
/// lexical ``BM25Retriever`` and a dense ``DenseRetriever``. RRF avoids
/// the need for cross-retriever score normalization and is empirically
/// competitive with more elaborate learned fusions. The default
/// constant `k=60` follows the Cormack et al. recommendation.
public struct HybridRetriever: Retriever {
    /// Member retrievers; results are fused in parallel.
    public let retrievers: [any Retriever]
    /// Number of candidates pulled from each member before fusion.
    public let perRetrieverLimit: Int
    /// RRF rank-discounting constant.
    public let k: Int

    /// Creates a hybrid retriever.
    public init(retrievers: [any Retriever], perRetrieverLimit: Int = 20, k: Int = 60) {
        self.retrievers = retrievers
        self.perRetrieverLimit = perRetrieverLimit
        self.k = k
    }

    /// Runs every member retriever concurrently and fuses results by RRF.
    /// Output is deterministic: ties on fused score break by source id.
    public func retrieve(query: String, limit: Int) async throws -> [RetrievedSource] {
        // Fan out across member retrievers in parallel — they're independent
        // and the slowest one (usually the dense retriever) dictates latency
        // when run serially. The returned tuple preserves the original
        // retriever index so we can re-assemble in the configured order,
        // which keeps "first seen wins" semantics deterministic.
        let perRetrieverLimit = self.perRetrieverLimit
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
            for (index, source) in results.enumerated() {
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
        return merged.prefix(limit).compactMap { entry in
            guard let base = firstSeen[entry.key] else { return nil }
            return RetrievedSource(id: base.id, title: base.title, content: base.content, score: entry.value)
        }
    }
}

/// Reorders an existing candidate list using a more expensive signal —
/// a cross-encoder, a smaller LLM, or a domain-specific scorer. Always
/// opt-in; callers that do not need the latency cost should skip it.
public protocol Reranker: Sendable {
    /// Returns up to `limit` candidates reordered by relevance to `query`.
    func rerank(query: String, candidates: [RetrievedSource], limit: Int) async throws -> [RetrievedSource]
}

/// Composes a base ``Retriever`` and a ``Reranker`` into a single
/// retriever surface so the rest of the framework does not need to know
/// the difference.
public struct RerankingRetriever: Retriever {
    /// Base retriever that produces the candidate set.
    public let base: any Retriever
    /// Reranker that reorders candidates.
    public let reranker: any Reranker
    /// Number of candidates fetched from `base` before reranking.
    public let candidateLimit: Int

    /// Creates a reranking retriever.
    public init(base: any Retriever, reranker: any Reranker, candidateLimit: Int = 50) {
        self.base = base
        self.reranker = reranker
        self.candidateLimit = candidateLimit
    }

    /// Retrieves up to ``candidateLimit`` candidates from ``base`` then
    /// reorders them via ``reranker``.
    public func retrieve(query: String, limit: Int) async throws -> [RetrievedSource] {
        let candidates = try await base.retrieve(query: query, limit: candidateLimit)
        return try await reranker.rerank(query: query, candidates: candidates, limit: limit)
    }
}

/// Pass-through reranker — useful for tests and as the default when no
/// real reranker is plugged in.
public struct IdentityReranker: Reranker {
    /// Creates an instance.
    public init() {}
    /// Returns the first `limit` candidates unchanged.
    public func rerank(query _: String, candidates: [RetrievedSource], limit: Int) async throws -> [RetrievedSource] {
        Array(candidates.prefix(limit))
    }
}
