import Foundation
import Testing
@testable import Compound

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private func hours(_ n: Double) -> TimeInterval { n * 3600 }

private func makeFact(
    predicate: String = "name",
    text: String = "Ada",
    importance: Int = 5,
    lastAccessedAt: Date = epoch
) -> Fact {
    Fact(
        threadID: "t1",
        subject: "user",
        predicate: predicate,
        text: text,
        origin: .userStated,
        confidence: 0.9,
        importance: importance,
        tags: [],
        provenance: FactProvenance(threadID: "t1", messageIDs: [], extractor: "test"),
        validFrom: epoch,
        recordedAt: epoch,
        lastAccessedAt: lastAccessedAt
    )
}

@Suite("MemorySalience")
struct MemorySalienceTests {
    @Test("a single fact scores finitely rather than producing NaN")
    func singleFactIsFinite() {
        let scored = SalienceScorer().score([makeFact()], relevance: [:], now: epoch)
        #expect(scored.count == 1)
        #expect(scored[0].score.isFinite)
        // Every component is degenerate over a one-element set, so all
        // three normalize to zero.
        #expect(scored[0].score == 0)
        #expect(scored[0].components == SalienceComponents(recency: 0, importance: 0, relevance: 0))
    }

    @Test("an empty input yields an empty output")
    func emptyInput() {
        #expect(SalienceScorer().score([], relevance: [:], now: epoch).isEmpty)
    }

    @Test("a component with no spread contributes nothing, never NaN")
    func degenerateComponents() {
        let facts = (0..<4).map { makeFact(predicate: "p\($0)", text: "f\($0)", importance: 5) }
        let scored = SalienceScorer().score(facts, relevance: [:], now: epoch)
        for s in scored {
            #expect(s.score.isFinite)
            #expect(!s.score.isNaN)
            #expect(s.components.importance == 0)
            #expect(s.components.recency == 0)
        }
    }

    @Test("identical facts order by id ascending")
    func tiesBreakOnID() {
        let facts = (0..<6).map { makeFact(predicate: "p\($0)", text: "same claim") }
        let scored = SalienceScorer().score(facts, relevance: [:], now: epoch)
        #expect(scored.map(\.fact.id) == facts.map(\.id).sorted())
        // And the tiebreak is stable regardless of input order.
        let shuffledInput = facts.sorted { $0.id > $1.id }
        let again = SalienceScorer().score(shuffledInput, relevance: [:], now: epoch)
        #expect(again.map(\.fact.id) == scored.map(\.fact.id))
    }

    @Test("a more recently touched fact outranks an older one")
    func recencyMovesRanking() {
        let stale = makeFact(predicate: "p1", text: "stale", lastAccessedAt: epoch)
        let fresh = makeFact(predicate: "p2", text: "fresh", lastAccessedAt: epoch.addingTimeInterval(hours(70)))
        let now = epoch.addingTimeInterval(hours(72))
        let scored = SalienceScorer().score([stale, fresh], relevance: [:], now: now)
        #expect(scored.map(\.fact.text) == ["fresh", "stale"])
        #expect(scored[0].components.recency == 1)
        #expect(scored[1].components.recency == 0)
    }

    @Test("importance breaks a recency tie")
    func importanceCounts() {
        let low = makeFact(predicate: "p1", text: "low", importance: 2)
        let high = makeFact(predicate: "p2", text: "high", importance: 9)
        let scored = SalienceScorer().score([low, high], relevance: [:], now: epoch)
        #expect(scored.map(\.fact.text) == ["high", "low"])
    }

    @Test("relevance is read by fact id and defaults to zero")
    func relevanceByID() {
        let a = makeFact(predicate: "p1", text: "alpha")
        let b = makeFact(predicate: "p2", text: "beta")
        let scored = SalienceScorer().score([a, b], relevance: [b.id: 1.0], now: epoch)
        #expect(scored.map(\.fact.text) == ["beta", "alpha"])
        #expect(scored[0].components.relevance == 1)
        #expect(scored[1].components.relevance == 0)
    }

