import Foundation

/// The default, model-free router: a fixed ladder of gates evaluated in
/// a fixed order, stopping at the first one that fires.
///
/// The whole point of this type is that it is a **pure function** of
/// (candidates, store contents, `now`). No clock read, no model call, no
/// dictionary-order dependence, and no gate that can be reached twice
/// for the same input. That is what lets a memory regression be a
/// diffable baseline rather than a re-run of a stochastic pipeline.
///
/// ## The gate ladder
///
/// 1. **Trust.** An origin below ``minimumOrigin`` is rejected outright,
///    and a non-``MemoryOrigin/userStated`` candidate needs
///    ``untrustedMinConfidence`` rather than ``minConfidence``.
/// 2. **Confidence floor.** Below ``minConfidence`` is rejected.
/// 3. **Retraction.** A candidate tagged ``retractionTag`` deletes the
///    newest live record in its slot.
/// 4. **Exact duplicate.** A live record with the candidate's derived id
///    is reconfirmed, not rewritten.
/// 5. **Slot contradiction.** A live record in the slot with different
///    text is resolved by a total order on (validity instant,
///    confidence, origin trust).
/// 6. **Otherwise** the candidate is new and is added.
///
/// ## On the trust gate
///
/// Reported memory-poisoning success rates against agent memory sit in
/// the 34–67% range, and the most vulnerable configuration is the one
/// that writes freely and then injects what it wrote back into the
/// prompt. Holding non-user-stated writes to a 0.9 confidence bar makes
/// the cheap end of that attack surface narrower.
///
/// It is worth being blunt about what this is: **defence in depth and
/// debuggability, not a validated mitigation.** An attacker who can get
/// the user to type a sentence still earns `userStated` trust, and no
/// confidence threshold helps there. The gate's real value is that every
/// rejection is recorded with a rationale, so a poisoned store is
/// forensically legible after the fact.
public struct DeterministicReconciler: FactReconciling {
    /// Identifier recorded in ``MemoryDecision/decidedBy``.
    public let name = "deterministic.v1"

    /// Confidence floor for a ``MemoryOrigin/userStated`` candidate.
    public let minConfidence: Double
    /// Confidence floor for every other origin.
    public let untrustedMinConfidence: Double
    /// Lowest origin trust rank admitted at all.
    public let minimumOrigin: MemoryOrigin
    /// Lexical similarity at or above which a stored record is treated as
    /// "about the same thing" for target selection.
    public let similarityThreshold: Double
    /// How many similarity candidates to pull from the store per
    /// candidate. Bounds the read cost of a contradiction check.
    public let similarityCandidateLimit: Int
    /// Tag that marks a candidate as a retraction request.
    public let retractionTag: String

    /// Creates a reconciler.
    ///
    /// - Parameters:
    ///   - minConfidence: Admission floor for user-stated candidates.
    ///   - untrustedMinConfidence: Admission floor for everything else.
    ///   - minimumOrigin: Lowest admitted origin. The default admits
    ///     ``MemoryOrigin/derived`` (rank 0), i.e. no trust floor beyond
    ///     the confidence bar; raise it to shut a whole origin class out.
    ///   - similarityThreshold: Similarity at or above which a stored
    ///     record is preferred as a contradiction target.
    ///   - similarityCandidateLimit: Similarity fan-out per candidate.
    ///   - retractionTag: Tag that means "forget this".
    public init(
        minConfidence: Double = 0.5,
        untrustedMinConfidence: Double = 0.9,
        minimumOrigin: MemoryOrigin = .derived,
        similarityThreshold: Double = 0.72,
        similarityCandidateLimit: Int = 10,
        retractionTag: String = "retraction"
    ) {
        precondition(minConfidence >= 0 && minConfidence <= 1, "minConfidence must be in [0, 1]")
        precondition(untrustedMinConfidence >= 0 && untrustedMinConfidence <= 1, "untrustedMinConfidence must be in [0, 1]")
        precondition(similarityCandidateLimit > 0, "similarityCandidateLimit must be positive")
        self.minConfidence = minConfidence
        self.untrustedMinConfidence = untrustedMinConfidence
        self.minimumOrigin = minimumOrigin
        self.similarityThreshold = similarityThreshold
        self.similarityCandidateLimit = similarityCandidateLimit
        self.retractionTag = retractionTag
    }

    /// Routes every candidate, in input order.
    ///
    /// Candidates are evaluated against the **pre-batch** store state:
    /// nothing here writes, so two candidates in one batch cannot see
    /// each other's effects. That is deliberate — a batch whose outcome
    /// depended on intra-batch ordering effects would not be replayable,
    /// and ``Reconciliation/apply(_:to:now:)`` resolves the resulting
    /// overlaps in one place instead.
    public func reconcile(candidates: [FactCandidate], against store: any MemoryStore, now: Date) async throws -> [MemoryDecision] {
        var decisions: [MemoryDecision] = []
        decisions.reserveCapacity(candidates.count)
        for candidate in candidates {
            decisions.append(try await decide(candidate, against: store, now: now))
        }
        return decisions
    }

