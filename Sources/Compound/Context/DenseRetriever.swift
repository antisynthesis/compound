import Foundation
import NaturalLanguage

/// Source of vector embeddings used by ``DenseRetriever``. The default
/// implementation wraps Apple's `NLEmbedding` (see
/// ``NLEmbeddingProvider``); plug in a custom provider for domains where
/// the system embedding model is insufficient.
public protocol EmbeddingProvider: Sendable {
    /// Returns a vector embedding of `text`.
    func embed(_ text: String) async throws -> [Double]
}

/// Failure modes for the embedding pipeline.
public enum EmbeddingError: Error, Equatable {
    /// Apple does not ship a sentence-embedding model for the requested language.
    case notAvailableForLanguage(String)
    /// The provider returned `nil` for a non-empty input.
    case vectorMissing
    /// A newly produced vector has a different dimension than the index expects.
    case dimensionMismatch(expected: Int, got: Int)
}

/// `EmbeddingProvider` backed by Apple's `NLEmbedding`. Runs entirely on
/// device with no network and no API key. Apple ships pretrained
/// embeddings for English and a few other languages; consult
/// `NLEmbedding` documentation for the current availability matrix.
///
/// The type is annotated `@unchecked Sendable` because Apple does not
/// formally document the thread-safety of `NLEmbedding.vector(for:)`.
/// Empirically the read-only call is safe to share; callers that hit
/// problems under heavy contention should serialize access through an
/// actor.
public struct NLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    /// Underlying `NLEmbedding`.
    public let embedding: NLEmbedding
    /// Loads the sentence-embedding model for `language`.
    ///
    /// - Throws: ``EmbeddingError/notAvailableForLanguage(_:)`` if no
    ///   model is available.
    public init(language: NLLanguage = .english) throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            throw EmbeddingError.notAvailableForLanguage(language.rawValue)
        }
        self.embedding = embedding
    }
    /// Embeds `text` via the underlying model.
    public func embed(_ text: String) async throws -> [Double] {
        guard let vec = embedding.vector(for: text) else {
            throw EmbeddingError.vectorMissing
        }
        return vec
    }
}

/// Dense (vector) retriever over an in-memory corpus of pre-normalized
/// unit-length embeddings. Cosine similarity reduces to a single dot
/// product per (query, doc) pair at retrieve time. Suitable for small to
/// medium corpora; pair with ``HybridRetriever`` for better recall.
public actor DenseRetriever: Retriever {
    // Stored as pre-normalized unit vectors so cosine similarity reduces to
    // a single dot product at retrieve time (no per-query sqrt, no divisor).
    private struct IndexedChunk: Sendable {
        let chunk: DocumentChunk
        let unit: [Double]
    }
    private var indexed: [IndexedChunk] = []
    private var dimension: Int?
    private let provider: any EmbeddingProvider
    private let minScore: Double
    private let indexingConcurrency: Int

    /// Creates a retriever.
    ///
    /// - Parameters:
    ///   - provider: Source of embeddings.
    ///   - minScore: Minimum cosine score required for a chunk to be
    ///     returned by ``retrieve(query:limit:)``.
    ///   - indexingConcurrency: Maximum in-flight embedding calls
    ///     during ``index(_:)-3a3lk``. Must be at least 1.
    public init(provider: any EmbeddingProvider, minScore: Double = 0, indexingConcurrency: Int = 4) {
        precondition(indexingConcurrency >= 1, "indexingConcurrency must be >= 1")
        self.provider = provider
        self.minScore = minScore
        self.indexingConcurrency = indexingConcurrency
    }

    /// Embeds and indexes `chunks` with bounded concurrency. Zero-norm
    /// vectors are silently skipped; one degenerate input does not fail
    /// the batch.
    public func index(_ chunks: [DocumentChunk]) async throws {
        guard !chunks.isEmpty else { return }
        let provider = self.provider
        let limit = max(1, indexingConcurrency)
        // Embed in parallel with a bounded window so we don't fan out an
        // unbounded number of concurrent calls into the embedding provider
        // (which on Apple platforms is backed by a single NLEmbedding model
        // and degrades under thrash).
        let embedded: [(Int, [Double])] = try await withThrowingTaskGroup(of: (Int, [Double]).self) { group in
            var next = 0
            var results: [(Int, [Double])] = []
            results.reserveCapacity(chunks.count)
            let initial = min(limit, chunks.count)
            for _ in 0..<initial {
                let i = next
                let text = chunks[i].content
                group.addTask { (i, try await provider.embed(text)) }
                next += 1
            }
            while let value = try await group.next() {
                results.append(value)
                if next < chunks.count {
                    let i = next
                    let text = chunks[i].content
                    group.addTask { (i, try await provider.embed(text)) }
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }
        }
        for (i, vec) in embedded {
            try appendEmbedding(chunk: chunks[i], vec: vec)
        }
    }

    /// Embeds and indexes a single chunk.
    public func index(_ chunk: DocumentChunk) async throws {
        let vec = try await provider.embed(chunk.content)
        try appendEmbedding(chunk: chunk, vec: vec)
    }

    private func appendEmbedding(chunk: DocumentChunk, vec: [Double]) throws {
        if let d = dimension {
            guard vec.count == d else {
                throw EmbeddingError.dimensionMismatch(expected: d, got: vec.count)
            }
        } else {
            dimension = vec.count
        }
        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else {
            // A zero vector contributes nothing to cosine similarity; storing
            // it would just be dead weight. Skip silently — the embedding
            // provider produced an unusable vector, but failing the entire
            // batch over one degenerate input is too aggressive.
            return
        }
        let unit = vec.map { $0 / norm }
        indexed.append(IndexedChunk(chunk: chunk, unit: unit))
    }

    /// Embeds `query` and returns the top-`limit` indexed chunks by
    /// cosine similarity, filtered by ``minScore``.
    public func retrieve(query: String, limit: Int) async throws -> [RetrievedSource] {
        guard !indexed.isEmpty else { return [] }
        let qVec = try await provider.embed(query)
        if let d = dimension {
            assert(qVec.count == d, "query embedding dimension (\(qVec.count)) does not match index dimension (\(d))")
            guard qVec.count == d else {
                throw EmbeddingError.dimensionMismatch(expected: d, got: qVec.count)
            }
        }
        let qNorm = sqrt(qVec.reduce(0) { $0 + $1 * $1 })
        guard qNorm > 0 else { return [] }
        let qUnit = qVec.map { $0 / qNorm }
        var scored: [(IndexedChunk, Double)] = []
        scored.reserveCapacity(indexed.count)
        for entry in indexed {
            // Pre-normalized vectors reduce cosine similarity to a plain
            // dot product — no per-query divide.
            var dot: Double = 0
            let u = entry.unit
            for i in 0..<u.count { dot += qUnit[i] * u[i] }
            if dot >= minScore { scored.append((entry, dot)) }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map {
            RetrievedSource(
                id: $0.0.chunk.id,
                title: "\($0.0.chunk.documentID)#\($0.0.chunk.ordinal)",
                content: $0.0.chunk.content,
                score: $0.1
            )
        }
    }

    /// Number of indexed chunks.
    public var count: Int { indexed.count }
    /// Dimensionality of the first indexed vector, or `nil` if the index
    /// is empty.
    public var indexedDimension: Int? { dimension }
}
