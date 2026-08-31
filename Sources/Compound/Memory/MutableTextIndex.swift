import Foundation

/// Write side of a text index that ``IndexedArchivalStore`` maintains.
///
/// The protocol exists to paper over a real signature asymmetry between
/// the two bundled retrievers: ``BM25Retriever/index(_:)-9k4qi`` is
/// non-throwing (tokenization cannot fail) while
/// ``DenseRetriever/index(_:)-3a3lk`` is `async throws` (embedding can).
/// Rather than force one shape on both, the adapters conform to a single
/// throwing requirement — a non-throwing witness satisfies it, so the
/// BM25 side pays nothing for the generality.
///
/// It is deliberately *write-only*. Reading goes through the existing
/// ``Retriever`` surface — normally a ``HybridRetriever`` over the very
/// same actors — because the archive is not a third index, it is a
/// side table over the two that already exist.
public protocol MutableTextIndex: Sendable {
    /// Stable name used in ``MemoryError/partialRemoval(chunkIDs:failedIndexes:)``
    /// so a failed fan-out names the index that did not take the delete.
    var indexName: String { get }
    /// Inserts or replaces `chunks` by ``DocumentChunk/id``.
    func upsert(_ chunks: [DocumentChunk]) async throws
    /// Removes the chunks with `ids`. Returns the number actually removed.
    @discardableResult
    func remove(ids: [String]) async throws -> Int
    /// Whether `id` is currently indexed.
    func contains(id: String) async -> Bool
}

/// ``MutableTextIndex`` adapter over a ``BM25Retriever`` actor.
public struct BM25Index: MutableTextIndex {
    /// The wrapped lexical retriever. Share the same actor instance with
    /// the reader so writes and reads see one index.
    public let retriever: BM25Retriever
    public let indexName: String

    /// Wraps `retriever`.
    public init(_ retriever: BM25Retriever, indexName: String = "bm25") {
        self.retriever = retriever
        self.indexName = indexName
    }

    /// Upserts into the lexical index. Cannot fail.
    public func upsert(_ chunks: [DocumentChunk]) async {
        await retriever.index(chunks)
    }

    /// Removes from the lexical index, restoring document-frequency and
    /// average-length statistics exactly.
    @discardableResult
    public func remove(ids: [String]) async -> Int {
        await retriever.remove(ids: ids)
    }

    public func contains(id: String) async -> Bool {
        await retriever.contains(id: id)
    }
}

/// ``MutableTextIndex`` adapter over a ``DenseRetriever`` actor.
public struct DenseIndex: MutableTextIndex {
    /// The wrapped dense retriever. Share the same actor instance with
    /// the reader so writes and reads see one index.
    public let retriever: DenseRetriever
    public let indexName: String

    /// Wraps `retriever`.
    public init(_ retriever: DenseRetriever, indexName: String = "dense") {
        self.retriever = retriever
        self.indexName = indexName
    }

    /// Embeds and upserts into the dense index.
    ///
    /// Errors propagate: an embedding provider that is down is not a
    /// silent partial index, it is a failed archive the caller must
    /// retry.
    public func upsert(_ chunks: [DocumentChunk]) async throws {
        try await retriever.index(chunks)
    }

    @discardableResult
    public func remove(ids: [String]) async -> Int {
        await retriever.remove(ids: ids)
    }

    public func contains(id: String) async -> Bool {
        await retriever.contains(id: id)
    }
}
