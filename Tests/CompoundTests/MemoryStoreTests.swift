import Foundation
import Testing
@testable import Compound

// A fixed instant so nothing in this file depends on the wall clock.
private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private func hours(_ n: Double) -> TimeInterval { n * 3600 }

private func makeFact(
    id: String? = nil,
    thread: String = "t1",
    subject: String = "user",
    predicate: String = "name",
    text: String = "Ada",
    origin: MemoryOrigin = .userStated,
    confidence: Double = 0.9,
    importance: Int = 5,
    tags: Set<String> = [],
    validFrom: Date = epoch,
    validUntil: Date? = nil,
    recordedAt: Date = epoch,
    invalidatedAt: Date? = nil,
    expiresAt: Date? = nil,
    lastAccessedAt: Date? = nil,
    accessCount: Int = 0
) -> Fact {
    Fact(
        id: id,
        threadID: thread,
        subject: subject,
        predicate: predicate,
        text: text,
        origin: origin,
        confidence: confidence,
        importance: importance,
        tags: tags,
        provenance: FactProvenance(threadID: thread, messageIDs: [], extractor: "test"),
        validFrom: validFrom,
        validUntil: validUntil,
        recordedAt: recordedAt,
        invalidatedAt: invalidatedAt,
        expiresAt: expiresAt,
        lastAccessedAt: lastAccessedAt ?? recordedAt,
        accessCount: accessCount
    )
}

@Suite("MemoryText")
struct MemoryTextTests {
    @Test("normalize folds case, whitespace runs, and Unicode form")
    func normalizeFolds() {
        #expect(MemoryText.normalize("  Work   Email \n") == "work email")
        let nfd = "café".decomposedStringWithCanonicalMapping
        #expect(MemoryText.normalize(nfd) == MemoryText.normalize("Café"))
        #expect(MemoryText.normalize("") == "")
        #expect(MemoryText.normalize("   \t\n  ") == "")
    }

    @Test("normalize collapses tabs and newlines to a single space")
    func normalizeCollapsesMixedWhitespace() {
        #expect(MemoryText.normalize("a\t\t b\n\nc") == "a b c")
    }

    @Test("verbatim span is literal, not normalized")
    func verbatimSpanIsLiteral() {
        let message = "My name is Ada Lovelace."
        #expect(MemoryText.isVerbatimSpan("Ada Lovelace", of: message))
        // Case and spacing differences are NOT verbatim.
        #expect(!MemoryText.isVerbatimSpan("ada lovelace", of: message))
        #expect(!MemoryText.isVerbatimSpan("Ada  Lovelace", of: message))
        // A model-authored claim that never appeared is rejected.
        #expect(!MemoryText.isVerbatimSpan("Grace Hopper", of: message))
        // The empty span never satisfies the guard.
        #expect(!MemoryText.isVerbatimSpan("", of: message))
    }

    @Test("verbatim span tolerates only Unicode normalization differences")
    func verbatimSpanNFC() {
        let message = "I live in Za\u{0308}hringen."  // NFD "ä"
        #expect(MemoryText.isVerbatimSpan("Zähringen", of: message))
    }
}

@Suite("MemoryFactID")
struct MemoryFactIDTests {
    @Test("derivation is stable across normalization variants")
    func derivationStable() {
        let base = FactID.derive(threadID: "t1", subject: "user", predicate: "name", text: "Ada Lovelace")
        #expect(FactID.derive(threadID: "t1", subject: "User", predicate: "NAME", text: "Ada Lovelace") == base)
        #expect(FactID.derive(threadID: "t1", subject: " user ", predicate: "name", text: "Ada   Lovelace") == base)
        let nfd = "Ada Lovelace".decomposedStringWithCanonicalMapping
        #expect(FactID.derive(threadID: "t1", subject: "user", predicate: "name", text: nfd) == base)
        // Different claim text is a different record.
        #expect(FactID.derive(threadID: "t1", subject: "user", predicate: "name", text: "Grace Hopper") != base)
        // Thread scoping is part of the address.
        #expect(FactID.derive(threadID: "t2", subject: "user", predicate: "name", text: "Ada Lovelace") != base)
        // So is the predicate.
        #expect(FactID.derive(threadID: "t1", subject: "user", predicate: "alias", text: "Ada Lovelace") != base)
    }

