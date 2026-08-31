import Foundation
import Testing
@testable import Compound

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private func days(_ n: Double) -> TimeInterval { n * 86_400 }
private let thread = "t1"
private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

// MARK: - Fixtures

private func candidate(
    subject: String = "user",
    predicate: String = "location",
    text: String,
    origin: MemoryOrigin = .userStated,
    confidence: Double = 0.9,
    importance: Int = 5,
    tags: Set<String> = [],
    validFrom: Date = epoch
) -> FactCandidate {
    FactCandidate(
        threadID: thread,
        subject: subject,
        predicate: predicate,
        text: text,
        origin: origin,
        confidence: confidence,
        importance: importance,
        tags: tags,
        sourceMessageIDs: [sourceID],
        validFrom: validFrom,
        extractor: "test.v1"
    )
}

private func storedFact(
    subject: String = "user",
    predicate: String = "location",
    text: String,
    origin: MemoryOrigin = .userStated,
    confidence: Double = 0.9,
    importance: Int = 5,
    tags: Set<String> = [],
    validFrom: Date = epoch,
    recordedAt: Date = epoch
) -> Fact {
    Fact(
        threadID: thread,
        subject: subject,
        predicate: predicate,
        text: text,
        origin: origin,
        confidence: confidence,
        importance: importance,
        tags: tags,
        provenance: FactProvenance(threadID: thread, messageIDs: [sourceID], extractor: "test.v1"),
        validFrom: validFrom,
        recordedAt: recordedAt,
        lastAccessedAt: recordedAt
    )
}

/// A store that forwards everything to an ``InMemoryFactStore`` and
/// records whether either destructive entry point was ever reached.
/// ``Reconciliation/apply(_:to:now:)`` and ``ForgettingSweep`` must both
/// leave `purgeCalls` at zero — invalidation and destruction are
/// deliberately different code paths.
actor PurgeSpyFactStore: MemoryStore {
    private let inner = InMemoryFactStore()
    private(set) var purgeCalls = 0
    private(set) var upsertCalls = 0
    private(set) var invalidateCalls: [(ids: [String], validUntil: Date?, reason: InvalidationReason)] = []
    private(set) var touchedIDs: [String] = []

    func upsert(_ facts: [Fact]) async throws {
        upsertCalls += 1
        try await inner.upsert(facts)
    }

    func fact(id: String) async throws -> Fact? { try await inner.fact(id: id) }
    func query(_ query: MemoryQuery) async throws -> [Fact] { try await inner.query(query) }

    func similar(to text: String, slot: FactSlot?, threadID: String?, limit: Int, now: Date) async throws -> [ScoredFact] {
        try await inner.similar(to: text, slot: slot, threadID: threadID, limit: limit, now: now)
    }

    func touch(ids: [String], at instant: Date) async throws {
        touchedIDs.append(contentsOf: ids)
        try await inner.touch(ids: ids, at: instant)
    }

    @discardableResult
    func invalidate(ids: [String], validUntil: Date?, at instant: Date, reason: InvalidationReason) async throws -> Int {
        invalidateCalls.append((ids, validUntil, reason))
        return try await inner.invalidate(ids: ids, validUntil: validUntil, at: instant, reason: reason)
    }

    @discardableResult
    func purge(ids: [String]) async throws -> Int {
        purgeCalls += 1
        return try await inner.purge(ids: ids)
    }

    @discardableResult
    func purge(matching predicate: PurgePredicate) async throws -> [String] {
        purgeCalls += 1
        return try await inner.purge(matching: predicate)
    }

    func allIDs() async throws -> [String] { try await inner.allIDs() }
    func removeAll() async throws { try await inner.removeAll() }
}

// MARK: - Gates

@Suite("ReconcilerGates")
struct ReconcilerGateTests {
    @Test("an origin below the trust floor is rejected outright")
    func trustFloor() async throws {
        let store = InMemoryFactStore()
        let reconciler = DeterministicReconciler(minimumOrigin: .toolOutput)
        let decisions = try await reconciler.reconcile(
            candidates: [candidate(text: "Paris", origin: .derived, confidence: 1.0)],
            against: store,
            now: epoch
        )
        #expect(decisions.count == 1)
        #expect(decisions[0].operation == .noop)
        #expect(decisions[0].rationale == .lowerTrustRejected)
        #expect(decisions[0].decidedBy == "deterministic.v1")
    }

