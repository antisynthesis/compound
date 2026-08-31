import Foundation
import Testing
@testable import Compound

// Retriever fakes used by the runner suites. `StaticRetriever` (from
// Sources) covers the "fixed ranking, ignore the query" case; these cover
// failure and per-query control.

private struct ExplodingRetriever: Retriever {
    struct Boom: Error, CustomStringConvertible {
        var description: String { "index unavailable" }
    }
    func retrieve(query _: String, limit _: Int) async throws -> [RetrievedSource] {
        throw Boom()
    }
}

/// Returns a canned ranking per query; unknown queries return nothing.
private struct TableRetriever: Retriever {
    let table: [String: [RetrievedSource]]
    func retrieve(query: String, limit: Int) async throws -> [RetrievedSource] {
        Array((table[query] ?? []).prefix(limit))
    }
}

private func source(_ id: String, score: Double? = nil) -> RetrievedSource {
    RetrievedSource(id: id, title: id, content: id, score: score)
}

@Suite("RetrievalMetrics")
struct RetrievalMetricsTests {
    // retrieved: a b c d, relevant: b d e (three relevant, one unretrieved)
    private let retrieved = ["a", "b", "c", "d"]
    private let relevant: Set<String> = ["b", "d", "e"]

    @Test("recall@k counts hits against the full relevant set")
    func recall() {
        #expect(RetrievalMetrics.recallAtK(retrieved: retrieved, relevant: relevant, k: 1) == 0.0)
        #expect(RetrievalMetrics.recallAtK(retrieved: retrieved, relevant: relevant, k: 2) == 1.0 / 3.0)
        #expect(RetrievalMetrics.recallAtK(retrieved: retrieved, relevant: relevant, k: 4) == 2.0 / 3.0)
    }

    @Test("k larger than the result list consumes the whole list")
    func recallBeyondResults() {
        // Recall must not shrink just because k outran the results, and it
        // must not exceed what was actually retrieved either.
        #expect(RetrievalMetrics.recallAtK(retrieved: retrieved, relevant: relevant, k: 100) == 2.0 / 3.0)
        #expect(RetrievalMetrics.precisionAtK(retrieved: retrieved, relevant: relevant, k: 100) == 0.5)
        #expect(RetrievalMetrics.topK(retrieved, k: 100) == retrieved)
    }

    @Test("precision@k divides by the results actually returned")
    func precision() {
        #expect(RetrievalMetrics.precisionAtK(retrieved: retrieved, relevant: relevant, k: 1) == 0.0)
        #expect(RetrievalMetrics.precisionAtK(retrieved: retrieved, relevant: relevant, k: 2) == 0.5)
        #expect(RetrievalMetrics.precisionAtK(retrieved: retrieved, relevant: relevant, k: 4) == 0.5)
        // Three results, all relevant, asked for ten: 1.0, not 0.3.
        #expect(RetrievalMetrics.precisionAtK(retrieved: ["b", "d", "e"], relevant: relevant, k: 10) == 1.0)
    }

    @Test("reciprocal rank finds the first hit, or zero within k")
    func reciprocalRank() {
        #expect(RetrievalMetrics.reciprocalRankAtK(retrieved: retrieved, relevant: relevant, k: 4) == 0.5)
        #expect(RetrievalMetrics.reciprocalRankAtK(retrieved: retrieved, relevant: relevant, k: 1) == 0.0)
        #expect(RetrievalMetrics.reciprocalRankAtK(retrieved: ["b"], relevant: relevant, k: 4) == 1.0)
        #expect(RetrievalMetrics.reciprocalRankAtK(retrieved: [], relevant: relevant, k: 4) == 0.0)
    }

    @Test("ndcg@k matches hand-computed graded values")
    func ndcgGraded() throws {
        // gains a=1 b=3 c=2, returned in the order c, a, b.
        // DCG@3  = 2/log2(2) + 1/log2(3) + 3/log2(4) = 4.130929753571458
        // IDCG@3 = 3/log2(2) + 2/log2(3) + 1/log2(4) = 4.761859507142916
        let gains = ["a": 1.0, "b": 3.0, "c": 2.0]
        let order = ["c", "a", "b"]
        let full = try #require(RetrievalMetrics.ndcgAtK(retrieved: order, gains: gains, k: 3))
        #expect(abs(full - 0.8675034925694372) < 1e-12)
        // At k = 2 the ideal prefix is [3, 2] and only c, a are scored.
        let cut = try #require(RetrievalMetrics.ndcgAtK(retrieved: order, gains: gains, k: 2))
        #expect(abs(cut - 0.617319681505689) < 1e-12)
    }

