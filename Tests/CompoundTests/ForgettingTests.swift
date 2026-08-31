import Foundation
import Testing
@testable import Compound

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private func hours(_ n: Double) -> TimeInterval { n * 3600 }
private func days(_ n: Double) -> TimeInterval { n * 86_400 }
private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

private func fact(
    threadID: String = "t1",
    predicate: String,
    text: String,
    origin: MemoryOrigin = .userStated,
    confidence: Double = 0.9,
    importance: Int = 5,
    tags: Set<String> = [],
    recordedAt: Date = epoch,
    lastAccessedAt: Date? = nil,
    expiresAt: Date? = nil
) -> Fact {
    Fact(
        threadID: threadID,
        subject: "user",
        predicate: predicate,
        text: text,
        origin: origin,
        confidence: confidence,
        importance: importance,
        tags: tags,
        provenance: FactProvenance(threadID: threadID, messageIDs: [sourceID], extractor: "test.v1"),
        validFrom: epoch,
        recordedAt: recordedAt,
        expiresAt: expiresAt,
        lastAccessedAt: lastAccessedAt ?? recordedAt
    )
}

@Suite("Forgetting")
struct ForgettingTests {
    @Test("the shipped default expires nothing a user said")
    func defaultPolicyIsConservative() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([fact(predicate: "name", text: "Ada", recordedAt: epoch)])
        let outcome = try await ForgettingSweep().sweep(
            store: store, threadID: nil, now: epoch.addingTimeInterval(days(3650))
        )
        #expect(outcome.isEmpty)
        #expect(try await store.query(MemoryQuery(now: epoch.addingTimeInterval(days(3650)))).count == 1)
    }

    @Test("an unreconfirmed derived reflection lapses; a recalled one does not")
    func unreconfirmedDerivedExpires() async throws {
        let store = InMemoryFactStore()
        let stale = fact(predicate: "mood", text: "tired", origin: .derived, recordedAt: epoch)
        let recalled = fact(
            predicate: "focus", text: "swift", origin: .derived,
            recordedAt: epoch, lastAccessedAt: epoch.addingTimeInterval(days(29))
        )
        let spoken = fact(predicate: "name", text: "Ada", origin: .userStated, recordedAt: epoch)
        try await store.upsert([stale, recalled, spoken])

        let now = epoch.addingTimeInterval(days(31))
        let outcome = try await ForgettingSweep().sweep(store: store, threadID: nil, now: now)
        #expect(outcome.expired == [stale.id])
        #expect(outcome.evicted.isEmpty)
        let live = try await store.query(MemoryQuery(now: now, order: .idAscending))
        #expect(Set(live.map(\.id)) == [recalled.id, spoken.id])
    }

    @Test("a tag lifetime beats the default lifetime, and the smallest tag wins")
    func tagTimeToLiveWins() async throws {
        let store = InMemoryFactStore()
        let policy = ForgettingPolicy(
            defaultTimeToLive: .seconds(days(100)),
            timeToLiveByTag: ["ephemeral": .seconds(days(1)), "session": .seconds(days(7))]
        )
        let ephemeral = fact(predicate: "a", text: "one", tags: ["ephemeral", "session"])
        let sessioned = fact(predicate: "b", text: "two", tags: ["session"])
        let plain = fact(predicate: "c", text: "three")
        try await store.upsert([ephemeral, sessioned, plain])

        let now = epoch.addingTimeInterval(days(2))
        let outcome = try await ForgettingSweep(policy: policy).sweep(store: store, threadID: nil, now: now)
        // Only the one-day tag has elapsed; the seven-day and hundred-day
        // lifetimes have not.
        #expect(outcome.expired == [ephemeral.id])
        let live = try await store.query(MemoryQuery(now: now, order: .idAscending))
        #expect(Set(live.map(\.id)) == [sessioned.id, plain.id])
    }

    @Test("an explicit expiry fires regardless of tag lifetime")
    func explicitExpiryBeatsTag() async throws {
        let store = InMemoryFactStore()
        let policy = ForgettingPolicy(timeToLiveByTag: ["pinned": .seconds(days(3650))])
        let pinned = fact(
            predicate: "a", text: "one", tags: ["pinned"],
            recordedAt: epoch, expiresAt: epoch.addingTimeInterval(hours(1))
        )
        try await store.upsert([pinned])
        let now = epoch.addingTimeInterval(hours(2))
        let outcome = try await ForgettingSweep(policy: policy).sweep(store: store, threadID: nil, now: now)
        #expect(outcome.expired == [pinned.id])
        let retired = try #require(try await store.fact(id: pinned.id))
        #expect(retired.invalidatedAt == now)
        // Expiry leaves the world-time window alone.
        #expect(retired.validUntil == nil)
    }

    @Test("expiry is exclusive at the boundary instant")
    func expiryBoundary() async throws {
        let store = InMemoryFactStore()
        let policy = ForgettingPolicy(defaultTimeToLive: .seconds(days(1)))
        let f = fact(predicate: "a", text: "one", recordedAt: epoch)
        try await store.upsert([f])
        // Exactly at recordedAt + TTL the record is already gone
        // (`<=`), matching the store's strict liveness convention.
        let outcome = try await ForgettingSweep(policy: policy).sweep(
            store: store, threadID: nil, now: epoch.addingTimeInterval(days(1))
        )
        #expect(outcome.expired == [f.id])
    }

    @Test("decay retires a record only after the modelled elapsed time")
    func decayCrossesTheFloorOnSchedule() async throws {
        // 0.8 · 0.5^(t/24h) < 0.2  ⇔  t > 48h.
        let policy = ForgettingPolicy(
            minimumRetainedConfidence: 0.2,
            confidenceDecayHalfLife: .seconds(hours(24))
        )
        let before = InMemoryFactStore()
        let f = fact(predicate: "a", text: "one", confidence: 0.8, recordedAt: epoch)
        try await before.upsert([f])
        let early = try await ForgettingSweep(policy: policy).sweep(
            store: before, threadID: nil, now: epoch.addingTimeInterval(hours(47))
        )
        #expect(early.decayed.isEmpty)

        let after = InMemoryFactStore()
        try await after.upsert([f])
        let late = try await ForgettingSweep(policy: policy).sweep(
            store: after, threadID: nil, now: epoch.addingTimeInterval(hours(49))
        )
        #expect(late.decayed == [f.id])
        // Stored confidence is untouched: decay is a view of the
        // extractor's assessment at an instant, never a rewrite of it.
        let retired = try #require(try await after.fact(id: f.id))
        #expect(retired.confidence == 0.8)
    }

    @Test("recall resets the decay clock")
    func touchDefersDecay() async throws {
        let policy = ForgettingPolicy(
            minimumRetainedConfidence: 0.2,
            confidenceDecayHalfLife: .seconds(hours(24))
        )
        let store = InMemoryFactStore()
        let f = fact(
            predicate: "a", text: "one", confidence: 0.8,
            recordedAt: epoch, lastAccessedAt: epoch.addingTimeInterval(hours(48))
        )
        try await store.upsert([f])
        let outcome = try await ForgettingSweep(policy: policy).sweep(
            store: store, threadID: nil, now: epoch.addingTimeInterval(hours(60))
        )
        #expect(outcome.decayed.isEmpty)
    }

    @Test("eviction retires the least salient records over the cap")
    func evictionPicksLowestSalience() async throws {
        let store = InMemoryFactStore()
        let high = fact(predicate: "a", text: "one", importance: 10)
        let mid = fact(predicate: "b", text: "two", importance: 5)
        let low = fact(predicate: "c", text: "three", importance: 1)
        try await store.upsert([high, mid, low])

        let policy = ForgettingPolicy(maxLiveFactsPerThread: 2)
        let outcome = try await ForgettingSweep(policy: policy).sweep(store: store, threadID: nil, now: epoch)
        #expect(outcome.evicted == [low.id])
        let live = try await store.query(MemoryQuery(now: epoch, order: .idAscending))
        #expect(Set(live.map(\.id)) == [high.id, mid.id])
        let retired = try #require(try await store.fact(id: low.id))
        #expect(retired.invalidatedAt == epoch)
    }

    @Test("a pinned high-importance record survives an eviction that clears a stale one")
    func pinnedSurvivesEviction() async throws {
        let store = InMemoryFactStore()
        let pinned = fact(predicate: "core", text: "allergic to peanuts", importance: 10, tags: ["core"])
        let stale = fact(
            predicate: "chatter", text: "nice weather", importance: 2,
            recordedAt: epoch.addingTimeInterval(-days(30))
        )
        try await store.upsert([pinned, stale])
        let policy = ForgettingPolicy(maxLiveFactsPerThread: 1)
        let outcome = try await ForgettingSweep(policy: policy).sweep(store: store, threadID: nil, now: epoch)
        #expect(outcome.evicted == [stale.id])
        let live = try await store.query(MemoryQuery(now: epoch))
        #expect(live.map(\.id) == [pinned.id])
    }

    @Test("eviction breaks ties on id ascending, keeping the smaller id")
    func evictionTieBreak() async throws {
        let store = InMemoryFactStore()
        // Identical on every salience axis, so only the id separates them.
        let a = fact(predicate: "a", text: "one", importance: 5)
        let b = fact(predicate: "b", text: "two", importance: 5)
        try await store.upsert([a, b])
        let kept = min(a.id, b.id)
        let dropped = max(a.id, b.id)

        let policy = ForgettingPolicy(maxLiveFactsPerThread: 1)
        let outcome = try await ForgettingSweep(policy: policy).sweep(store: store, threadID: nil, now: epoch)
        #expect(outcome.evicted == [dropped])
        let live = try await store.query(MemoryQuery(now: epoch))
        #expect(live.map(\.id) == [kept])
    }

    @Test("the live cap applies per thread, not globally")
    func capIsPerThread() async throws {
        let store = InMemoryFactStore()
        try await store.upsert([
            fact(threadID: "a", predicate: "p", text: "one", importance: 9),
            fact(threadID: "a", predicate: "q", text: "two", importance: 1),
            fact(threadID: "b", predicate: "p", text: "three", importance: 9),
            fact(threadID: "b", predicate: "q", text: "four", importance: 1),
        ])
        let policy = ForgettingPolicy(maxLiveFactsPerThread: 1)
        let outcome = try await ForgettingSweep(policy: policy).sweep(store: store, threadID: nil, now: epoch)
        #expect(outcome.evicted.count == 2)
        let live = try await store.query(MemoryQuery(now: epoch, order: .idAscending))
        #expect(live.count == 2)
        #expect(Set(live.map(\.threadID)) == ["a", "b"])
        #expect(live.allSatisfy { $0.importance == 9 })
    }

    @Test("a thread-scoped sweep leaves other threads alone")
    func threadScoping() async throws {
        let store = InMemoryFactStore()
        let policy = ForgettingPolicy(defaultTimeToLive: .seconds(days(1)))
        try await store.upsert([
            fact(threadID: "a", predicate: "p", text: "one"),
            fact(threadID: "b", predicate: "p", text: "two"),
        ])
        let now = epoch.addingTimeInterval(days(2))
        let outcome = try await ForgettingSweep(policy: policy).sweep(store: store, threadID: "a", now: now)
        #expect(outcome.expired.count == 1)
        let live = try await store.query(MemoryQuery(now: now))
        #expect(live.map(\.threadID) == ["b"])
    }

    @Test("a sweep is idempotent at a fixed instant")
    func sweepIsIdempotent() async throws {
        let store = InMemoryFactStore()
        let policy = ForgettingPolicy(
            defaultTimeToLive: .seconds(days(5)),
            timeToLiveByTag: ["ephemeral": .seconds(days(1))],
            unreconfirmedDerivedTimeToLive: .seconds(days(2)),
            minimumRetainedConfidence: 0.2,
            maxLiveFactsPerThread: 2,
            confidenceDecayHalfLife: .seconds(hours(24))
        )
        try await store.upsert([
            fact(predicate: "a", text: "one", tags: ["ephemeral"]),
            fact(predicate: "b", text: "two", origin: .derived, confidence: 0.95),
            fact(predicate: "c", text: "three", importance: 10, recordedAt: epoch.addingTimeInterval(days(2))),
            fact(predicate: "d", text: "four", importance: 9, recordedAt: epoch.addingTimeInterval(days(2))),
            fact(predicate: "e", text: "five", importance: 1, recordedAt: epoch.addingTimeInterval(days(2))),
        ])
        let now = epoch.addingTimeInterval(days(3))
        let sweep = ForgettingSweep(policy: policy)
        let first = try await sweep.sweep(store: store, threadID: nil, now: now)
        #expect(!first.isEmpty)
        let second = try await sweep.sweep(store: store, threadID: nil, now: now)
        #expect(second == SweepOutcome.empty)

        // And the retired records still carry the first pass's timestamps.
        for id in first.allIDs {
            let retired = try #require(try await store.fact(id: id))
            #expect(retired.invalidatedAt == now)
        }
    }

    @Test("a sweep never reaches a destructive path")
    func sweepNeverPurges() async throws {
        let store = PurgeSpyFactStore()
        let policy = ForgettingPolicy(
            defaultTimeToLive: .seconds(days(1)),
            maxLiveFactsPerThread: 1,
            confidenceDecayHalfLife: .seconds(hours(1))
        )
        try await store.upsert([
            fact(predicate: "a", text: "one"),
            fact(predicate: "b", text: "two"),
        ])
        let outcome = try await ForgettingSweep(policy: policy).sweep(
            store: store, threadID: nil, now: epoch.addingTimeInterval(days(2))
        )
        #expect(!outcome.isEmpty)
        #expect(await store.purgeCalls == 0)
        // Everything is still readable through the invalidated view.
        #expect(try await store.allIDs().count == 2)
    }

    @Test("the three outcome lists are disjoint and sorted")
    func outcomeShape() async throws {
        let store = InMemoryFactStore()
        let policy = ForgettingPolicy(
            defaultTimeToLive: .seconds(days(1)),
            maxLiveFactsPerThread: 0,
            confidenceDecayHalfLife: .seconds(hours(1))
        )
        try await store.upsert((0..<6).map { fact(predicate: "p\($0)", text: "t\($0)") })
        let outcome = try await ForgettingSweep(policy: policy).sweep(
            store: store, threadID: nil, now: epoch.addingTimeInterval(days(2))
        )
        #expect(outcome.expired == outcome.expired.sorted())
        #expect(outcome.decayed == outcome.decayed.sorted())
        #expect(outcome.evicted == outcome.evicted.sorted())
        let all = outcome.expired + outcome.decayed + outcome.evicted
        #expect(Set(all).count == all.count)
    }

    @Test("resolved lifetimes are a pure function of the record's tags")
    func resolvedTimeToLive() {
        let policy = ForgettingPolicy(
            defaultTimeToLive: .seconds(days(100)),
            timeToLiveByTag: ["short": .seconds(days(1)), "long": .seconds(days(30))]
        )
        #expect(policy.resolvedTimeToLive(for: fact(predicate: "a", text: "x")) == .seconds(days(100)))
        #expect(policy.resolvedTimeToLive(for: fact(predicate: "a", text: "x", tags: ["long"])) == .seconds(days(30)))
        #expect(policy.resolvedTimeToLive(for: fact(predicate: "a", text: "x", tags: ["long", "short"])) == .seconds(days(1)))
        #expect(policy.resolvedTimeToLive(for: fact(predicate: "a", text: "x", tags: ["other"])) == .seconds(days(100)))
        #expect(ForgettingPolicy().resolvedTimeToLive(for: fact(predicate: "a", text: "x")) == nil)
    }

    @Test("a policy round-trips through Codable")
    func policyCodable() throws {
        let policy = ForgettingPolicy(
            defaultTimeToLive: .seconds(days(5)),
            timeToLiveByTag: ["a": .seconds(60)],
            unreconfirmedDerivedTimeToLive: .seconds(days(2)),
            minimumRetainedConfidence: 0.33,
            maxLiveFactsPerThread: 7,
            confidenceDecayHalfLife: .seconds(hours(6))
        )
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(ForgettingPolicy.self, from: data) == policy)
    }
}