    @Test("a non-user-stated candidate needs the higher confidence bar")
    func untrustedConfidenceBar() async throws {
        let store = InMemoryFactStore()
        let reconciler = DeterministicReconciler()
        // 0.8 clears minConfidence (0.5) but not untrustedMinConfidence (0.9).
        let low = try await reconciler.reconcile(
            candidates: [candidate(text: "Paris", origin: .assistantStated, confidence: 0.8)],
            against: store, now: epoch
        )
        #expect(low[0].rationale == .lowerTrustRejected)

        let high = try await reconciler.reconcile(
            candidates: [candidate(text: "Paris", origin: .assistantStated, confidence: 0.95)],
            against: store, now: epoch
        )
        #expect(high[0].operation == .add)
    }

    @Test("a user-stated candidate below the confidence floor is rejected")
    func confidenceFloor() async throws {
        let store = InMemoryFactStore()
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "Paris", confidence: 0.3)],
            against: store, now: epoch
        )
        #expect(decisions[0].operation == .noop)
        #expect(decisions[0].rationale == .belowConfidenceFloor)
    }

    @Test("gate order: a low-trust retraction is rejected as low trust, not honoured as a retraction")
    func trustGateBeatsRetraction() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([storedFact(text: "Paris")])
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "Paris", origin: .retrievedDocument, confidence: 0.6, tags: ["retraction"])],
            against: store, now: epoch
        )
        #expect(decisions[0].operation == .noop)
        #expect(decisions[0].rationale == .lowerTrustRejected)
        // The store is untouched: nothing was deleted.
        let live = try await store.query(MemoryQuery(now: epoch))
        #expect(live.count == 1)
    }

    @Test("a retraction with nothing to retract is a no-op")
    func retractionWithNoTarget() async throws {
        let store = InMemoryFactStore()
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "Paris", tags: ["retraction"])],
            against: store, now: epoch
        )
        #expect(decisions[0].operation == .noop)
        #expect(decisions[0].rationale == .retractionRequested)
        #expect(decisions[0].targetFactID == nil)
    }

    @Test("a retraction targets the newest live record in the slot")
    func retractionTargetsNewest() async throws {
        let store = InMemoryFactStore()
        let old = storedFact(text: "Paris", validFrom: epoch)
        let new = storedFact(text: "Osaka", validFrom: epoch.addingTimeInterval(days(1)))
        try await store.upsert([old, new])
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "Osaka", tags: ["retraction"], validFrom: epoch.addingTimeInterval(days(2)))],
            against: store, now: epoch.addingTimeInterval(days(3))
        )
        #expect(decisions[0].operation == .delete)
        #expect(decisions[0].rationale == .retractionRequested)
        #expect(decisions[0].targetFactID == new.id)
    }

    @Test("an exact restatement of a live fact is a reconfirmation, not a rewrite")
    func exactDuplicate() async throws {
        let store = InMemoryFactStore()
        let existing = storedFact(text: "I live in Paris")
        try await store.upsert([existing])
        // Different case and spacing collapse onto the same derived id.
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "I  live in  PARIS", validFrom: epoch.addingTimeInterval(days(1)))],
            against: store, now: epoch.addingTimeInterval(days(1))
        )
        #expect(decisions[0].operation == .noop)
        #expect(decisions[0].rationale == .duplicateOfCurrent)
        #expect(decisions[0].targetFactID == existing.id)
    }

    @Test("a duplicate of an invalidated fact is not a duplicate")
    func duplicateOfRetiredFactIsNotADuplicate() async throws {
        let store = InMemoryFactStore()
        let existing = storedFact(text: "Paris")
        try await store.upsert([existing])
        try await store.invalidate(ids: [existing.id], validUntil: nil, at: epoch, reason: .retracted)
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "Paris")],
            against: store, now: epoch
        )
        #expect(decisions[0].operation == .add)
        #expect(decisions[0].rationale == .noSimilarFact)
    }

    @Test("a claim in an empty slot is added")
    func newClaimIsAdded() async throws {
        let store = InMemoryFactStore()
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "Paris")], against: store, now: epoch
        )
        #expect(decisions[0].operation == .add)
        #expect(decisions[0].rationale == .noSimilarFact)
        #expect(decisions[0].targetFactID == nil)
    }
}