    @Test("ndcg is 1.0 for the ideal ordering and 0.0 when nothing relevant ranks")
    func ndcgBounds() {
        let gains = ["a": 1.0, "b": 3.0, "c": 2.0]
        #expect(RetrievalMetrics.ndcgAtK(retrieved: ["b", "c", "a"], gains: gains, k: 3) == 1.0)
        #expect(RetrievalMetrics.ndcgAtK(retrieved: ["x", "y"], gains: gains, k: 3) == 0.0)
        // Explicit zero-gain judgments are assessed-but-irrelevant, not hits.
        #expect(RetrievalMetrics.ndcgAtK(retrieved: ["z"], gains: ["z": 0.0, "b": 3.0], k: 3) == 0.0)
        #expect(RetrievalMetrics.recallAtK(retrieved: ["z"], relevant: Set(["b"]), k: 3) == 0.0)
    }

    @Test("undefined metrics return nil rather than a misleading zero or one")
    func undefinedCases() {
        // No relevant document: recall, ndcg, and RR have no meaning.
        #expect(RetrievalMetrics.recallAtK(retrieved: retrieved, relevant: [], k: 3) == nil)
        #expect(RetrievalMetrics.reciprocalRankAtK(retrieved: retrieved, relevant: [], k: 3) == nil)
        #expect(RetrievalMetrics.ndcgAtK(retrieved: retrieved, gains: [:], k: 3) == nil)
        #expect(RetrievalMetrics.ndcgAtK(retrieved: retrieved, gains: ["a": 0.0], k: 3) == nil)
        // Precision *is* defined with an empty relevant set — it is zero.
        #expect(RetrievalMetrics.precisionAtK(retrieved: retrieved, relevant: [], k: 3) == 0.0)
        // ...but not when nothing was retrieved.
        #expect(RetrievalMetrics.precisionAtK(retrieved: [], relevant: relevant, k: 3) == nil)
        #expect(RetrievalMetrics.recallAtK(retrieved: [], relevant: relevant, k: 3) == 0.0)
    }

    @Test("duplicate results are not credited twice and do not eat rank slots")
    func duplicatesCollapse() {
        #expect(RetrievalMetrics.topK(["a", "a", "b", "b", "c"], k: 3) == ["a", "b", "c"])
        // Without de-duplication this would be 2/2 = 1.0 precision and
        // 1/3 recall from a single relevant document.
        let dupes = ["b", "b", "a"]
        #expect(RetrievalMetrics.precisionAtK(retrieved: dupes, relevant: relevant, k: 2) == 0.5)
        #expect(RetrievalMetrics.recallAtK(retrieved: dupes, relevant: relevant, k: 2) == 1.0 / 3.0)
    }

    @Test("mean skips undefined values")
    func meanSkipsNil() {
        #expect(RetrievalMetrics.mean([1.0, nil, 0.0]) == 0.5)
        #expect(RetrievalMetrics.mean([nil, nil]) == nil)
        #expect(RetrievalMetrics.mean([]) == nil)
    }

    @Test("binary gains are graded gains of one")
    func binaryGains() {
        #expect(RetrievalMetrics.binaryGains(["a", "b"]) == ["a": 1.0, "b": 1.0])
        #expect(RetrievalMetrics.binaryGains([]).isEmpty)
    }

    @Test("score set bundles the metrics and the abstention signals")
    func scoreSet() {
        let results = [source("b", score: 3.5), source("x", score: 1.0)]
        let scores = RetrievalScores.compute(retrieved: results, gains: ["b": 2.0], k: 2)
        #expect(scores.k == 2)
        #expect(scores.recall == 1.0)
        #expect(scores.precision == 0.5)
        #expect(scores.reciprocalRank == 1.0)
        #expect(scores.ndcg == 1.0)
        #expect(scores.retrievedCount == 2)
        #expect(scores.relevantCount == 1)
        #expect(scores.topScore == 3.5)
        // Unscored results leave no floor to check against.
        let unscored = RetrievalScores.compute(retrieved: [source("b")], gains: ["b": 1.0], k: 1)
        #expect(unscored.topScore == nil)
    }
}

