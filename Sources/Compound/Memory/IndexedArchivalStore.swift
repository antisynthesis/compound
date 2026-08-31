import Foundation

/// ``ArchivalStore`` over the retrievers Compound already ships.
///
/// The store owns three things and no index of its own:
///
/// - a fan-out set of ``MutableTextIndex`` writers (normally one
///   ``BM25Index`` and one ``DenseIndex``),
/// - a read-side ``Retriever`` over those same actors (normally a
///   ``HybridRetriever``, so archival recall gets RRF fusion for free),
/// - an ``ArchivalJournal`` holding the rounds themselves.
///
/// ## Why the fan-out is the load-bearing part
///
/// ForgetEval's deletion results show lexical and vector indexes fail on
/// *different* inputs, not on the same ones with different reliability:
/// 32/39 versus 12/39 on prefix collisions, 21/38 versus 0/38 on
/// cross-lingual aliases. They are complementary, which means a delete
/// that reaches only one of them leaves the content retrievable through
/// the other — the user asked to be forgotten and was not. So
/// ``remove(chunkIDs:)`` fans out to every index, collects per-index
/// failures instead of short-circuiting on the first, and records what it
/// could not finish in ``ArchivalSnapshot/pendingRemovals`` so the next
/// pass retries it.
public actor IndexedArchivalStore: ArchivalStore {
    private let indexes: [any MutableTextIndex]
    private let reader: any Retriever
    private let journal: any ArchivalJournal
    private let onInconsistency: (@Sendable (String) -> Void)?

    private var snapshot = ArchivalSnapshot.empty
    private var byID: [String: ArchivedRound] = [:]
    private var loaded = false

    /// How much deeper than `limit` the reader is queried when a
    /// `threadID` scope is supplied, since scoping filters after the
    /// reader has already truncated.
    private static let threadScopeOverfetch = 4

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - indexes: Every index the archive writes to. A removal is only
    ///     complete when it has reached all of them.
    ///   - reader: Retriever used for reads. Point it at the same actors
    ///     the indexes wrap.
    ///   - journal: Durability for the round side table.
    ///   - onInconsistency: Called with a human-readable description when
    ///     the indexes and the journal disagree (a posting whose round is
    ///     gone). Torn state is reported, never fatal: crashing a run
    ///     because one stale posting survived is worse than skipping it.
    public init(
        indexes: [any MutableTextIndex],
        reader: any Retriever,
        journal: any ArchivalJournal,
        onInconsistency: (@Sendable (String) -> Void)? = nil
    ) {
        self.indexes = indexes
        self.reader = reader
        self.journal = journal
        self.onInconsistency = onInconsistency
    }

    // MARK: - Archive

    /// Indexes and records `rounds`.
    ///
    /// Writes are upserts on both sides — the index by
    /// ``DocumentChunk/id``, the journal by the same id — so archiving a
    /// backlog that overlaps one already archived changes nothing. That
    /// is required, not merely nice: ``BackgroundCompoundActivity``
    /// re-runs a deferred body from the top, and an archive that appended
    /// would double the corpus on every retry.
    public func archive(_ rounds: [ArchivedRound]) async throws {
        try await ensureLoaded()
        await retryPendingRemovals()
        guard !rounds.isEmpty else { return }

        // Deduplicate by id first so one call cannot ask an index to take
        // the same posting twice.
        var deduped: [ArchivedRound] = []
        var seen: Set<String> = []
        for round in rounds where seen.insert(round.id).inserted {
            deduped.append(round)
        }

        let chunks = deduped.map(\.chunk)
        for index in indexes {
            try await index.upsert(chunks)
        }

        for round in deduped {
            byID[round.id] = round
            snapshot.ordinals[round.messageIDs.first.map(\.uuidString) ?? round.id] = round.ordinal
            let next = snapshot.nextOrdinal[round.threadID] ?? 0
            snapshot.nextOrdinal[round.threadID] = max(next, round.ordinal + 1)
        }
        rebuildRounds()
        try await journal.save(snapshot)
    }

    /// The ordinal ledger for `threadID`, in the shape
    /// ``RoundBuilder/rounds(from:threadID:ordinals:nextOrdinal:)`` takes.
    ///
    /// Callers that build rounds must thread this through, otherwise
    /// ordinals restart at zero after a process restart and the archive
    /// mints a second copy of every round under new ids.
    public func ledger(threadID: String) async throws -> (ordinals: [UUID: Int], nextOrdinal: Int) {
        try await ensureLoaded()
        return snapshot.ledger(threadID: threadID)
    }

    // MARK: - Removal

    /// Removes `chunkIDs` from every index and from the journal.
    ///
    /// Fan-out is exhaustive: every index is asked, even after one has
    /// failed, because a partial delete that stops early leaves the most
    /// content behind. The journal entry is dropped either way — the
    /// user's intent is recorded — and any index that refused is named in
    /// the thrown ``MemoryError/partialRemoval(chunkIDs:failedIndexes:)``
    /// and retried on the next mutating call.
    ///
    /// The ordinal ledger is deliberately *not* pruned. It is a monotonic
    /// record of ordinal assignment, so re-archiving the same messages
    /// after a purge reproduces the same chunk id — which is what makes a
    /// purge independently verifiable rather than merely asserted.
    @discardableResult
    public func remove(chunkIDs: [String]) async throws -> Int {
        try await ensureLoaded()
        await retryPendingRemovals()
        guard !chunkIDs.isEmpty else { return 0 }

        var failedIndexes: [String] = []
        for index in indexes {
            do {
                _ = try await index.remove(ids: chunkIDs)
            } catch {
                failedIndexes.append(index.indexName)
                onInconsistency?("archival remove failed on index \(index.indexName): \(error)")
            }
        }

        var removed = 0
        for id in chunkIDs where byID.removeValue(forKey: id) != nil {
            removed += 1
        }
        rebuildRounds()

        if failedIndexes.isEmpty {
            let cleared = Set(chunkIDs)
            snapshot.pendingRemovals.removeAll { cleared.contains($0) }
            try await journal.save(snapshot)
            return removed
        }

        var pending = Set(snapshot.pendingRemovals)
        pending.formUnion(chunkIDs)
        snapshot.pendingRemovals = pending.sorted()
        try await journal.save(snapshot)
        throw MemoryError.partialRemoval(chunkIDs: chunkIDs, failedIndexes: failedIndexes)
    }

    /// Removes every round in `threadID`.
    @discardableResult
    public func removeThread(_ threadID: String) async throws -> [String] {
        try await ensureLoaded()
        let ids = snapshot.rounds.filter { $0.threadID == threadID }.map(\.id).sorted()
        guard !ids.isEmpty else { return [] }
        try await remove(chunkIDs: ids)
        return ids
    }

    /// Chunk ids whose removal has not yet reached every index.
    public func pendingRemovalIDs() async throws -> [String] {
        try await ensureLoaded()
        return snapshot.pendingRemovals
    }

    // MARK: - Read

    /// Retrieves archived rounds for `query`.
    ///
    /// The reader supplies the ordering; this method only re-joins each
    /// hit to its round and filters. A hit whose id is in an index but
    /// not in the journal is torn state — the removal reached the journal
    /// and not the index, or a journal was restored from an older
    /// snapshot — so it is reported through `onInconsistency` and
    /// skipped. Returning it would serve content the journal says is
    /// gone; trapping would take the run down over one stale posting.
    public func retrieve(query: String, limit: Int, threadID: String?) async throws -> [ArchivalHit] {
        try await ensureLoaded()
        guard limit > 0 else { return [] }
        // Thread scoping filters *after* the reader truncated, so ask for
        // more than the caller wants when a scope is in play.
        let fetch = threadID == nil
            ? limit
            : HybridRetriever.depth(limit: limit, multiplier: Self.threadScopeOverfetch)
        let sources = try await reader.retrieve(query: query, limit: fetch)
        var hits: [ArchivalHit] = []
        hits.reserveCapacity(min(sources.count, limit))
        for source in sources {
            guard let round = byID[source.id] else {
                onInconsistency?("archival retrieval returned id \(source.id) with no journal entry; skipping")
                continue
            }
            if let threadID, round.threadID != threadID { continue }
            hits.append(ArchivalHit(round: round, score: source.score))
            if hits.count == limit { break }
        }
        return hits
    }

    /// Looks a round up by chunk id.
    public func round(chunkID: String) async throws -> ArchivedRound? {
        try await ensureLoaded()
        return byID[chunkID]
    }

    /// Number of archived rounds.
    public func count() async throws -> Int {
        try await ensureLoaded()
        return snapshot.rounds.count
    }

    // MARK: - Rehydration

    /// Reloads the journal and re-indexes every round it holds.
    ///
    /// Required because ``BM25Retriever`` and ``DenseRetriever`` are
    /// in-memory actors: they do not survive a process restart, while the
    /// journal does. Idempotent — postings are upserted by id, so running
    /// it twice, or over indexes that are already warm, changes nothing.
    public func rehydrate() async throws {
        snapshot = try await journal.load()
        rebuildByID()
        loaded = true
        await retryPendingRemovals()
        guard !snapshot.rounds.isEmpty else { return }
        let chunks = snapshot.rounds.map(\.chunk)
        for index in indexes {
            try await index.upsert(chunks)
        }
    }

    /// Whether every index already holds a posting for a known round.
    ///
    /// Answered by probing the first journal round against every index:
    /// rehydration writes all rounds to all indexes in one pass, so a
    /// single missing posting means at least one index is cold and the
    /// whole re-index is warranted. An empty journal answers `true` —
    /// there is nothing to restore, so there is no work to schedule.
    public func indexesArePopulated() async throws -> Bool {
        try await ensureLoaded()
        guard let probe = snapshot.rounds.first else { return true }
        for index in indexes where await !index.contains(id: probe.id) {
            return false
        }
        return true
    }

    // MARK: - Internals

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        snapshot = try await journal.load()
        rebuildByID()
        loaded = true
    }

    /// Re-derives the id table from the snapshot. Last writer wins on a
    /// duplicated id, which a hand-edited journal can produce.
    private func rebuildByID() {
        byID = [:]
        byID.reserveCapacity(snapshot.rounds.count)
        for round in snapshot.rounds { byID[round.id] = round }
    }

    /// Re-derives the snapshot's round array from the id table.
    ///
    /// Sorted by (thread, ordinal, id) so the persisted file is a
    /// function of content alone: dictionary iteration order must never
    /// reach disk, or two runs that archived the same rounds would write
    /// different bytes.
    private func rebuildRounds() {
        snapshot.rounds = byID.values.sorted { a, b in
            if a.threadID != b.threadID { return a.threadID < b.threadID }
            if a.ordinal != b.ordinal { return a.ordinal < b.ordinal }
            return a.id < b.id
        }
    }

    /// Re-attempts removals that a previous fan-out could not finish.
    ///
    /// Deliberately non-throwing: it runs at the head of other people's
    /// calls, and an index that is still down must not fail an unrelated
    /// archive. The ids stay pending, and the next pass — or
    /// `MemoryMaintenance` — tries again.
    private func retryPendingRemovals() async {
        guard !snapshot.pendingRemovals.isEmpty else { return }
        let pending = snapshot.pendingRemovals
        var stillFailing = false
        for index in indexes {
            do {
                _ = try await index.remove(ids: pending)
            } catch {
                stillFailing = true
                onInconsistency?("pending archival removal still failing on index \(index.indexName): \(error)")
            }
        }
        guard !stillFailing else { return }
        snapshot.pendingRemovals = []
        for id in pending { byID.removeValue(forKey: id) }
        rebuildRounds()
        try? await journal.save(snapshot)
    }
}
