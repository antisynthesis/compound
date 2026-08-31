import Foundation

/// The three raw ingredients of a salience score, kept alongside the
/// score itself so a ranking can be explained rather than merely
/// observed. Values are the post-normalization components in `[0, 1]`.
public struct SalienceComponents: Sendable, Equatable, Codable {
    /// Exponential recency term derived from ``Fact/lastAccessedAt``.
    public let recency: Double
    /// Normalized ``Fact/importance``.
    public let importance: Double
    /// Query relevance supplied by the caller (0 when none was).
    public let relevance: Double

    /// Creates a component triple.
    public init(recency: Double, importance: Double, relevance: Double) {
        self.recency = recency
        self.importance = importance
        self.relevance = relevance
    }

    /// All-zero components, used where a ranking carries no salience
    /// interpretation (for example the lexical-similarity path).
    public static let zero = SalienceComponents(recency: 0, importance: 0, relevance: 0)
}

/// A fact with a computed rank.
public struct ScoredFact: Sendable, Equatable {
    /// The record.
    public let fact: Fact
    /// Combined score; higher ranks first.
    public let score: Double
    /// The components that produced `score`.
    public let components: SalienceComponents

    /// Creates a scored fact.
    public init(fact: Fact, score: Double, components: SalienceComponents) {
        self.fact = fact
        self.score = score
        self.components = components
    }
}

/// Why a record was retired. Recorded for the trace and for debugging
/// "where did my fact go"; it does not change the mechanics of
/// invalidation.
public enum InvalidationReason: String, Sendable, Codable, CaseIterable {
    /// A newer record in the same slot replaced it.
    case superseded
    /// The user asked for it to be forgotten.
    case retracted
    /// A TTL, an explicit expiry, or confidence decay ended it.
    case expired
    /// A per-thread cap pushed it out on salience.
    case evicted
    /// A compliance action retired it (see also the destructive
    /// ``MemoryStore/purge(matching:)``).
    case compliance
}

/// How ``MemoryStore/query(_:)`` orders its results. Every order breaks
/// ties on fact id ascending, so no ordering can leak dictionary
/// iteration order into a returned array.
public enum MemoryOrder: String, Sendable, Codable, CaseIterable {
    /// Recency × importance, as scored by ``SalienceScorer`` with no
    /// query relevance. This is the default because the read path wants
    /// "what matters" and only the assembler knows the query.
    case salience
    /// Most recently written first.
    case recordedAtDescending
    /// Most recently true first.
    case validFromDescending
    /// Fully deterministic id order; useful for snapshots and evals.
    case idAscending
}

/// A read against a ``MemoryStore``.
///
/// `now` is required and has no default. Every time-dependent decision
/// in the memory layer takes its instant from the caller so that an eval
/// replays byte for byte; a store that reached for `Date()` internally
/// would make its own results irreproducible.
public struct MemoryQuery: Sendable, Equatable, Codable {
    /// Restrict to one thread. `nil` searches every thread.
    public var threadID: String?
    /// Restrict to one (thread, subject, predicate) address.
    public var slot: FactSlot?
    /// Keep facts carrying at least one of these tags. An empty set
    /// applies no tag filter.
    public var tagsAny: Set<String>
    /// Minimum ``Fact/confidence``.
    public var minConfidence: Double
    /// Minimum ``MemoryOrigin/trustRank``. `nil` applies no trust floor.
    public var minimumOrigin: MemoryOrigin?
    /// Include retired and out-of-window records.
    public var includeInvalidated: Bool
    /// Ask a **validity-time** question at this instant instead of a
    /// liveness question at `now` — the "what did I believe in March"
    /// path.
    ///
    /// When set, the liveness filter switches from ``Fact/isLive(at:)``
    /// to ``Fact/wasValid(at:)``: a record whose window covered `asOf`
    /// is returned even though a later supersession has since retired
    /// it. Without that switch every historical answer would be empty,
    /// because supersession sets `invalidatedAt` on exactly the records
    /// a historical query is looking for.
    ///
    /// `recordedAt` is deliberately not filtered on. Transaction time
    /// answers a different question ("when did the system learn this")
    /// and mixing the two into one instant would make a batch
    /// consolidation — where several records share a `recordedAt` —
    /// silently return nothing for instants before the batch ran.
    ///
    /// Ignored entirely when ``includeInvalidated`` is `true`, which
    /// already disables the liveness filter.
    public var asOf: Date?
    /// The caller's clock instant.
    public var now: Date
    /// Maximum records returned.
    public var limit: Int
    /// Result ordering.
    public var order: MemoryOrder