@Suite("RetrievalEvalRunner")
struct RetrievalEvalRunnerTests {
    // A seeded corpus with deterministic chunk ids. Ground truth below
    // references `chunk.id`, i.e. the same derivation any re-chunking of
    // this text would produce.
    private static let corpus: [DocumentChunk] = [
        DocumentChunk(documentID: "manual", ordinal: 0, content: "espresso machine descaling procedure using citric acid"),
        DocumentChunk(documentID: "manual", ordinal: 1, content: "grinder burr replacement schedule and torque"),
        DocumentChunk(documentID: "manual", ordinal: 2, content: "milk frothing temperature guidelines"),
        DocumentChunk(documentID: "manual", ordinal: 3, content: "warranty registration and support contact"),
    ]

    private static func suite() -> RetrievalEvalSuite {
        RetrievalEvalSuite(name: "manual-retrieval", cases: [
            RetrievalEvalCase(
                id: "descale",
                query: "descaling citric acid",
                relevantIDs: [corpus[0].id],
                tags: ["quality"]
            ),
            RetrievalEvalCase(
                id: "burr",
                query: "burr replacement",
                relevantIDs: [corpus[1].id],
                tags: ["quality"]
            ),
            RetrievalEvalCase(
                id: "off-corpus",
                query: "quantum chromodynamics lattice",
                relevantIDs: [],
                tags: ["abstention"]
            ),
        ])
    }

    @Test("full pass over a BM25 index with known ground truth")
    func fullPass() async throws {
        let bm25 = BM25Retriever(chunks: Self.corpus)
        let report = try await RetrievalEvalRunner(k: 3).run(Self.suite(), against: bm25)

        #expect(report.suiteName == "manual-retrieval")
        #expect(report.k == 3)
        // Declaration order is preserved even though cases run in parallel.
        #expect(report.cases.map(\.caseID) == ["descale", "burr", "off-corpus"])
        #expect(report.environment != nil)

        let descale = try #require(report.cases.first { $0.caseID == "descale" })
        #expect(descale.retrievedIDs.first == Self.corpus[0].id)
        let scores = try #require(descale.scores)
        #expect(scores.recall == 1.0)
        #expect(scores.reciprocalRank == 1.0)
        #expect(scores.ndcg == 1.0)
        #expect((scores.topScore ?? 0) > 0)

        // The abstention case retrieved nothing, so its recall/ndcg/RR are
        // undefined and must not drag the aggregate down.
        let off = try #require(report.cases.first { $0.caseID == "off-corpus" })
        #expect(off.isAbstention)
        #expect(off.retrievedIDs.isEmpty)
        #expect(off.scores?.recall == nil)
        #expect(off.scores?.precision == nil)

        let aggregate = report.aggregate
        #expect(aggregate.caseCount == 3)
        #expect(aggregate.completedCaseCount == 3)
        #expect(aggregate.erroredCaseCount == 0)
        #expect(aggregate.recallAtK == 1.0)
        #expect(aggregate.meanReciprocalRank == 1.0)
        #expect(aggregate.ndcgAtK == 1.0)
        // Only the two answerable cases returned anything, so only they
        // contribute a precision.
        #expect(aggregate.precisionAtK == 1.0)
        #expect(report.summary().contains("recall@3=1.000"))
    }

    @Test("tag-filtered aggregates slice one run")
    func taggedAggregates() async throws {
        let bm25 = BM25Retriever(chunks: Self.corpus)
        let report = try await RetrievalEvalRunner(k: 3).run(Self.suite(), against: bm25)
        #expect(report.aggregate(tags: ["quality"]).caseCount == 2)
        #expect(report.aggregate(tags: ["abstention"]).caseCount == 1)
        #expect(report.aggregate(tags: ["abstention"]).recallAtK == nil)
        #expect(report.aggregate(tags: ["nonexistent"]).caseCount == 0)
        #expect(Self.suite().filtered(tags: ["abstention"]).cases.map(\.id) == ["off-corpus"])
    }