    // MARK: - The ladder

    private func decide(_ candidate: FactCandidate, against store: any MemoryStore, now: Date) async throws -> MemoryDecision {
        // Gate 1 — trust. Evaluated before everything else, including
        // retraction: an untrusted "forget X" is an *attack shape*, so a
        // low-trust retraction must be rejected as low trust rather than
        // honoured as a retraction.
        if candidate.origin.trustRank < minimumOrigin.trustRank {
            return noop(candidate, .lowerTrustRejected)
        }
        if candidate.origin != .userStated, candidate.confidence < untrustedMinConfidence {
            return noop(candidate, .lowerTrustRejected)
        }

        // Gate 2 — confidence floor.
        if candidate.confidence < minConfidence {
            return noop(candidate, .belowConfidenceFloor)
        }

        let slot = FactSlot(
            threadID: candidate.threadID,
            subject: candidate.subject,
            predicate: candidate.predicate
        )
        let liveInSlot = try await store.query(MemoryQuery(
            now: now,
            threadID: candidate.threadID,
            slot: slot,
            includeInvalidated: false,
            limit: Self.slotFanout,
            order: .validFromDescending
        ))

        // Gate 3 — retraction.
        if candidate.tags.contains(retractionTag) {
            guard let target = Self.newestByValidFrom(liveInSlot) else {
                return noop(candidate, .retractionRequested)
            }
            return MemoryDecision(
                operation: .delete,
                candidate: candidate,
                targetFactID: target.id,
                rationale: .retractionRequested,
                decidedBy: name
            )
        }

        // Gate 4 — exact duplicate. Id derivation already folds case,
        // spacing, and Unicode form, so "restated differently" lands
        // here rather than in the contradiction gate.
        let candidateID = candidate.derivedFactID
        if let existing = try await store.fact(id: candidateID), existing.isLive(at: now) {
            return MemoryDecision(
                operation: .noop,
                candidate: candidate,
                targetFactID: existing.id,
                rationale: .duplicateOfCurrent,
                decidedBy: name
            )
        }

        // Gate 5 — slot contradiction.
        let conflicting = liveInSlot.filter { $0.id != candidateID }
        if !conflicting.isEmpty {
            let ranked = try await rankTargets(conflicting, for: candidate, in: store, now: now)
            // `ranked` is non-empty because `conflicting` is.
            let incumbent = ranked[0]
            return resolve(candidate: candidate, against: incumbent)
        }

        // Gate 6 — new claim.
        return MemoryDecision(
            operation: .add,
            candidate: candidate,
            rationale: .noSimilarFact,
            decidedBy: name
        )
    }

    /// The contradiction total order. Every comparison is on a stored
    /// scalar, and the branches are mutually exclusive by construction —
    /// each one is guarded by the negation of every branch above it — so
    /// exactly one fires for any input pair and the result is a function,
    /// not a search.
    ///
    /// Validity instant comes first because a memory system's job is to
    /// track what is true *now*; confidence and trust only break a tie in
    /// world time, where "which of these two simultaneous claims do I
    /// believe" is the only question left.
    private func resolve(candidate: FactCandidate, against incumbent: Fact) -> MemoryDecision {
        func update(_ rationale: MemoryRationale) -> MemoryDecision {
            MemoryDecision(
                operation: .update,
                candidate: candidate,
                targetFactID: incumbent.id,
                rationale: rationale,
                decidedBy: name
            )
        }
        func keep(_ rationale: MemoryRationale) -> MemoryDecision {
            MemoryDecision(
                operation: .noop,
                candidate: candidate,
                targetFactID: incumbent.id,
                rationale: rationale,
                decidedBy: name
            )
        }

        if candidate.validFrom > incumbent.validFrom { return update(.newerWins) }
        if candidate.validFrom < incumbent.validFrom { return keep(.staleCandidate) }
        if candidate.confidence > incumbent.confidence { return update(.higherConfidenceWins) }
        if candidate.confidence < incumbent.confidence { return keep(.higherConfidenceWins) }
        if candidate.origin.trustRank > incumbent.origin.trustRank { return update(.higherTrustWins) }
        if candidate.origin.trustRank < incumbent.origin.trustRank { return keep(.higherTrustWins) }
        // Indistinguishable on every axis: the incumbent stays. Churning
        // the store on a tie would rewrite `recordedAt` on every restated
        // fact and make supersession chains grow without new information.
        return keep(.slotContradiction)
    }