// MARK: - Contradiction total order

@Suite("ReconcilerContradiction")
struct ReconcilerContradictionTests {
    /// Runs one candidate against one incumbent and returns the decision.
    private func resolve(
        incumbent: Fact,
        candidate c: FactCandidate,
        now: Date = epoch.addingTimeInterval(days(10))
    ) async throws -> MemoryDecision {
        let store = InMemoryFactStore()
        try await store.upsert([incumbent])
        return try await DeterministicReconciler().reconcile(candidates: [c], against: store, now: now)[0]
    }

    @Test("a newer validity instant supersedes")
    func newerWins() async throws {
        let d = try await resolve(
            incumbent: storedFact(text: "Paris", validFrom: epoch),
            candidate: candidate(text: "Osaka", validFrom: epoch.addingTimeInterval(days(1)))
        )
        #expect(d.operation == .update)
        #expect(d.rationale == .newerWins)
    }

    @Test("an older validity instant is stale news")
    func staleCandidate() async throws {
        let d = try await resolve(
            incumbent: storedFact(text: "Paris", validFrom: epoch.addingTimeInterval(days(2))),
            candidate: candidate(text: "Osaka", validFrom: epoch)
        )
        #expect(d.operation == .noop)
        #expect(d.rationale == .staleCandidate)
    }

    @Test("at the same instant, higher confidence supersedes")
    func higherConfidenceWins() async throws {
        let d = try await resolve(
            incumbent: storedFact(text: "Paris", confidence: 0.7),
            candidate: candidate(text: "Osaka", confidence: 0.95)
        )
        #expect(d.operation == .update)
        #expect(d.rationale == .higherConfidenceWins)
    }

    @Test("at the same instant, lower confidence loses")
    func lowerConfidenceLoses() async throws {
        let d = try await resolve(
            incumbent: storedFact(text: "Paris", confidence: 0.95),
            candidate: candidate(text: "Osaka", confidence: 0.7)
        )
        #expect(d.operation == .noop)
        #expect(d.rationale == .higherConfidenceWins)
    }

    @Test("at equal instant and confidence, higher origin trust supersedes")
    func higherTrustWins() async throws {
        let d = try await resolve(
            incumbent: storedFact(text: "Paris", origin: .assistantStated, confidence: 0.95),
            candidate: candidate(text: "Osaka", origin: .userStated, confidence: 0.95)
        )
        #expect(d.operation == .update)
        #expect(d.rationale == .higherTrustWins)
    }

    @Test("at equal instant and confidence, lower origin trust loses")
    func lowerTrustLoses() async throws {
        let d = try await resolve(
            incumbent: storedFact(text: "Paris", origin: .userStated, confidence: 0.95),
            candidate: candidate(text: "Osaka", origin: .assistantStated, confidence: 0.95)
        )
        #expect(d.operation == .noop)
        #expect(d.rationale == .higherTrustWins)
    }

    @Test("a full tie keeps the incumbent")
    func fullTie() async throws {
        let d = try await resolve(
            incumbent: storedFact(text: "Paris", confidence: 0.9),
            candidate: candidate(text: "Osaka", confidence: 0.9)
        )
        #expect(d.operation == .noop)
        #expect(d.rationale == .slotContradiction)
    }