    @Test("duplicate case ids are rejected before anything runs")
    func duplicateIDs() async throws {
        let suite = RetrievalEvalSuite(name: "dupes", cases: [
            RetrievalEvalCase(id: "x", query: "a", relevantIDs: []),
            RetrievalEvalCase(id: "x", query: "b", relevantIDs: []),
        ])
        await #expect(throws: EvalError.duplicateCaseID("x")) {
            _ = try await RetrievalEvalRunner(k: 1).run(suite, against: EmptyRetriever())
        }
    }

    @Test("a throwing retriever fails its own case, not the run")
    func retrieverErrorIsCaptured() async throws {
        let suite = RetrievalEvalSuite(name: "broken", cases: [
            RetrievalEvalCase(id: "one", query: "q", relevantIDs: ["gold"]),
        ])
        let report = try await RetrievalEvalRunner(k: 3).run(suite, against: ExplodingRetriever())
        let outcome = try #require(report.cases.first)
        #expect(outcome.scores == nil)
        #expect(outcome.retrievedIDs.isEmpty)
        #expect(outcome.relevantCount == 1)
        guard case .errored(let reason, _) = outcome.result else {
            Issue.record("expected an errored outcome, got \(outcome.result)")
            return
        }
        #expect(reason.contains("index unavailable"))
        // An error is not a zero score: it is excluded from the means and
        // counted separately so a broken index cannot look like a bad one.
        #expect(report.aggregate.erroredCaseCount == 1)
        #expect(report.aggregate.completedCaseCount == 0)
        #expect(report.aggregate.recallAtK == nil)
    }

    @Test("limit may exceed k: the longer list is recorded, the metrics stay at k")
    func limitAboveK() async throws {
        let retriever = StaticRetriever([
            source("x", score: 0.9), source("y", score: 0.8), source("gold", score: 0.7),
            source("z", score: 0.6), source("w", score: 0.5),
        ])
        let suite = RetrievalEvalSuite(name: "cut", cases: [
            RetrievalEvalCase(id: "one", query: "q", relevantIDs: ["gold"]),
        ])
        let report = try await RetrievalEvalRunner(k: 2, limit: 5).run(suite, against: retriever)
        let outcome = try #require(report.cases.first)
        #expect(outcome.retrievedIDs.count == 5)
        let scores = try #require(outcome.scores)
        #expect(scores.k == 2)
        #expect(scores.retrievedCount == 5)
        // "gold" sits at rank 3, outside the cutoff.
        #expect(scores.recall == 0.0)
        #expect(scores.reciprocalRank == 0.0)
        #expect(scores.precision == 0.0)
    }

    @Test("per-case hits carry the ground-truth gain")
    func hitsCarryGains() async throws {
        let retriever = TableRetriever(table: ["q": [source("a", score: 2.0), source("b", score: 1.0)]])
        let suite = RetrievalEvalSuite(name: "graded", cases: [
            RetrievalEvalCase(id: "one", query: "q", gains: ["a": 3.0, "b": 0.0]),
        ])
        let report = try await RetrievalEvalRunner(k: 2).run(suite, against: retriever)
        let outcome = try #require(report.cases.first)
        guard case .completed(let hits, _, _) = outcome.result else {
            Issue.record("expected a completed outcome, got \(outcome.result)")
            return
        }
        #expect(hits.map(\.id) == ["a", "b"])
        #expect(hits.map(\.gain) == [3.0, 0.0])
        #expect(hits.map(\.score) == [2.0, 1.0])
    }

    @Test("report survives a JSON round trip with its aggregates intact")
    func codableRoundTrip() async throws {
        let bm25 = BM25Retriever(chunks: Self.corpus)
        let report = try await RetrievalEvalRunner(k: 3).run(Self.suite(), against: bm25)
        let decoded = try RetrievalEvalReport(jsonData: report.jsonData())

        #expect(decoded.suiteName == report.suiteName)
        #expect(decoded.runID == report.runID)
        #expect(decoded.k == report.k)
        #expect(decoded.cases == report.cases)
        #expect(decoded.environment == report.environment)
        // Aggregates are derived, so a decoded report can never disagree
        // with its own rows.
        #expect(decoded.aggregate == report.aggregate)
        // ISO 8601 encoding is whole-second, so timestamps round-trip at
        // second granularity — fine for a stored baseline, and the reason
        // per-case durations are carried as integer nanoseconds instead.
        #expect(abs(decoded.started.timeIntervalSince(report.started)) < 1.0)
    }

    @Test("suites are Codable so ground truth can live on disk")
    func suiteRoundTrip() throws {
        let suite = Self.suite()
        let data = try JSONEncoder().encode(suite)
        let decoded = try JSONDecoder().decode(RetrievalEvalSuite.self, from: data)
        #expect(decoded == suite)
        #expect(decoded.cases[0].relevantIDs == [Self.corpus[0].id])
        #expect(decoded.cases[2].isAbstention)
    }
}