    /// Orders the conflicting records so the "most about the same thing"
    /// one is first.
    ///
    /// Lexical similarity is consulted here rather than used as a gate:
    /// two live records in one slot are a contradiction whether or not
    /// they share vocabulary, so filtering by ``similarityThreshold``
    /// would silently drop real conflicts. What the threshold does is
    /// decide *which* incumbent a candidate supersedes when a slot holds
    /// several — the one it is actually restating, before the merely
    /// newest one.
    private func rankTargets(
        _ conflicting: [Fact],
        for candidate: FactCandidate,
        in store: any MemoryStore,
        now: Date
    ) async throws -> [Fact] {
        let slot = FactSlot(
            threadID: candidate.threadID,
            subject: candidate.subject,
            predicate: candidate.predicate
        )
        let similar = try await store.similar(
            to: candidate.text,
            slot: slot,
            threadID: candidate.threadID,
            limit: similarityCandidateLimit,
            now: now
        )
        var scores: [String: Double] = [:]
        for hit in similar { scores[hit.fact.id] = hit.score }
        return conflicting.sorted { a, b in
            let sa = scores[a.id] ?? 0
            let sb = scores[b.id] ?? 0
            let aNear = sa >= similarityThreshold
            let bNear = sb >= similarityThreshold
            if aNear != bNear { return aNear }
            if sa != sb { return sa > sb }
            if a.validFrom != b.validFrom { return a.validFrom > b.validFrom }
            return a.id < b.id
        }
    }

    // MARK: - Helpers

    /// Read fan-out for a single-slot query. A slot holding more than
    /// this many simultaneously live records is already pathological;
    /// the cap keeps one bad thread from turning every write into a full
    /// table scan.
    static let slotFanout = 64

    private func noop(_ candidate: FactCandidate, _ rationale: MemoryRationale) -> MemoryDecision {
        MemoryDecision(operation: .noop, candidate: candidate, rationale: rationale, decidedBy: name)
    }

    /// Newest by ``Fact/validFrom``, ties broken on id ascending.
    static func newestByValidFrom(_ facts: [Fact]) -> Fact? {
        facts.min { a, b in
            a.validFrom == b.validFrom ? a.id < b.id : a.validFrom > b.validFrom
        }
    }
}

// MARK: - Bounded option lists

/// Builds the small, deterministic candidate list a model-backed router
/// is allowed to choose from.
///
/// Shared between ``DeterministicReconciler`` and ``ModelMutationHook``
/// so the two cannot disagree about what "the plausible targets" are.
/// The list is capped hard: a router that can name any stored id is a
/// router that can be talked into deleting anything, whereas one that
/// can only return an index into five pre-selected records has a
/// failure mode bounded by the selection logic in front of it.
enum MemoryCandidateOptions {
    /// Returns at most `maxOptions` existing records the candidate might
    /// legitimately be about, best first.
    ///
    /// Ordering: lexical similarity descending, then validity instant
    /// descending, then id ascending. Live records in the candidate's own
    /// slot are always included even at zero similarity — a contradiction
    /// with no shared vocabulary ("I live in Paris" → "I moved to Osaka")
    /// is exactly the case a router is being asked about.
    static func options(
        for candidate: FactCandidate,
        in store: any MemoryStore,
        similarityCandidateLimit: Int,
        maxOptions: Int,
        now: Date
    ) async throws -> [Fact] {
        guard maxOptions > 0 else { return [] }
        let slot = FactSlot(
            threadID: candidate.threadID,
            subject: candidate.subject,
            predicate: candidate.predicate
        )
        let live = try await store.query(MemoryQuery(
            now: now,
            threadID: candidate.threadID,
            slot: slot,
            includeInvalidated: false,
            limit: DeterministicReconciler.slotFanout,
            order: .validFromDescending
        ))
        let similar = try await store.similar(
            to: candidate.text,
            slot: slot,
            threadID: candidate.threadID,
            limit: similarityCandidateLimit,
            now: now
        )
        var scores: [String: Double] = [:]
        var pool: [String: Fact] = [:]
        for hit in similar {
            scores[hit.fact.id] = hit.score
            pool[hit.fact.id] = hit.fact
        }
        for fact in live where pool[fact.id] == nil { pool[fact.id] = fact }

        let ordered = pool.values.sorted { a, b in
            let sa = scores[a.id] ?? 0
            let sb = scores[b.id] ?? 0
            if sa != sb { return sa > sb }
            if a.validFrom != b.validFrom { return a.validFrom > b.validFrom }
            return a.id < b.id
        }
        return Array(ordered.prefix(maxOptions))
    }

    /// One-line human-readable summary of a record, for a router prompt.
    static func summary(of fact: Fact, maxCharacters: Int = 160) -> String {
        let line = "\(fact.subject) \(fact.predicate): \(fact.text)"
        guard line.count > maxCharacters else { return line }
        return String(line.prefix(maxCharacters)) + "…"
    }
}
