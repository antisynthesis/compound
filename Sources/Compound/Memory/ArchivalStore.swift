import Foundation

/// One archival round returned by a retrieval, with the reader's score
/// attached.
public struct ArchivalHit: Sendable, Equatable {
    /// The round, re-joined from the store's journal by chunk id.
    public let round: ArchivedRound
    /// Score from the reader that produced the hit, or `nil` when the
    /// reader does not score.
    public let score: Double?

    /// Creates a hit.
    public init(round: ArchivedRound, score: Double?) {
        self.round = round
        self.score = score
    }

    /// The hit rendered as evidence for context assembly.
    ///
    /// Content is ``ArchivedRound/displayText`` — the raw round, without
    /// the derived key line. The key line steers retrieval and then stops
    /// existing; LongMemEval found that putting derived text into the
    /// *value* hurts accuracy, so the value stays verbatim.
    ///
    /// Provenance rides in the title. ``RetrievedSource`` has no metadata
    /// field, and plumbing one through it was considered and rejected: it
    /// is the package's most widely used struct, a source-breaking change
    /// to it would touch every retriever, assembler, and eval in the
    /// tree, and the title is already escaped as an attribute by
    /// ``PromptFrame``, so it is a safe channel. The thread and ordinal
    /// are what a reader needs to find the original messages; the store's
    /// journal holds the message ids for anything richer.
    public var retrievedSource: RetrievedSource {
        let formatter = ISO8601DateFormatter()
        return RetrievedSource(
            id: round.id,
            title: "thread \(round.threadID) round \(round.ordinal) [\(formatter.string(from: round.startedAt))]",
            content: round.displayText,
            score: score
        )
    }
}

/// Storage for conversation rounds that have aged out of the working
/// window.
///
/// The archive is tier 2 of Compound's memory: bulk transcript, indexed
/// lexically and densely, read back through the retrievers that already
/// exist. Tier 1 (``Fact`` records) is small, structured, and read
/// without any index at all.
public protocol ArchivalStore: Sendable {
    /// Indexes and records `rounds`. Re-archiving an identical round is a
    /// no-op upsert, which is what makes the whole path safe to re-run
    /// after a deferred background pass.
    func archive(_ rounds: [ArchivedRound]) async throws
    /// Removes rounds from every index and from the journal.
    ///
    /// - Returns: The number of rounds actually dropped from the journal.
    /// - Throws: ``MemoryError/partialRemoval(chunkIDs:failedIndexes:)``
    ///   if any index refused the delete.
    @discardableResult
    func remove(chunkIDs: [String]) async throws -> Int
    /// Removes every round belonging to `threadID`.
    /// - Returns: The chunk ids that were removed.
    @discardableResult
    func removeThread(_ threadID: String) async throws -> [String]
    /// Looks a round up by chunk id.
    func round(chunkID: String) async throws -> ArchivedRound?
    /// Retrieves rounds for `query`, optionally scoped to one thread.
    func retrieve(query: String, limit: Int, threadID: String?) async throws -> [ArchivalHit]
    /// Reloads the journal and re-indexes every round it holds.
    func rehydrate() async throws
    /// Chunk ids whose removal has not yet reached every index.
    func pendingRemovalIDs() async throws -> [String]
    /// Number of archived rounds.
    func count() async throws -> Int
    /// Whether the indexes already hold postings for the journal's rounds.
    ///
    /// Exists so `MemoryMaintenance` can skip a redundant re-index on a
    /// long-lived process whose indexes are known warm. Rehydration is
    /// idempotent, so a wrong answer here costs work rather than
    /// correctness — which is why the default is the conservative one.
    func indexesArePopulated() async throws -> Bool
}

extension ArchivalStore {
    /// Default: "I cannot tell", reported as `false` so the caller
    /// rehydrates.
    ///
    /// Answering `true` would be the dangerous default. ``BM25Retriever``
    /// and ``DenseRetriever`` are in-memory actors that do not survive a
    /// process restart while the journal does, so a conformer that cannot
    /// introspect its indexes must claim they are cold: an unnecessary
    /// rehydrate wastes a background pass, whereas a skipped one leaves
    /// the entire archive silently unretrievable until the next restart.
    public func indexesArePopulated() async throws -> Bool { false }
}

/// ``Retriever`` facade over an ``ArchivalStore``.
///
/// Exists so the archive drops into ``DefaultContextAssembler/retriever``,
/// ``HybridRetriever/retrievers``, ``RerankingRetriever``, and
/// `RetrievalEvalRunner` with zero new API — the archive is a corpus like
/// any other from the read side, and the eval harness that already
/// measures recall\@k over chunk ids measures it here unchanged.
public struct ArchivalRetriever: Retriever {
    /// Backing store.
    public let store: any ArchivalStore
    /// Optional thread scope. `nil` retrieves across every thread.
    public let threadID: String?

    /// Creates a retriever over `store`.
    public init(store: any ArchivalStore, threadID: String? = nil) {
        self.store = store
        self.threadID = threadID
    }

    /// Retrieves archived rounds as sources, in the store's order.
    public func retrieve(query: String, limit: Int) async throws -> [RetrievedSource] {
        try await store.retrieve(query: query, limit: limit, threadID: threadID)
            .map(\.retrievedSource)
    }
}