    /// Creates a query.
    public init(
        now: Date,
        threadID: String? = nil,
        slot: FactSlot? = nil,
        tagsAny: Set<String> = [],
        minConfidence: Double = 0,
        minimumOrigin: MemoryOrigin? = nil,
        includeInvalidated: Bool = false,
        asOf: Date? = nil,
        limit: Int = 50,
        order: MemoryOrder = .salience
    ) {
        self.now = now
        self.threadID = threadID
        self.slot = slot
        self.tagsAny = tagsAny
        self.minConfidence = minConfidence
        self.minimumOrigin = minimumOrigin
        self.includeInvalidated = includeInvalidated
        self.asOf = asOf
        self.limit = limit
        self.order = order
    }
}

/// A destructive-deletion filter.
///
/// Every field is an **exact** match. There is no similarity field, no
/// substring field, and no id-prefix field, and that is a design
/// decision rather than an omission: purge is the GDPR-shaped path, and
/// semantic similarity is the wrong primitive for a compliance
/// operation. Substring or prefix matching on `subject` is *precisely*
/// the prefix-collision failure mode — a request to forget `"project"`
/// must not also erase `"project-atlas"`.
///
/// An entirely empty predicate matches nothing. "Delete everything" is
/// spelled ``MemoryStore/removeAll()``, so a partially-built predicate
/// cannot become an accidental wipe.
public struct PurgePredicate: Sendable, Equatable, Codable {
    /// Exact thread id.
    public var threadID: String?
    /// Exact subject, compared after ``MemoryText/normalize(_:)`` on
    /// both sides.
    public var subjectEquals: String?
    /// Match facts carrying at least one of these tags.
    public var tagsAny: Set<String>
    /// Match facts whose ``Fact/recordedAt`` is strictly before this.
    public var olderThan: Date?

    /// Creates a predicate.
    public init(threadID: String? = nil, subjectEquals: String? = nil, tagsAny: Set<String> = [], olderThan: Date? = nil) {
        self.threadID = threadID
        self.subjectEquals = subjectEquals
        self.tagsAny = tagsAny
        self.olderThan = olderThan
    }

    /// Whether the predicate constrains anything at all.
    public var isEmpty: Bool {
        threadID == nil && subjectEquals == nil && tagsAny.isEmpty && olderThan == nil
    }

    /// Whether `fact` satisfies every supplied constraint.
    func matches(_ fact: Fact) -> Bool {
        guard !isEmpty else { return false }
        if let threadID, fact.threadID != threadID { return false }
        if let subjectEquals, MemoryText.normalize(fact.subject) != MemoryText.normalize(subjectEquals) { return false }
        if !tagsAny.isEmpty, fact.tags.isDisjoint(with: tagsAny) { return false }
        if let olderThan, fact.recordedAt >= olderThan { return false }
        return true
    }
}

/// Storage boundary for ``Fact`` records.
///
/// Two implementations ship: ``InMemoryFactStore`` and
/// ``FileFactStore``. Both are actors and both are model-free — nothing
/// in this protocol ever calls a language model, which is what keeps the
/// read path at zero model calls per turn.
///
/// The store is also deliberately **embedding-free**. Similarity here is
/// lexical only (see ``similar(to:slot:threadID:limit:now:)``). Two
/// reasons: it makes the whole layer testable off-device with no
/// providers wired up, and independent replication work has shown a
/// memory system's headline result reversing on an embedder swap alone.
/// A store whose correctness depends on embedding quality is a store
/// whose correctness cannot be regression-tested; dense recall belongs
/// upstream in ``DenseRetriever``, where it is one fused signal among
/// several rather than the arbiter of what is remembered.
public protocol MemoryStore: Sendable {
    /// Inserts or replaces `facts`, keyed on ``Fact/id``.
    func upsert(_ facts: [Fact]) async throws
    /// Returns the record with `id`, or `nil`.
    func fact(id: String) async throws -> Fact?
    /// Runs a filtered, ordered, limited read.
    func query(_ query: MemoryQuery) async throws -> [Fact]
    /// Ranks live facts by lexical similarity to `text`.
    func similar(to text: String, slot: FactSlot?, threadID: String?, limit: Int, now: Date) async throws -> [ScoredFact]
    /// Bumps ``Fact/lastAccessedAt`` and ``Fact/accessCount``.
    func touch(ids: [String], at instant: Date) async throws
    /// Retires records. Recoverable — the data stays readable through
    /// ``MemoryQuery/includeInvalidated`` and ``MemoryQuery/asOf``.
    @discardableResult
    func invalidate(ids: [String], validUntil: Date?, at instant: Date, reason: InvalidationReason) async throws -> Int
    /// Destructively removes records by id.
    @discardableResult
    func purge(ids: [String]) async throws -> Int
    /// Destructively removes every record matching `predicate`.
    @discardableResult
    func purge(matching predicate: PurgePredicate) async throws -> [String]
    /// Every stored id, sorted ascending.
    func allIDs() async throws -> [String]
    /// Destructively removes everything.
    func removeAll() async throws
}