    @Test("fact ids occupy a region disjoint from chunk ids")
    func disjointFromChunkIDs() {
        let factID = FactID.derive(threadID: "t1", subject: "user", predicate: "name", text: "Ada")
        #expect(factID.count == 32)
        // The plausible ways a chunk id could be computed over the same
        // material all miss, because the fact domain is folded in.
        #expect(factID != DocumentChunker.chunkID(documentID: "t1", ordinal: 0, content: "ada"))
        #expect(factID != DocumentChunker.chunkID(documentID: "user", ordinal: 0, content: "Ada"))
        #expect(factID != DocumentChunker.chunkID(documentID: "t1|user|name", ordinal: 0, content: "ada"))
        // And the derivation is exactly the documented one.
        #expect(factID == DocumentChunker.chunkID(
            documentID: "compound.memory.fact.v1|t1|user|name",
            ordinal: 0,
            content: "ada"
        ))
    }

    @Test("fact adopts the derived id when none is supplied")
    func factAdoptsDerivedID() {
        let f = makeFact(text: "Ada Lovelace")
        #expect(f.id == FactID.derive(threadID: "t1", subject: "user", predicate: "name", text: "Ada Lovelace"))
        #expect(f.slot == FactSlot(threadID: "t1", subject: "USER", predicate: " Name "))
    }
}

@Suite("MemoryLiveness")
struct MemoryLivenessTests {
    @Test("a future validFrom is not yet live")
    func futureValidFrom() {
        let f = makeFact(validFrom: epoch.addingTimeInterval(hours(1)))
        #expect(!f.isLive(at: epoch))
        #expect(f.isLive(at: epoch.addingTimeInterval(hours(1))))
    }

    @Test("expiresAt exactly at the instant is already expired")
    func expiresAtBoundary() {
        let f = makeFact(expiresAt: epoch.addingTimeInterval(hours(1)))
        #expect(f.isLive(at: epoch.addingTimeInterval(hours(0.99))))
        #expect(!f.isLive(at: epoch.addingTimeInterval(hours(1))))
    }

    @Test("validUntil exactly at the instant is already over")
    func validUntilBoundary() {
        let f = makeFact(validUntil: epoch.addingTimeInterval(hours(1)))
        #expect(f.isLive(at: epoch))
        #expect(!f.isLive(at: epoch.addingTimeInterval(hours(1))))
    }

    @Test("invalidatedAt kills liveness regardless of the window")
    func invalidatedIsNeverLive() {
        let f = makeFact(invalidatedAt: epoch.addingTimeInterval(hours(1)))
        #expect(!f.isLive(at: epoch))
        #expect(!f.isLive(at: epoch.addingTimeInterval(hours(99))))
    }
}

@Suite("MemoryStore")
struct MemoryStoreTests {
    @Test("upsert replaces on id and count reflects it")
    func upsertReplaces() async throws {
        let store = InMemoryFactStore()
        let f = makeFact(text: "Ada")
        try await store.upsert([f])
        try await store.upsert([f.with(confidence: 0.5)])
        #expect(await store.count == 1)
        let read = try await store.fact(id: f.id)
        #expect(read?.confidence == 0.5)
    }