    @Test("weights redirect the ranking")
    func weightsApply() {
        let fresh = makeFact(predicate: "p1", text: "fresh", importance: 1, lastAccessedAt: epoch.addingTimeInterval(hours(72)))
        let important = makeFact(predicate: "p2", text: "important", importance: 10, lastAccessedAt: epoch)
        let now = epoch.addingTimeInterval(hours(72))
        let recencyOnly = SalienceScorer(weights: .init(recency: 5, importance: 0, relevance: 0))
        #expect(recencyOnly.score([fresh, important], relevance: [:], now: now).first?.fact.text == "fresh")
        let importanceOnly = SalienceScorer(weights: .init(recency: 0, importance: 5, relevance: 0))
        #expect(importanceOnly.score([fresh, important], relevance: [:], now: now).first?.fact.text == "important")
    }

    @Test("the recency term halves over one half-life")
    func halfLifeShape() {
        let scorer = SalienceScorer(recencyHalfLifeHours: 24)
        let now = epoch.addingTimeInterval(hours(24))
        let atNow = makeFact(predicate: "p0", text: "now", lastAccessedAt: now)
        let oneHalfLife = makeFact(predicate: "p1", text: "one", lastAccessedAt: epoch)
        let scored = scorer.score([atNow, oneHalfLife], relevance: [:], now: now)
        // Raw terms are 1.0 and 0.5; after min-max they are 1 and 0, so
        // check the shape through the ordering plus a hand-computed raw
        // pair via a three-point set.
        #expect(scored.map(\.fact.text) == ["now", "one"])
        let twoHalfLives = makeFact(predicate: "p2", text: "two", lastAccessedAt: epoch.addingTimeInterval(-hours(24)))
        let three = scorer.score([atNow, oneHalfLife, twoHalfLives], relevance: [:], now: now)
        let middle = three.first { $0.fact.text == "one" }!
        // raw: 1.0, 0.5, 0.25 -> normalized middle = (0.5 - 0.25) / 0.75
        #expect(abs(middle.components.recency - (1.0 / 3.0)) < 1e-9)
    }

    @Test("a lastAccessedAt in the future is clamped, never above 1")
    func futureAccessClamped() {
        let future = makeFact(predicate: "p1", text: "future", lastAccessedAt: epoch.addingTimeInterval(hours(1000)))
        let present = makeFact(predicate: "p2", text: "present", lastAccessedAt: epoch)
        let scored = SalienceScorer().score([future, present], relevance: [:], now: epoch)
        for s in scored {
            #expect(s.components.recency >= 0 && s.components.recency <= 1)
            #expect(s.score.isFinite)
        }
        // Clock skew must not let a future record beat a present one by
        // more than the ordinary "just touched" amount.
        #expect(scored.first?.fact.text == "future")
    }

    @Test("a fixed now yields byte-identical ordering across runs")
    func fixedClockIsReproducible() {
        let facts = (0..<12).map {
            makeFact(
                predicate: "p\($0)",
                text: "claim \($0)",
                importance: ($0 % 3) + 3,
                lastAccessedAt: epoch.addingTimeInterval(hours(Double($0 % 4) * 10))
            )
        }
        let relevance = Dictionary(uniqueKeysWithValues: facts.enumerated().map { ($0.element.id, Double($0.offset % 5) / 5.0) })
        let now = epoch.addingTimeInterval(hours(60))
        var first: [String] = []
        for run in 0..<25 {
            let ids = SalienceScorer().score(facts, relevance: relevance, now: now).map(\.fact.id)
            if run == 0 { first = ids } else { #expect(ids == first) }
        }
        #expect(first.count == facts.count)
    }

    @Test("normalize maps a degenerate range to all zeros")
    func normalizeDegenerate() {
        #expect(SalienceScorer.normalize([]) == [])
        #expect(SalienceScorer.normalize([7]) == [0])
        #expect(SalienceScorer.normalize([3, 3, 3]) == [0, 0, 0])
        #expect(SalienceScorer.normalize([0, 5, 10]) == [0, 0.5, 1])
    }

    @Test("store salience ordering matches the scorer")
    func storeSalienceMatchesScorer() async throws {
        let store = InMemoryFactStore()
        let stale = makeFact(predicate: "p1", text: "stale", importance: 3, lastAccessedAt: epoch)
        let fresh = makeFact(predicate: "p2", text: "fresh", importance: 9, lastAccessedAt: epoch.addingTimeInterval(hours(70)))
        try await store.upsert([stale, fresh])
        let now = epoch.addingTimeInterval(hours(72))
        let hits = try await store.query(MemoryQuery(now: now, order: .salience))
        let expected = SalienceScorer().score([stale, fresh], relevance: [:], now: now).map(\.fact.id)
        #expect(hits.map(\.id) == expected)
        #expect(hits.first?.text == "fresh")
    }
}