// MARK: - Shared implementation

/// The filtering, ordering, and mutation semantics both bundled stores
/// share.
///
/// Factored into a value type so ``InMemoryFactStore`` and
/// ``FileFactStore`` cannot drift apart: a durability bug and a
/// semantics bug should never be the same bug. Every method that returns
/// a collection sorts before returning — dictionary iteration order is
/// never allowed to reach a caller.
struct FactTable: Sendable {
    private(set) var facts: [String: Fact] = [:]
    private(set) var slotIndex: [FactSlot: Set<String>] = [:]

    init(facts: [Fact] = []) {
        for fact in facts { insert(fact) }
    }

    var count: Int { facts.count }

    mutating func insert(_ fact: Fact) {
        if let existing = facts[fact.id], existing.slot != fact.slot {
            slotIndex[existing.slot]?.remove(fact.id)
            if slotIndex[existing.slot]?.isEmpty == true { slotIndex.removeValue(forKey: existing.slot) }
        }
        facts[fact.id] = fact
        slotIndex[fact.slot, default: []].insert(fact.id)
    }

    @discardableResult
    mutating func remove(id: String) -> Bool {
        guard let existing = facts.removeValue(forKey: id) else { return false }
        slotIndex[existing.slot]?.remove(id)
        if slotIndex[existing.slot]?.isEmpty == true { slotIndex.removeValue(forKey: existing.slot) }
        return true
    }

    mutating func removeAll() {
        facts.removeAll()
        slotIndex.removeAll()
    }

    func fact(id: String) -> Fact? { facts[id] }

    var allIDs: [String] { facts.keys.sorted() }

    /// Candidate set for a query, honoring the slot index when present.
    private func candidates(slot: FactSlot?) -> [Fact] {
        guard let slot else { return Array(facts.values) }
        guard let ids = slotIndex[slot] else { return [] }
        return ids.compactMap { facts[$0] }
    }

    /// Applies the documented filter order, then the ordering, then the
    /// limit. The order of the filters is fixed and part of the
    /// contract: thread, slot, tags, confidence and trust, liveness.
    func query(_ q: MemoryQuery, scorer: SalienceScorer) -> [Fact] {
        var filtered = candidates(slot: q.slot).filter { fact in
            if let threadID = q.threadID, fact.threadID != threadID { return false }
            if !q.tagsAny.isEmpty, fact.tags.isDisjoint(with: q.tagsAny) { return false }
            if fact.confidence < q.minConfidence { return false }
            if let minimumOrigin = q.minimumOrigin, fact.origin.trustRank < minimumOrigin.trustRank { return false }
            if !q.includeInvalidated {
                // `asOf` asks a validity-time question and deliberately
                // survives supersession; without it the filter is the
                // full liveness predicate at `now`.
                if let asOf = q.asOf {
                    if !fact.wasValid(at: asOf) { return false }
                } else if !fact.isLive(at: q.now) {
                    return false
                }
            }
            return true
        }
        filtered = FactTable.order(filtered, by: q.order, now: q.now, scorer: scorer)
        guard q.limit >= 0 else { return filtered }
        return Array(filtered.prefix(q.limit))
    }