@Suite("RetrievalRobustness")
struct RetrievalRobustnessTests {
    private static let gold = DocumentChunk(
        documentID: "manual",
        ordinal: 0,
        content: "espresso machine descaling procedure using citric acid"
    )
    private static let filler = [
        DocumentChunk(documentID: "manual", ordinal: 1, content: "grinder burr replacement schedule and torque"),
        DocumentChunk(documentID: "manual", ordinal: 2, content: "milk frothing temperature guidelines"),
    ]

    @Test("near-duplicates are deterministic, distinct, and query-matching")
    func nearDuplicatesAreDeterministic() {
        let first = RetrievalRobustness.nearDuplicates(of: Self.gold, count: 3)
        let second = RetrievalRobustness.nearDuplicates(of: Self.gold, count: 3)
        #expect(first.count == 3)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == 3)
        #expect(!first.map(\.id).contains(Self.gold.id))
        // Each distractor still contains every term of the original, which
        // is what makes it a hard negative rather than filler.
        #expect(first.allSatisfy { $0.content.hasPrefix(Self.gold.content) })
        #expect(first.allSatisfy { $0.content.contains(RetrievalRobustness.distractorMarker) })
        #expect(RetrievalRobustness.nearDuplicates(of: Self.gold, count: 0).isEmpty)
    }

    @Test("rank stability is hand-computable from two id lists")
    func rankStabilityMath() throws {
        // baseline a b c d, perturbed a c b e at k = 4.
        // common (baseline order) = a, b, c; d fell out, e is new.
        let stability = RetrievalRobustness.rankStability(
            baseline: ["a", "b", "c", "d"],
            perturbed: ["a", "c", "b", "e"],
            k: 4
        )
        #expect(stability.k == 4)
        #expect(stability.overlap == 0.75)
        #expect(stability.topRankRetained)
        #expect(stability.maxDisplacement == 1)
        // Pairs (a,b) and (a,c) keep their order; (b,c) inverts.
        let tau = try #require(stability.kendallTau)
        #expect(abs(tau - 1.0 / 3.0) < 1e-12)
        #expect(!stability.isFullyStable)
    }

    @Test("an untouched ranking is fully stable; an empty one is undefined")
    func rankStabilityEdges() {
        let same = RetrievalRobustness.rankStability(baseline: ["a", "b"], perturbed: ["a", "b"], k: 5)
        #expect(same.overlap == 1.0)
        #expect(same.maxDisplacement == 0)
        #expect(same.kendallTau == 1.0)
        #expect(same.isFullyStable)

        let empty = RetrievalRobustness.rankStability(baseline: [], perturbed: [], k: 3)
        #expect(empty.overlap == nil)
        #expect(empty.maxDisplacement == nil)
        #expect(empty.kendallTau == nil)
        #expect(empty.topRankRetained)

        let displaced = RetrievalRobustness.rankStability(baseline: ["a"], perturbed: ["z", "a"], k: 3)
        #expect(displaced.overlap == 1.0)
        #expect(!displaced.topRankRetained)
        #expect(displaced.maxDisplacement == 1)
        #expect(displaced.kendallTau == nil)
        #expect(!displaced.isFullyStable)
    }

    @Test("distractor injection does not displace the gold chunk")
    func distractorSuite() async throws {
        let clean = BM25Retriever(chunks: [Self.gold] + Self.filler)
        let distractors = RetrievalRobustness.nearDuplicates(of: Self.gold, count: 5)
        let noisy = BM25Retriever(chunks: [Self.gold] + Self.filler + distractors)

        let query = "descaling citric acid"
        // Sanity: the distractors really did enter the candidate set.
        let noisyResults = try await noisy.retrieve(query: query, limit: 10)
        #expect(noisyResults.count == 6)

        let stability = try await RetrievalRobustness.rankStability(
            query: query,
            baseline: clean,
            perturbed: noisy,
            k: 5
        )
        #expect(stability.topRankRetained)
        #expect(stability.overlap == 1.0)
        #expect(stability.maxDisplacement == 0)
        #expect(stability.isFullyStable)
    }

