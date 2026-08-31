import Foundation

/// Process-local ``MemoryStore``. The right default for tests, demos,
/// and sessions whose memory need not outlive the process.
///
/// Backed by a `[String: Fact]` table plus a `[FactSlot: Set<String>]`
/// index, so slot-scoped reads — the reconciler's hot path, which asks
/// "what else is already in this slot" for every candidate — do not scan
/// the whole store.
///
/// Every returned collection is sorted before it leaves the actor.
/// Dictionary iteration order is unspecified and varies with hash seed
/// across processes; letting it reach a caller would make a golden
/// baseline flap between runs on the same machine.
public actor InMemoryFactStore: MemoryStore {
    private var table = FactTable()
    private let tokenizer: @Sendable (String) -> [String]
    private let scorer: SalienceScorer

    /// Creates an empty store.
    ///
    /// - Parameters:
    ///   - tokenizer: Tokenizer used by
    ///     ``similar(to:slot:threadID:limit:now:)``. Defaults to
    ///     ``BM25Retriever/defaultTokenize`` so lexical similarity here
    ///     matches lexical retrieval elsewhere in the package.
    ///   - scorer: Scorer used to realize ``MemoryOrder/salience``.
    public init(
        tokenizer: @escaping @Sendable (String) -> [String] = BM25Retriever.defaultTokenize,
        scorer: SalienceScorer = SalienceScorer()
    ) {
        self.tokenizer = tokenizer
        self.scorer = scorer
    }

    /// Number of stored records, live and retired.
    public var count: Int { table.count }

    /// Inserts or replaces `facts`, keyed on ``Fact/id``.
    public func upsert(_ facts: [Fact]) async throws {
        for fact in facts { table.insert(fact) }
    }

    /// Returns the record with `id`, or `nil`.
    public func fact(id: String) async throws -> Fact? { table.fact(id: id) }

    /// Runs a filtered, ordered, limited read. See ``MemoryQuery``.
    public func query(_ query: MemoryQuery) async throws -> [Fact] {
        table.query(query, scorer: scorer)
    }

    /// Ranks live facts by weighted-Jaccard lexical similarity.
    public func similar(to text: String, slot: FactSlot?, threadID: String?, limit: Int, now: Date) async throws -> [ScoredFact] {
        table.similar(to: text, slot: slot, threadID: threadID, limit: limit, now: now, tokenizer: tokenizer)
    }

    /// Bumps ``Fact/lastAccessedAt`` and ``Fact/accessCount``.
    public func touch(ids: [String], at instant: Date) async throws {
        table.touch(ids: ids, at: instant)
    }

    /// Retires records; returns how many actually changed.
    @discardableResult
    public func invalidate(ids: [String], validUntil: Date?, at instant: Date, reason: InvalidationReason) async throws -> Int {
        table.invalidate(ids: ids, validUntil: validUntil, at: instant)
    }

    /// Destructively removes records by id.
    @discardableResult
    public func purge(ids: [String]) async throws -> Int {
        table.purge(ids: ids)
    }

    /// Destructively removes every record matching `predicate`.
    @discardableResult
    public func purge(matching predicate: PurgePredicate) async throws -> [String] {
        table.purge(matching: predicate)
    }

    /// Every stored id, sorted ascending.
    public func allIDs() async throws -> [String] { table.allIDs }

    /// Destructively removes everything.
    public func removeAll() async throws { table.removeAll() }
}