    @Test("query filters by threadID")
    func filterThread() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([
            makeFact(thread: "a", text: "one"),
            makeFact(thread: "b", text: "two"),
        ])
        let a = try await store.query(MemoryQuery(now: epoch, threadID: "a"))
        #expect(a.count == 1)
        #expect(a[0].threadID == "a")
    }

    @Test("query filters by slot")
    func filterSlot() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([
            makeFact(predicate: "name", text: "Ada"),
            makeFact(predicate: "location", text: "Dublin"),
        ])
        let slot = FactSlot(threadID: "t1", subject: "user", predicate: "location")
        let hits = try await store.query(MemoryQuery(now: epoch, slot: slot))
        #expect(hits.count == 1)
        #expect(hits[0].text == "Dublin")
    }

    @Test("query filters by tagsAny, empty set meaning no filter")
    func filterTags() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([
            makeFact(text: "Ada", tags: ["core"]),
            makeFact(predicate: "prefers", text: "tea", tags: ["preference"]),
            makeFact(predicate: "location", text: "Dublin", tags: []),
        ])
        let core = try await store.query(MemoryQuery(now: epoch, tagsAny: ["core"]))
        #expect(core.map(\.text) == ["Ada"])
        let either = try await store.query(MemoryQuery(now: epoch, tagsAny: ["core", "preference"]))
        #expect(either.count == 2)
        let all = try await store.query(MemoryQuery(now: epoch))
        #expect(all.count == 3)
    }

    @Test("query filters by minConfidence and minimumOrigin")
    func filterConfidenceAndTrust() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([
            makeFact(text: "high", origin: .userStated, confidence: 0.95),
            makeFact(predicate: "p2", text: "low", origin: .userStated, confidence: 0.3),
            makeFact(predicate: "p3", text: "derived", origin: .derived, confidence: 0.95),
        ])
        let confident = try await store.query(MemoryQuery(now: epoch, minConfidence: 0.5))
        #expect(Set(confident.map(\.text)) == ["high", "derived"])
        let trusted = try await store.query(MemoryQuery(now: epoch, minimumOrigin: .assistantStated))
        #expect(Set(trusted.map(\.text)) == ["high", "low"])
        let both = try await store.query(MemoryQuery(now: epoch, minConfidence: 0.5, minimumOrigin: .userStated))
        #expect(both.map(\.text) == ["high"])
    }

    @Test("combined filters intersect")
    func filtersCombine() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([
            makeFact(thread: "a", predicate: "p1", text: "keep", confidence: 0.9, tags: ["core"]),
            makeFact(thread: "a", predicate: "p2", text: "wrong tag", confidence: 0.9, tags: ["other"]),
            makeFact(thread: "b", predicate: "p1", text: "wrong thread", confidence: 0.9, tags: ["core"]),
            makeFact(thread: "a", predicate: "p3", text: "low conf", confidence: 0.1, tags: ["core"]),
        ])
        let hits = try await store.query(MemoryQuery(
            now: epoch, threadID: "a", tagsAny: ["core"], minConfidence: 0.5
        ))
        #expect(hits.map(\.text) == ["keep"])
    }

    @Test("liveness filter hides invalidated records unless asked")
    func filterInvalidated() async throws {
        let store = InMemoryFactStore()
        let f = makeFact(text: "Ada")
        try await store.upsert([f])
        _ = try await store.invalidate(ids: [f.id], validUntil: nil, at: epoch, reason: .retracted)
        let live = try await store.query(MemoryQuery(now: epoch))
        #expect(live.isEmpty)
        let all = try await store.query(MemoryQuery(now: epoch, includeInvalidated: true))
        #expect(all.count == 1)
    }

    @Test("asOf answers what was believed in March")
    func asOfHistory() async throws {
        let store = InMemoryFactStore()
        let march = Date(timeIntervalSince1970: 1_678_000_000)
        let june = Date(timeIntervalSince1970: 1_688_000_000)
        let september = Date(timeIntervalSince1970: 1_694_000_000)
        // The old belief, superseded in June.
        let old = makeFact(
            predicate: "location", text: "Dublin",
            validFrom: march, validUntil: june, recordedAt: march,
            invalidatedAt: june
        )
        let new = makeFact(
            predicate: "location", text: "Lisbon",
            validFrom: june, recordedAt: june
        )
        try await store.upsert([old, new])

        let slot = FactSlot(threadID: "t1", subject: "user", predicate: "location")
        // In April the old belief held, even though the system has
        // since retired that record.
        let inApril = try await store.query(MemoryQuery(
            now: september, slot: slot, asOf: march.addingTimeInterval(hours(24))
        ))
        #expect(inApril.map(\.text) == ["Dublin"])

        // Once asOf passes the old record's validUntil, the superseding
        // record is the answer.
        let inJuly = try await store.query(MemoryQuery(
            now: september, slot: slot, asOf: june.addingTimeInterval(hours(24))
        ))
        #expect(inJuly.map(\.text) == ["Lisbon"])

        // And the plain "what do I believe now" read is unaffected by
        // the history: only the live record comes back.
        let today = try await store.query(MemoryQuery(now: september, slot: slot))
        #expect(today.map(\.text) == ["Lisbon"])

        // includeInvalidated overrides the liveness filter entirely, so
        // asOf has nothing left to narrow.
        let everything = try await store.query(MemoryQuery(
            now: september, slot: slot, includeInvalidated: true,
            asOf: march.addingTimeInterval(hours(24)), order: .validFromDescending
        ))
        #expect(everything.map(\.text) == ["Lisbon", "Dublin"])
    }

    @Test("asOf survives a retraction that set no validUntil")
    func asOfSurvivesRetraction() async throws {
        let store = InMemoryFactStore()
        let f = makeFact(predicate: "location", text: "Dublin", validFrom: epoch)
        try await store.upsert([f])
        let later = epoch.addingTimeInterval(hours(100))
        _ = try await store.invalidate(ids: [f.id], validUntil: nil, at: later, reason: .retracted)
        // Live read: gone.
        #expect(try await store.query(MemoryQuery(now: later)).isEmpty)
        // Validity-time read: it was true back then, and still answers so.
        let historical = try await store.query(MemoryQuery(now: later, asOf: epoch.addingTimeInterval(hours(1))))
        #expect(historical.map(\.text) == ["Dublin"])
    }

    @Test("orders break ties on id ascending")
    func orderingDeterminism() async throws {
        let store = InMemoryFactStore()
        let a = makeFact(predicate: "p1", text: "alpha")
        let b = makeFact(predicate: "p2", text: "beta")
        let c = makeFact(predicate: "p3", text: "gamma")
        try await store.upsert([a, b, c])
        let byID = try await store.query(MemoryQuery(now: epoch, order: .idAscending))
        #expect(byID.map(\.id) == [a, b, c].map(\.id).sorted())
        // Every field that could order these is identical, so every
        // order degenerates to the id tiebreak.
        for order in MemoryOrder.allCases {
            let hits = try await store.query(MemoryQuery(now: epoch, order: order))
            #expect(hits.map(\.id) == byID.map(\.id), "order \(order) is not id-stable")
        }
    }

    @Test("recordedAtDescending and validFromDescending sort as named")
    func explicitOrders() async throws {
        let store = InMemoryFactStore()
        let old = makeFact(predicate: "p1", text: "old", validFrom: epoch, recordedAt: epoch)
        let new = makeFact(
            predicate: "p2", text: "new",
            validFrom: epoch.addingTimeInterval(hours(10)),
            recordedAt: epoch.addingTimeInterval(hours(10))
        )
        try await store.upsert([old, new])
        let now = epoch.addingTimeInterval(hours(20))
        let byRecorded = try await store.query(MemoryQuery(now: now, order: .recordedAtDescending))
        #expect(byRecorded.map(\.text) == ["new", "old"])
        let byValid = try await store.query(MemoryQuery(now: now, order: .validFromDescending))
        #expect(byValid.map(\.text) == ["new", "old"])
    }

    @Test("limit truncates after ordering")
    func limitTruncates() async throws {
        let store = InMemoryFactStore()
        try await store.upsert((0..<10).map { makeFact(predicate: "p\($0)", text: "f\($0)") })
        let hits = try await store.query(MemoryQuery(now: epoch, limit: 3, order: .idAscending))
        #expect(hits.count == 3)
        let all = try await store.query(MemoryQuery(now: epoch, limit: 100, order: .idAscending))
        #expect(hits.map(\.id) == Array(all.map(\.id).prefix(3)))
    }

    @Test("invalidate is idempotent and reports the changed count")
    func invalidateIdempotent() async throws {
        let store = InMemoryFactStore()
        let f = makeFact(text: "Ada")
        try await store.upsert([f])
        let first = try await store.invalidate(ids: [f.id], validUntil: nil, at: epoch, reason: .retracted)
        #expect(first == 1)
        let second = try await store.invalidate(ids: [f.id], validUntil: nil, at: epoch.addingTimeInterval(hours(1)), reason: .retracted)
        #expect(second == 0)
        // The original timestamp survives the second pass.
        let read = try await store.fact(id: f.id)
        #expect(read?.invalidatedAt == epoch)
    }

    @Test("invalidating an unknown id returns zero without throwing")
    func invalidateUnknown() async throws {
        let store = InMemoryFactStore()
        let n = try await store.invalidate(ids: ["nope"], validUntil: nil, at: epoch, reason: .retracted)
        #expect(n == 0)
    }

    @Test("invalidate sets validUntil when supplied")
    func invalidateSetsWindow() async throws {
        let store = InMemoryFactStore()
        let f = makeFact(predicate: "location", text: "Dublin")
        try await store.upsert([f])
        let cut = epoch.addingTimeInterval(hours(5))
        _ = try await store.invalidate(ids: [f.id], validUntil: cut, at: epoch.addingTimeInterval(hours(6)), reason: .superseded)
        let read = try await store.fact(id: f.id)
        #expect(read?.validUntil == cut)
        #expect(read?.invalidatedAt == epoch.addingTimeInterval(hours(6)))
    }

    @Test("purge by exact subject spares prefix siblings")
    func purgeExactSubjectOnly() async throws {
        let store = InMemoryFactStore()
        let target = makeFact(subject: "project", predicate: "status", text: "green")
        let sibling = makeFact(subject: "project-atlas", predicate: "status", text: "red")
        let other = makeFact(subject: "projector", predicate: "status", text: "blue")
        try await store.upsert([target, sibling, other])
        let removed = try await store.purge(matching: PurgePredicate(subjectEquals: "Project"))
        #expect(removed == [target.id])
        let remaining = Set(try await store.allIDs())
        #expect(remaining == [sibling.id, other.id])
    }

    @Test("purge by predicate honours thread, tags, and age together")
    func purgePredicateFields() async throws {
        let store = InMemoryFactStore()
        let old = makeFact(thread: "a", predicate: "p1", text: "old", tags: ["pii"], recordedAt: epoch)
        let young = makeFact(thread: "a", predicate: "p2", text: "young", tags: ["pii"], recordedAt: epoch.addingTimeInterval(hours(50)))
        let untagged = makeFact(thread: "a", predicate: "p3", text: "untagged", recordedAt: epoch)
        let otherThread = makeFact(thread: "b", predicate: "p1", text: "elsewhere", tags: ["pii"], recordedAt: epoch)
        try await store.upsert([old, young, untagged, otherThread])
        let removed = try await store.purge(matching: PurgePredicate(
            threadID: "a", tagsAny: ["pii"], olderThan: epoch.addingTimeInterval(hours(10))
        ))
        #expect(removed == [old.id])
    }

    @Test("an empty purge predicate matches nothing")
    func emptyPredicateIsInert() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([makeFact(text: "Ada")])
        let removed = try await store.purge(matching: PurgePredicate())
        #expect(removed.isEmpty)
        #expect(await store.count == 1)
    }

    @Test("purge and invalidate are distinguishable")
    func purgeVersusInvalidate() async throws {
        let store = InMemoryFactStore()
        let kept = makeFact(predicate: "p1", text: "kept")
        let gone = makeFact(predicate: "p2", text: "gone")
        try await store.upsert([kept, gone])
        _ = try await store.invalidate(ids: [kept.id], validUntil: nil, at: epoch, reason: .retracted)
        let purged = try await store.purge(ids: [gone.id])
        #expect(purged == 1)

        let recoverable = try await store.query(MemoryQuery(now: epoch, includeInvalidated: true))
        #expect(recoverable.map(\.id) == [kept.id])
        let ids = try await store.allIDs()
        #expect(ids == [kept.id])
        #expect(try await store.fact(id: gone.id) == nil)
    }

    @Test("touch bumps access metadata")
    func touchBumps() async throws {
        let store = InMemoryFactStore()
        let f = makeFact(text: "Ada")
        try await store.upsert([f])
        try await store.touch(ids: [f.id], at: epoch.addingTimeInterval(hours(3)))
        try await store.touch(ids: [f.id], at: epoch.addingTimeInterval(hours(5)))
        let read = try await store.fact(id: f.id)
        #expect(read?.accessCount == 2)
        #expect(read?.lastAccessedAt == epoch.addingTimeInterval(hours(5)))
        // Touching with an earlier instant never rewinds the clock.
        try await store.touch(ids: [f.id], at: epoch)
        let again = try await store.fact(id: f.id)
        #expect(again?.lastAccessedAt == epoch.addingTimeInterval(hours(5)))
        #expect(again?.accessCount == 3)
    }

    @Test("similar ranks an exact restatement above a partial overlap")
    func similarRanks() async throws {
        let store = InMemoryFactStore()
        let exact = makeFact(predicate: "p1", text: "I prefer oat milk in coffee")
        let partial = makeFact(predicate: "p2", text: "I prefer coffee")
        let unrelated = makeFact(predicate: "p3", text: "the ceiling is blue")
        try await store.upsert([exact, partial, unrelated])
        let hits = try await store.similar(
            to: "I prefer oat milk in coffee", slot: nil, threadID: nil, limit: 5, now: epoch
        )
        #expect(hits.first?.fact.id == exact.id)
        #expect(hits.first?.score == 1.0)
        #expect(hits.count == 2)  // "unrelated" shares no tokens and is dropped
        #expect(hits[1].fact.id == partial.id)
        #expect(hits[1].score < 1.0)
    }

    @Test("similar is order-deterministic across repeated calls")
    func similarDeterministic() async throws {
        let store = InMemoryFactStore()
        // Six facts with identical token multisets: every score ties, so
        // only the id tiebreak can produce a stable order.
        for i in 0..<6 {
            try await store.upsert([makeFact(predicate: "p\(i)", text: "green tea please")])
        }
        var first: [String] = []
        for run in 0..<100 {
            let hits = try await store.similar(to: "green tea please", slot: nil, threadID: nil, limit: 6, now: epoch)
            let ids = hits.map(\.fact.id)
            if run == 0 { first = ids } else { #expect(ids == first) }
        }
        #expect(first == first.sorted())
    }

    @Test("similar excludes invalidated facts and honours slot and thread scoping")
    func similarScoping() async throws {
        let store = InMemoryFactStore()
        let live = makeFact(thread: "a", predicate: "p1", text: "green tea")
        let dead = makeFact(thread: "a", predicate: "p2", text: "green tea")
        let elsewhere = makeFact(thread: "b", predicate: "p1", text: "green tea")
        try await store.upsert([live, dead, elsewhere])
        _ = try await store.invalidate(ids: [dead.id], validUntil: nil, at: epoch, reason: .retracted)

        let scoped = try await store.similar(to: "green tea", slot: nil, threadID: "a", limit: 10, now: epoch)
        #expect(scoped.map(\.fact.id) == [live.id])

        let slot = FactSlot(threadID: "b", subject: "user", predicate: "p1")
        let bySlot = try await store.similar(to: "green tea", slot: slot, threadID: nil, limit: 10, now: epoch)
        #expect(bySlot.map(\.fact.id) == [elsewhere.id])
    }

    @Test("removeAll empties the store")
    func removeAllEmpties() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([makeFact(predicate: "p1", text: "a"), makeFact(predicate: "p2", text: "b")])
        try await store.removeAll()
        #expect(try await store.allIDs().isEmpty)
        #expect(await store.count == 0)
    }

    @Test("100 concurrent upserts leave exactly the expected id set")
    func concurrentUpserts() async throws {
        let store = InMemoryFactStore()
        let facts = (0..<100).map { makeFact(predicate: "p\($0)", text: "fact number \($0)") }
        await withTaskGroup(of: Void.self) { group in
            for fact in facts {
                group.addTask { try? await store.upsert([fact]) }
            }
        }
        let ids = try await store.allIDs()
        #expect(ids == facts.map(\.id).sorted())
        #expect(await store.count == 100)
    }

    @Test("slot index survives concurrent slot-scoped reads")
    func concurrentSlotReads() async throws {
        let store = InMemoryFactStore()
        let slot = FactSlot(threadID: "t1", subject: "user", predicate: "name")
        try await store.upsert([makeFact(text: "Ada")])
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    ((try? await store.query(MemoryQuery(now: epoch, slot: slot))) ?? []).count
                }
            }
            for await count in group { #expect(count == 1) }
        }
    }
}

@Suite("MemoryOrigin")
struct MemoryOriginTests {
    @Test("trust ranks are strictly ordered as documented")
    func trustRanks() {
        #expect(MemoryOrigin.userStated.trustRank == 4)
        #expect(MemoryOrigin.assistantStated.trustRank == 3)
        #expect(MemoryOrigin.toolOutput.trustRank == 2)
        #expect(MemoryOrigin.retrievedDocument.trustRank == 1)
        #expect(MemoryOrigin.derived.trustRank == 0)
        let ranks = MemoryOrigin.allCases.map(\.trustRank)
        #expect(Set(ranks).count == MemoryOrigin.allCases.count)
    }
}