    @Test("distractors cost precision even when rank 1 holds")
    func distractorsCostPrecision() async throws {
        let distractors = RetrievalRobustness.nearDuplicates(of: Self.gold, count: 5)
        let noisy = BM25Retriever(chunks: [Self.gold] + Self.filler + distractors)
        let suite = RetrievalEvalSuite(name: "distractors", cases: [
            RetrievalEvalCase(
                id: "descale",
                query: "descaling citric acid",
                relevantIDs: [Self.gold.id],
                tags: ["distractor"]
            ),
        ])
        let report = try await RetrievalEvalRunner(k: 5).run(suite, against: noisy)
        let scores = try #require(report.cases.first?.scores)
        #expect(scores.reciprocalRank == 1.0)
        #expect(scores.recall == 1.0)
        // One relevant chunk among five returned.
        #expect(scores.precision == 0.2)
    }

    @Test("abstention: an empty result set counts as declining")
    func abstentionByEmptyResult() async throws {
        let corpus = [Self.gold] + Self.filler
        let suite = RetrievalEvalSuite(name: "abstain", cases: [
            RetrievalEvalCase(id: "off-corpus", query: "quantum chromodynamics", relevantIDs: []),
            RetrievalEvalCase(id: "answerable", query: "descaling", relevantIDs: [Self.gold.id]),
        ])
        let report = try await RetrievalEvalRunner(k: 5).run(suite, against: BM25Retriever(chunks: corpus))
        let summary = report.abstention()
        // Only the abstention case is judged; the answerable one is not.
        #expect(summary.caseCount == 1)
        #expect(summary.abstainedCount == 1)
        #expect(summary.erroredCaseCount == 0)
        #expect(summary.rate == 1.0)
        #expect(summary.violations.isEmpty)
        #expect(summary.outcomes.first?.returnedCount == 0)
        #expect(summary.outcomes.first?.topScore == nil)
    }

    @Test("abstention: a retriever that always answers needs a score floor")
    func abstentionByScoreFloor() async throws {
        // StaticRetriever ignores the query and always returns its list —
        // the behavior of any retriever that hands back its `limit` best
        // guesses regardless of how weak they are.
        let alwaysAnswers = StaticRetriever([source("junk", score: 0.05), source("more-junk", score: 0.01)])
        let suite = RetrievalEvalSuite(name: "abstain", cases: [
            RetrievalEvalCase(id: "off-corpus", query: "quantum chromodynamics", relevantIDs: []),
        ])
        let report = try await RetrievalEvalRunner(k: 2).run(suite, against: alwaysAnswers)

        // With no floor, answering at all is a violation.
        let strict = report.abstention()
        #expect(strict.abstainedCount == 0)
        #expect(strict.violations.map(\.caseID) == ["off-corpus"])
        #expect(strict.rate == 0.0)

        // With a floor above the best score, a caller could threshold this
        // away — which is what the suite is really measuring.
        let thresholded = report.abstention(scoreFloor: 0.1)
        #expect(thresholded.abstainedCount == 1)
        #expect(thresholded.violations.isEmpty)
        #expect(thresholded.outcomes.first?.topScore == 0.05)

        // A floor below the best score does not rescue it.
        #expect(report.abstention(scoreFloor: 0.01).abstainedCount == 0)
    }

    @Test("an errored abstention case is reported separately, never as a decision")
    func abstentionErrorsAreNotDecisions() async throws {
        let suite = RetrievalEvalSuite(name: "abstain", cases: [
            RetrievalEvalCase(id: "off-corpus", query: "anything", relevantIDs: []),
        ])
        let report = try await RetrievalEvalRunner(k: 2).run(suite, against: ExplodingRetriever())
        let summary = report.abstention()
        #expect(summary.caseCount == 0)
        #expect(summary.abstainedCount == 0)
        #expect(summary.erroredCaseCount == 1)
        #expect(summary.rate == 0.0)
    }

    @Test("abstention and rank-stability records are Codable")
    func robustnessRecordsRoundTrip() throws {
        let stability = RetrievalRobustness.rankStability(baseline: ["a", "b"], perturbed: ["b", "a"], k: 2)
        let decodedStability = try JSONDecoder().decode(
            RankStability.self,
            from: JSONEncoder().encode(stability)
        )
        #expect(decodedStability == stability)

        let summary = AbstentionSummary(
            caseCount: 1,
            abstainedCount: 1,
            erroredCaseCount: 0,
            outcomes: [AbstentionOutcome(caseID: "x", abstained: true, returnedCount: 0, topScore: nil)]
        )
        let decodedSummary = try JSONDecoder().decode(
            AbstentionSummary.self,
            from: JSONEncoder().encode(summary)
        )
        #expect(decodedSummary == summary)
    }
}