    /// Sorts `facts`, breaking every tie on id ascending.
    static func order(_ facts: [Fact], by order: MemoryOrder, now: Date, scorer: SalienceScorer) -> [Fact] {
        switch order {
        case .idAscending:
            return facts.sorted { $0.id < $1.id }
        case .recordedAtDescending:
            return facts.sorted { a, b in
                a.recordedAt == b.recordedAt ? a.id < b.id : a.recordedAt > b.recordedAt
            }
        case .validFromDescending:
            return facts.sorted { a, b in
                a.validFrom == b.validFrom ? a.id < b.id : a.validFrom > b.validFrom
            }
        case .salience:
            // No query text is available at the store boundary, so the
            // relevance term is uniformly zero and the ranking reduces
            // to recency × importance. The assembler, which does know
            // the query, re-scores with real relevance.
            return scorer.score(facts, relevance: [:], now: now).map(\.fact)
        }
    }

    /// Weighted-Jaccard (Ruzicka) similarity over token multisets:
    /// `Σ min(a, b) / Σ max(a, b)` across the union of terms. Repeated
    /// terms count, so a fact that repeats the query's key term scores
    /// above one that mentions it once — and the measure stays in
    /// `[0, 1]` with an exact restatement scoring 1.
    static func similarity(_ a: [String: Int], _ b: [String: Int]) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        var intersection = 0
        var union = 0
        for (term, countA) in a {
            let countB = b[term] ?? 0
            intersection += min(countA, countB)
            union += max(countA, countB)
        }
        for (term, countB) in b where a[term] == nil {
            union += countB
        }
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    static func counts(_ tokens: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for t in tokens { out[t, default: 0] += 1 }
        return out
    }

    func similar(
        to text: String,
        slot: FactSlot?,
        threadID: String?,
        limit: Int,
        now: Date,
        tokenizer: (String) -> [String]
    ) -> [ScoredFact] {
        guard limit > 0 else { return [] }
        let queryCounts = FactTable.counts(tokenizer(text))
        guard !queryCounts.isEmpty else { return [] }
        var scored: [ScoredFact] = []
        for fact in candidates(slot: slot) {
            if let threadID, fact.threadID != threadID { continue }
            guard fact.isLive(at: now) else { continue }
            let score = FactTable.similarity(queryCounts, FactTable.counts(tokenizer(fact.text)))
            guard score > 0 else { continue }
            scored.append(ScoredFact(
                fact: fact,
                score: score,
                components: SalienceComponents(recency: 0, importance: 0, relevance: score)
            ))
        }
        scored.sort { a, b in
            a.score == b.score ? a.fact.id < b.fact.id : a.score > b.score
        }
        return Array(scored.prefix(limit))
    }

    /// Returns the ids actually changed.
    @discardableResult
    mutating func touch(ids: [String], at instant: Date) -> [String] {
        var changed: [String] = []
        for id in Set(ids).sorted() {
            guard let fact = facts[id] else { continue }
            insert(fact.with(
                lastAccessedAt: max(fact.lastAccessedAt, instant),
                accessCount: fact.accessCount + 1
            ))
            changed.append(id)
        }
        return changed
    }

    /// Retires the named records. Idempotent: a record that already
    /// carries an ``Fact/invalidatedAt`` is skipped, so re-running a
    /// deferred background pass cannot rewrite history with a second
    /// timestamp.
    @discardableResult
    mutating func invalidate(ids: [String], validUntil: Date?, at instant: Date) -> Int {
        var changed = 0
        for id in Set(ids).sorted() {
            guard let fact = facts[id], fact.invalidatedAt == nil else { continue }
            // A supplied `validUntil` overwrites; omitting it leaves the
            // world-time window alone. Supersession supplies it (the
            // incoming record's `validFrom`); a plain retraction does not.
            let window: Date? = validUntil ?? fact.validUntil
            insert(fact.with(
                validUntil: Optional(window),
                invalidatedAt: Optional(instant)
            ))
            changed += 1
        }
        return changed
    }

    @discardableResult
    mutating func purge(ids: [String]) -> Int {
        var removed = 0
        for id in Set(ids).sorted() where remove(id: id) { removed += 1 }
        return removed
    }

    @discardableResult
    mutating func purge(matching predicate: PurgePredicate) -> [String] {
        let hits = facts.values.filter { predicate.matches($0) }.map(\.id).sorted()
        for id in hits { remove(id: id) }
        return hits
    }
}