    @Test("the six contradiction branches are mutually exclusive and jointly exhaustive")
    func branchesArePartition() async throws {
        // One input per branch; every input produces exactly one
        // rationale, and no two inputs land on the same operation and
        // rationale pair unless the branch pair genuinely shares one.
        var seen: [MemoryRationale] = []
        let cases: [(Fact, FactCandidate)] = [
            (storedFact(text: "a", validFrom: epoch), candidate(text: "b", validFrom: epoch.addingTimeInterval(1))),
            (storedFact(text: "a", validFrom: epoch.addingTimeInterval(1)), candidate(text: "b", validFrom: epoch)),
            (storedFact(text: "a", confidence: 0.7), candidate(text: "b", confidence: 0.95)),
            (storedFact(text: "a", confidence: 0.95), candidate(text: "b", confidence: 0.7)),
            (storedFact(text: "a", origin: .assistantStated, confidence: 0.95), candidate(text: "b", origin: .userStated, confidence: 0.95)),
            (storedFact(text: "a", origin: .userStated, confidence: 0.95), candidate(text: "b", origin: .assistantStated, confidence: 0.95)),
            (storedFact(text: "a"), candidate(text: "b")),
        ]
        for (incumbent, c) in cases {
            let d = try await resolve(incumbent: incumbent, candidate: c)
            seen.append(d.rationale)
        }
        #expect(seen == [
            .newerWins, .staleCandidate,
            .higherConfidenceWins, .higherConfidenceWins,
            .higherTrustWins, .higherTrustWins,
            .slotContradiction,
        ])
    }

    @Test("reconcile is a pure function across repeated runs")
    func purity() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([
            storedFact(predicate: "location", text: "Paris"),
            storedFact(predicate: "name", text: "Ada", validFrom: epoch.addingTimeInterval(days(3))),
        ])
        let batch = [
            candidate(predicate: "location", text: "Osaka", validFrom: epoch.addingTimeInterval(days(1))),
            candidate(predicate: "name", text: "Grace", validFrom: epoch),
            candidate(predicate: "prefers", text: "tea"),
            candidate(predicate: "location", text: "Osaka", tags: ["retraction"], validFrom: epoch.addingTimeInterval(days(1))),
        ]
        let now = epoch.addingTimeInterval(days(5))
        let reconciler = DeterministicReconciler()
        let reference = try await reconciler.reconcile(candidates: batch, against: store, now: now)
        for _ in 0..<50 {
            let again = try await reconciler.reconcile(candidates: batch, against: store, now: now)
            #expect(again == reference)
        }
    }
}

// MARK: - Apply

@Suite("ReconciliationApply")
struct ReconciliationApplyTests {
    @Test("an add inserts a live record and reports it")
    func addInserts() async throws {
        let store = InMemoryFactStore()
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "Paris")], against: store, now: epoch
        )
        let outcome = try await Reconciliation.apply(decisions, to: store, now: epoch)
        #expect(outcome.added.count == 1)
        #expect(outcome.superseded.isEmpty)
        #expect(outcome.byRationale[.noSimilarFact] == 1)
        let live = try await store.query(MemoryQuery(now: epoch))
        #expect(live.map(\.text) == ["Paris"])
        #expect(live[0].recordedAt == epoch)
        #expect(live[0].supersedes == nil)
    }

    @Test("an update abuts the two validity windows exactly")
    func updateAbutsWindows() async throws {
        let store = InMemoryFactStore()
        let t1 = epoch.addingTimeInterval(days(10))
        try await Reconciliation.apply(
            try await DeterministicReconciler().reconcile(
                candidates: [candidate(text: "Paris", validFrom: epoch)], against: store, now: epoch
            ), to: store, now: epoch
        )
        let old = try #require(try await store.query(MemoryQuery(now: epoch)).first)

        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "Osaka", validFrom: t1)], against: store, now: t1
        )
        #expect(decisions[0].operation == .update)
        let outcome = try await Reconciliation.apply(decisions, to: store, now: t1)
        #expect(outcome.superseded == [old.id])

        let retired = try #require(try await store.fact(id: old.id))
        let fresh = try #require(outcome.added.first)
        #expect(retired.validUntil == fresh.validFrom)
        #expect(retired.validUntil == t1)
        #expect(retired.invalidatedAt == t1)
        #expect(fresh.supersedes == old.id)

        let live = try await store.query(MemoryQuery(now: t1))
        #expect(live.map(\.text) == ["Osaka"])
        let everything = try await store.query(MemoryQuery(now: t1, includeInvalidated: true, order: .idAscending))
        #expect(everything.count == 2)
    }

    @Test("asOf between the two validity instants returns the old belief")
    func asOfReturnsHistory() async throws {
        let store = InMemoryFactStore()
        let t1 = epoch.addingTimeInterval(days(10))
        try await Reconciliation.apply(
            try await DeterministicReconciler().reconcile(
                candidates: [candidate(text: "Paris", validFrom: epoch)], against: store, now: epoch
            ), to: store, now: epoch
        )
        try await Reconciliation.apply(
            try await DeterministicReconciler().reconcile(
                candidates: [candidate(text: "Osaka", validFrom: t1)], against: store, now: t1
            ), to: store, now: t1
        )
        let march = try await store.query(MemoryQuery(now: t1, asOf: epoch.addingTimeInterval(days(5))))
        #expect(march.map(\.text) == ["Paris"])
        let later = try await store.query(MemoryQuery(now: t1, asOf: t1.addingTimeInterval(days(1))))
        #expect(later.map(\.text) == ["Osaka"])
    }

    @Test("a three-link supersession chain leaves exactly one live record")
    func supersessionChain() async throws {
        let store = InMemoryFactStore()
        var instants: [Date] = []
        for (index, text) in ["Paris", "Osaka", "Kyoto"].enumerated() {
            let t = epoch.addingTimeInterval(days(Double(index) * 10))
            instants.append(t)
            let decisions = try await DeterministicReconciler().reconcile(
                candidates: [candidate(text: text, validFrom: t)], against: store, now: t
            )
            try await Reconciliation.apply(decisions, to: store, now: t)
        }
        let now = instants[2].addingTimeInterval(days(1))
        let live = try await store.query(MemoryQuery(now: now))
        #expect(live.map(\.text) == ["Kyoto"])

        let all = try await store.query(MemoryQuery(now: now, includeInvalidated: true, order: .idAscending))
        #expect(all.count == 3)

        let root = try #require(all.first { $0.text == "Paris" })
        let chain = try await Reconciliation.chain(of: root.id, in: store)
        #expect(chain.map(\.text) == ["Paris", "Osaka", "Kyoto"])

        // The chain reads the same from any link.
        let middle = try #require(all.first { $0.text == "Osaka" })
        let fromMiddle = try await Reconciliation.chain(of: middle.id, in: store)
        #expect(fromMiddle.map(\.text) == ["Paris", "Osaka", "Kyoto"])

        // Intermediates are unreachable from a live query but reachable
        // historically.
        let midWindow = try await store.query(MemoryQuery(now: now, asOf: instants[1].addingTimeInterval(days(1))))
        #expect(midWindow.map(\.text) == ["Osaka"])
    }

    @Test("a retraction removes its target and leaves a sibling slot alone")
    func retractionWidthControl() async throws {
        let store = InMemoryFactStore()
        let location = storedFact(predicate: "location", text: "Paris")
        let name = storedFact(predicate: "name", text: "Ada")
        try await store.upsert([location, name])

        let now = epoch.addingTimeInterval(days(1))
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(predicate: "location", text: "Paris", tags: ["retraction"], validFrom: now)],
            against: store, now: now
        )
        let outcome = try await Reconciliation.apply(decisions, to: store, now: now)
        #expect(outcome.deleted == [location.id])

        let live = try await store.query(MemoryQuery(now: now, order: .idAscending))
        #expect(live.map(\.text) == ["Ada"])
        // Retraction is recoverable: the record is retired, not destroyed.
        #expect(try await store.allIDs().count == 2)
        let retired = try #require(try await store.fact(id: location.id))
        #expect(retired.invalidatedAt == now)
        // A retraction leaves the world-time window alone, so the claim
        // still answers honestly for instants inside it.
        #expect(retired.validUntil == nil)
    }

    @Test("apply never reaches a destructive path")
    func applyNeverPurges() async throws {
        let store = PurgeSpyFactStore()
        let now = epoch.addingTimeInterval(days(1))
        try await store.upsert([storedFact(text: "Paris"), storedFact(predicate: "name", text: "Ada")])
        let batch = [
            candidate(text: "Osaka", validFrom: now),
            candidate(predicate: "name", text: "Ada", tags: ["retraction"], validFrom: now),
            candidate(predicate: "prefers", text: "tea", validFrom: now),
        ]
        let decisions = try await DeterministicReconciler().reconcile(candidates: batch, against: store, now: now)
        _ = try await Reconciliation.apply(decisions, to: store, now: now)
        #expect(await store.purgeCalls == 0)
        let reasons = await store.invalidateCalls.map(\.reason)
        #expect(reasons.contains(.superseded))
        #expect(reasons.contains(.retracted))
    }

    @Test("a reconfirmed duplicate is touched, not rewritten")
    func duplicateIsTouched() async throws {
        let store = PurgeSpyFactStore()
        let existing = storedFact(text: "Paris")
        try await store.upsert([existing])
        let now = epoch.addingTimeInterval(days(2))
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "Paris", validFrom: now)], against: store, now: now
        )
        let outcome = try await Reconciliation.apply(decisions, to: store, now: now)
        #expect(outcome.noops == 1)
        #expect(outcome.added.isEmpty)
        #expect(await store.touchedIDs == [existing.id])
        let touched = try #require(try await store.fact(id: existing.id))
        #expect(touched.lastAccessedAt == now)
        #expect(touched.accessCount == 1)
    }

    @Test("two candidates in one batch see the same pre-batch state")
    func batchUsesPreBatchState() async throws {
        let store = InMemoryFactStore()
        let incumbent = storedFact(text: "Paris", validFrom: epoch)
        try await store.upsert([incumbent])
        let t1 = epoch.addingTimeInterval(days(1))
        let t2 = epoch.addingTimeInterval(days(2))
        let decisions = try await DeterministicReconciler().reconcile(
            candidates: [candidate(text: "Osaka", validFrom: t1), candidate(text: "Kyoto", validFrom: t2)],
            against: store, now: t2
        )
        // Both target the same incumbent, because neither saw the other.
        #expect(decisions.allSatisfy { $0.operation == .update })
        #expect(decisions.allSatisfy { $0.targetFactID == incumbent.id })

        let outcome = try await Reconciliation.apply(decisions, to: store, now: t2)
        #expect(outcome.added.count == 2)
        // The incumbent is retired once, at the *first* boundary that
        // named it — invalidation is idempotent, so the second call is a
        // no-op rather than a second rewrite of history.
        #expect(outcome.superseded == [incumbent.id])
        let retired = try #require(try await store.fact(id: incumbent.id))
        #expect(retired.validUntil == t1)
    }

    @Test("an update decision with no target is rejected rather than applied")
    func updateWithoutTargetThrows() async throws {
        let store = InMemoryFactStore()
        let bad = MemoryDecision(
            operation: .update,
            candidate: candidate(text: "Paris"),
            targetFactID: nil,
            rationale: .newerWins,
            decidedBy: "test"
        )
        await #expect(throws: MemoryError.self) {
            _ = try await Reconciliation.apply([bad], to: store, now: epoch)
        }
    }

    @Test("chain of an unknown id is empty and chain of a lone fact is itself")
    func chainEdges() async throws {
        let store = InMemoryFactStore()
        let lone = storedFact(text: "Paris")
        try await store.upsert([lone])
        #expect(try await Reconciliation.chain(of: "nope", in: store).isEmpty)
        #expect(try await Reconciliation.chain(of: lone.id, in: store).map(\.id) == [lone.id])
    }

    @Test("a sequence of candidates converges on one live fact per slot")
    func sequenceConvergence() async throws {
        // Property-style: whatever order corrections arrive in, each slot
        // ends with exactly one live record and every retired record is
        // still readable.
        let store = InMemoryFactStore()
        let reconciler = DeterministicReconciler()
        let texts = ["Paris", "Osaka", "Kyoto", "Nara", "Kobe"]
        for (index, text) in texts.enumerated() {
            let t = epoch.addingTimeInterval(days(Double(index)))
            for predicate in ["location", "prefers"] {
                let decisions = try await reconciler.reconcile(
                    candidates: [candidate(predicate: predicate, text: text, validFrom: t)],
                    against: store, now: t
                )
                try await Reconciliation.apply(decisions, to: store, now: t)
            }
        }
        let now = epoch.addingTimeInterval(days(Double(texts.count)))
        let live = try await store.query(MemoryQuery(now: now, order: .idAscending))
        #expect(live.count == 2)
        #expect(Set(live.map(\.text)) == ["Kobe"])
        #expect(Set(live.map(\.predicate)) == ["location", "prefers"])
        // Nothing was destroyed along the way.
        #expect(try await store.allIDs().count == texts.count * 2)
    }
}
