import Foundation
import Testing
@testable import Compound

// Unit coverage of the memory eval harness itself, plus the two
// measurements it composes with the existing harnesses (archival retrieval
// through `RetrievalEvalRunner`, budget adherence through `EvalRunner`).
//
// An eval that is wrong is worse than no eval: it produces a number people
// act on. So the grading rule, the ordering guarantees, and the
// normalization contract are all asserted here rather than assumed by the
// gate.

// MARK: - Fakes

/// Returns a fixed source list regardless of the query.
private struct FixedRetriever: Retriever {
    let sources: [RetrievedSource]
    func retrieve(query _: String, limit: Int) async throws -> [RetrievedSource] {
        Array(sources.prefix(limit))
    }
}

/// Throws for one designated query and answers normally otherwise.
private struct SelectivelyFailingRetriever: Retriever {
    let failOn: String
    let sources: [RetrievedSource]

    struct Boom: Error, CustomStringConvertible {
        var description: String { "retriever exploded" }
    }

    func retrieve(query: String, limit: Int) async throws -> [RetrievedSource] {
        if query == failOn { throw Boom() }
        return Array(sources.prefix(limit))
    }
}

/// Sleeps a query-dependent amount so a concurrent runner would return
/// results out of declaration order if it did not restore it.
private struct StaggeredRetriever: Retriever {
    func retrieve(query: String, limit _: Int) async throws -> [RetrievedSource] {
        // Longest query finishes first.
        try await Task.sleep(for: .milliseconds(max(0, 40 - query.count)))
        return [RetrievedSource(id: query, title: query, content: query, score: 1)]
    }
}

private func source(_ id: String, title: String, content: String) -> RetrievedSource {
    RetrievedSource(id: id, title: title, content: content, score: 1)
}

private let unitProvenance = MemoryEvalReport.Provenance(
    embedder: "unit",
    extractor: "unit",
    reconciler: "unit",
    promptVersion: "none",
    modelAvailability: "unavailable: test"
)

// MARK: - Blob predicate

@Suite("MemoryEvalBlob")
struct MemoryEvalBlobTests {

    @Test("a term present only in a title counts as present")
    func titleCountsAsEvidence() async throws {
        // Archival provenance — thread and round — rides in the title,
        // because `RetrievedSource` has no metadata field. If the blob
        // ignored titles, a case could not assert that recalled transcript
        // arrived with its attribution.
        let retriever = FixedRetriever(sources: [
            source("a", title: "thread t1 round 7 [2024-01-01T00:00:00Z]", content: "some body text")
        ])
        let c = MemoryEvalCase(id: "t", query: "q", mustContain: ["round 7"], k: 5)
        let report = try await MemoryEvalRunner().run(
            MemoryEvalSuite(name: "s", cases: [c]),
            against: retriever,
            provenance: unitProvenance
        )
        #expect(report.cases[0].passed)
    }

    @Test("a term present only at rank k+1 is missing")
    func rankCutoffIsEnforced() async throws {
        // The blob is the top-k window, not the whole result list. A system
        // that surfaces the right fact at rank 11 did not surface it.
        let sources = (1...6).map { source("s\($0)", title: "t\($0)", content: "body \($0)") }
        let c = MemoryEvalCase(id: "t", query: "q", mustContain: ["body 6"], k: 5)
        let report = try await MemoryEvalRunner().run(
            MemoryEvalSuite(name: "s", cases: [c]),
            against: FixedRetriever(sources: sources),
            provenance: unitProvenance
        )
        #expect(!report.cases[0].passed)
        #expect(report.cases[0].missing == ["body 6"])
        // The retriever was asked for exactly k, so the ranked list the
        // report stores is the graded window and nothing more.
        #expect(report.cases[0].retrievedIDs.count == 5)
    }

    @Test("normalization catches case and whitespace variants of a forbidden term")
    func normalizationCatchesVariants() async throws {
        // A forgotten fact that comes back with different capitalization or
        // a line break in the middle is still back. Matching the raw string
        // would let exactly that through.
        let retriever = FixedRetriever(sources: [
            source("a", title: "T", content: "Kestrel   Migration\nWas   Cancelled")
        ])
        let c = MemoryEvalCase(
            id: "t",
            query: "q",
            mustNotContain: ["kestrel migration was cancelled"],
            k: 5
        )
        let report = try await MemoryEvalRunner().run(
            MemoryEvalSuite(name: "s", cases: [c]),
            against: retriever,
            provenance: unitProvenance
        )
        #expect(!report.cases[0].passed)
        #expect(report.cases[0].forbidden == ["kestrel migration was cancelled"])
    }

    @Test("normalization folds NFD to NFC on both sides")
    func normalizationFoldsUnicode() {
        // Decomposed input from one source and precomposed from another must
        // not read as different text.
        let decomposed = "Cafe\u{0301} Re\u{0301}sume\u{0301}"
        let precomposed = "Café Résumé"
        #expect(MemoryEvalBlob.normalize(decomposed) == MemoryEvalBlob.normalize(precomposed))
    }

    @Test("duplicate ids do not consume a rank slot")
    func duplicatesDoNotConsumeSlots() {
        // Same rule `RetrievalMetrics.topK` follows: a retriever must not
        // spend the graded window on its own duplicate.
        let sources = [
            source("a", title: "t", content: "alpha"),
            source("a", title: "t", content: "alpha"),
            source("b", title: "t", content: "bravo"),
        ]
        let blob = MemoryEvalBlob.build(from: sources, k: 2)
        #expect(blob.contains("bravo"))
    }
}

// MARK: - Runner

@Suite("MemoryEvalRunner")
struct MemoryEvalRunnerTests {

    @Test("duplicate case ids throw")
    func duplicateIDsThrow() async {
        let suite = MemoryEvalSuite(name: "s", cases: [
            MemoryEvalCase(id: "dup", query: "a"),
            MemoryEvalCase(id: "dup", query: "b"),
        ])
        await #expect(throws: EvalError.duplicateCaseID("dup")) {
            _ = try await MemoryEvalRunner().run(
                suite,
                against: EmptyRetriever(),
                provenance: unitProvenance
            )
        }
    }

    @Test("a throwing retriever fails only its own case")
    func throwingRetrieverIsIsolated() async throws {
        let retriever = SelectivelyFailingRetriever(
            failOn: "boom",
            sources: [source("a", title: "t", content: "alpha")]
        )
        let suite = MemoryEvalSuite(name: "s", cases: [
            MemoryEvalCase(id: "ok", query: "fine", mustContain: ["alpha"]),
            MemoryEvalCase(id: "bad", query: "boom", mustContain: ["alpha"]),
        ])
        let report = try await MemoryEvalRunner().run(
            suite,
            against: retriever,
            provenance: unitProvenance
        )
        #expect(report.cases[0].passed)
        #expect(!report.cases[1].passed)
        // An outage and a recall miss must stay distinguishable: the error
        // is recorded, and the required terms are still listed as missing so
        // the row grades as failed rather than as inconclusive.
        #expect(report.cases[1].error?.contains("exploded") == true)
        #expect(report.cases[1].missing == ["alpha"])
        #expect(report.cases[0].error == nil)
    }

    @Test("declaration order survives concurrency")
    func declarationOrderIsPreserved() async throws {
        let cases = ["aaaaaaaaaa", "aaaaa", "aa", "aaaaaaa"].enumerated().map {
            MemoryEvalCase(id: "case-\($0.offset)", query: $0.element)
        }
        let report = try await MemoryEvalRunner(concurrency: 4).run(
            MemoryEvalSuite(name: "s", cases: cases),
            against: StaggeredRetriever(),
            provenance: unitProvenance
        )
        #expect(report.cases.map(\.caseID) == cases.map(\.id))
    }

    @Test("provenance and write-path cost reach the report")
    func provenanceReachesTheReport() async throws {
        let cost = MemoryEvalReport.WritePathCost(
            modelCalls: 3,
            promptTokens: 400,
            wallClockNanoseconds: 12_345
        )
        let report = try await MemoryEvalRunner().run(
            MemoryEvalSuite(name: "s", cases: [MemoryEvalCase(id: "a", query: "q")]),
            against: EmptyRetriever(),
            provenance: unitProvenance,
            writePath: cost
        )
        #expect(report.provenance == unitProvenance)
        #expect(report.writePath == cost)
    }
}

// MARK: - Report

@Suite("MemoryEvalReport")
struct MemoryEvalReportTests {

    private func outcome(_ id: String, passed: Bool, tags: [String] = []) -> MemoryEvalReport.CaseOutcome {
        MemoryEvalReport.CaseOutcome(
            caseID: id,
            query: "q-\(id)",
            tags: tags,
            passed: passed,
            missing: passed ? [] : ["x"],
            forbidden: [],
            retrievedIDs: ["r1"],
            elapsed: .milliseconds(7)
        )
    }

    private func report(_ outcomes: [MemoryEvalReport.CaseOutcome]) -> MemoryEvalReport {
        MemoryEvalReport(
            suiteName: "s",
            started: Date(timeIntervalSince1970: 100),
            finished: Date(timeIntervalSince1970: 200),
            cases: outcomes,
            environment: .init(osVersion: "os", modelAvailability: "unavailable: test"),
            provenance: unitProvenance,
            writePath: .init(modelCalls: 1, promptTokens: 2, wallClockNanoseconds: 3)
        )
    }

    @Test("normalizedForBaseline zeroes every clock- and UUID-derived field")
    func normalizationZeroesVolatileFields() {
        let normalized = report([outcome("a", passed: true)]).normalizedForBaseline()
        #expect(normalized.started == Date(timeIntervalSince1970: 0))
        #expect(normalized.finished == Date(timeIntervalSince1970: 0))
        #expect(normalized.runID == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        #expect(normalized.cases[0].elapsed == .zero)
        #expect(normalized.writePath.wallClockNanoseconds == 0)
        // Deterministic cost survives: a baseline that starts spending model
        // calls is precisely the change a reviewer must see in the diff.
        #expect(normalized.writePath.modelCalls == 1)
        #expect(normalized.writePath.promptTokens == 2)
        #expect(normalized.environment?.osVersion == "os")
        #expect(normalized.provenance == unitProvenance)
    }

    @Test("report round-trips through JSON")
    func roundTrips() throws {
        let original = report([
            outcome("a", passed: true, tags: ["supersession"]),
            outcome("b", passed: false, tags: ["decay"]),
        ]).normalizedForBaseline()
        let decoded = try MemoryEvalReport(jsonData: original.jsonData())
        #expect(decoded == original)
    }

    @Test("tagged aggregates slice the suite")
    func taggedAggregates() {
        let r = report([
            outcome("a", passed: true, tags: ["supersession"]),
            outcome("b", passed: false, tags: ["obfuscation"]),
            outcome("c", passed: true, tags: ["supersession"]),
        ])
        #expect(r.aggregate.caseCount == 3)
        #expect(r.aggregate.passedCount == 2)
        #expect(r.aggregate(tags: ["supersession"]).passRate == 1.0)
        #expect(r.aggregate(tags: ["obfuscation"]).passRate == 0.0)
    }

    @Test("delta is candidate minus control")
    func deltaArithmetic() {
        let candidate = report([outcome("a", passed: true), outcome("b", passed: true)])
        let control = report([outcome("a", passed: true), outcome("b", passed: false)])
        #expect(candidate.delta(from: control) == 0.5)
        #expect(control.delta(from: candidate) == -0.5)
    }

    @Test("the EvalGate bridge preserves verdicts and names the failing half")
    func evalReportBridge() {
        let r = report([
            outcome("pass", passed: true),
            MemoryEvalReport.CaseOutcome(
                caseID: "forbidden",
                query: "q",
                tags: [],
                passed: false,
                missing: [],
                forbidden: ["berlin"],
                retrievedIDs: [],
                elapsed: .zero
            ),
        ])
        let bridged = r.evalReport()
        #expect(bridged.passRate == 0.5)
        // "the right memory did not surface" and "the forgotten memory came
        // back" are different bugs; the bridge keeps them apart in CI output.
        let failing = bridged.cases[1]
        guard case .completed(_, let checks, _) = failing.result else {
            Issue.record("expected a completed outcome")
            return
        }
        #expect(checks.first { $0.name == "must-contain" }?.check.passed == true)
        #expect(checks.first { $0.name == "must-not-contain" }?.check.passed == false)
        #expect(checks.first { $0.name == "must-not-contain" }?.check.message?.contains("berlin") == true)
    }

    @Test("a retriever failure bridges to an errored outcome, not a failed check")
    func errorBridgesAsErrored() {
        let r = report([
            MemoryEvalReport.CaseOutcome(
                caseID: "boom",
                query: "q",
                tags: [],
                passed: false,
                missing: ["x"],
                forbidden: [],
                retrievedIDs: [],
                error: "retriever exploded",
                elapsed: .zero
            )
        ])
        guard case .errored(let reason, _) = r.evalReport().cases[0].result else {
            Issue.record("expected an errored outcome")
            return
        }
        #expect(reason == "retriever exploded")
    }
}

// MARK: - End-to-end against the fixtures

@Suite("MemoryEvalSuiteBehavior")
struct MemoryEvalSuiteBehaviorTests {

    private func run(_ retriever: any Retriever) async throws -> MemoryEvalReport {
        try await MemoryEvalCases.runner.run(
            MemoryEvalCases.suite,
            against: retriever,
            provenance: MemoryEvalFixtures.provenance
        )
    }

    @Test("memory beats the memory-off control overall")
    func memoryBeatsControl() async throws {
        // The rule MemDelta makes necessary, executable: agent self-memory
        // there scored 42% against 47% for plain retrieval on the same
        // questions. A memory layer that does not beat "just retrieve the
        // transcript" is cost without benefit, and the suite refuses to
        // bless one.
        let world = try await MemoryEvalFixtures.make()
        let candidate = try await run(world.memoryRetriever)
        let control = try await run(world.controlRetriever)
        #expect(
            candidate.delta(from: control) > 0,
            """
            memory-on \(candidate.passRate) did not beat memory-off \(control.passRate)

            \(candidate.detailedReport())
            \(control.detailedReport())
            """
        )
    }

    @Test("memory is not worse than the control on any measured family")
    func memoryIsNotWorsePerFamily() async throws {
        // An overall win can hide a family the memory layer actively broke,
        // so the delta is asserted per family too. Supersession and
        // fact-recall are called out in the spec; checking all of them is
        // strictly stronger and costs nothing.
        let world = try await MemoryEvalFixtures.make()
        let candidate = try await run(world.memoryRetriever)
        let control = try await run(world.controlRetriever)
        let families = Set(MemoryEvalCases.all.flatMap(\.tags))
        for family in families.sorted() {
            let delta = candidate.delta(from: control, tags: [family])
            #expect(delta >= 0, "family '\(family)' regressed against the control by \(-delta)")
        }
        // The two the spec names must be strictly better, not merely equal.
        #expect(candidate.delta(from: control, tags: ["supersession"]) > 0)
        #expect(candidate.delta(from: control, tags: ["fact-recall"]) > 0)
    }

    @Test("write-path cost is zero for the deterministic configuration")
    func writePathIsZero() async throws {
        // The fixture wires no model-backed hook anywhere, so a non-zero
        // cost would mean one crept in. Measured through the tracer rather
        // than asserted as a constant, so the measurement itself is covered.
        let tracer = InMemoryTracer()
        _ = try await MemoryEvalFixtures.make()
        let cost = await MemoryEvalReport.WritePathCost.measure(tracer: tracer)
        #expect(cost == .zero)
    }

    @Test("write-path cost is read out of the trace when there is one")
    func writePathReadsTheTrace() async throws {
        let tracer = InMemoryTracer()
        let runID = UUID()
        await tracer.record(.modelInvocationStarted(runID: runID, turn: 1, promptBytes: 400))
        await tracer.record(.memoryConsolidated(
            runID: runID,
            extracted: 3, added: 2, updated: 1, deleted: 0, archived: 1,
            modelCalls: 2,
            elapsed: .milliseconds(5)
        ))
        let cost = await MemoryEvalReport.WritePathCost.measure(tracer: tracer)
        #expect(cost.modelCalls == 2)
        #expect(cost.promptTokens == 100)
        #expect(cost.wallClockNanoseconds == 5_000_000)
    }

    @Test("the whole suite is byte-identical across five runs")
    func fullDeterminism() async throws {
        // The property the committed baseline rests on. Five runs, five
        // freshly built worlds — so a fixture that accidentally read a
        // clock, minted a UUID, or leaked dictionary iteration order into a
        // result shows up here rather than as a mystery CI diff.
        var encodings: [Data] = []
        for _ in 0..<5 {
            let world = try await MemoryEvalFixtures.make()
            encodings.append(try await run(world.memoryRetriever).normalizedForBaseline().jsonData())
        }
        #expect(Set(encodings).count == 1)
    }

    @Test("archival chunk ids are stable across worlds")
    func archivalIDsAreStable() async throws {
        // Content-derived ids are what let a stored `RetrievalEvalCase` keep
        // pointing at the same round. A fresh `UUID()` reaching a message id
        // would break this and nothing else.
        let a = try await MemoryEvalFixtures.make()
        let b = try await MemoryEvalFixtures.make()
        #expect(a.rounds.map(\.id) == b.rounds.map(\.id))
        #expect(!a.rounds.isEmpty)
    }
}

// MARK: - Archival retrieval accuracy

@Suite("MemoryArchivalRetrievalEval")
struct MemoryArchivalRetrievalEvalTests {

    @Test("archival retrieval scores through the existing retrieval harness")
    func archivalMetrics() async throws {
        // Zero new metric code: `ArchivalRetriever` is a `Retriever` and an
        // `ArchivedRound.id` is a `DocumentChunker.chunkID`, so recall@k,
        // nDCG@k and MRR come straight from `RetrievalEvalRunner`.
        let world = try await MemoryEvalFixtures.make()
        let report = try await RetrievalEvalRunner(k: MemoryArchivalEvalCases.k, limit: 10)
            .run(MemoryArchivalEvalCases.suite(world), against: world.archivalRetriever)

        let graded = report.cases.filter { !$0.isAbstention }
        #expect(graded.count == 4)
        #expect(report.aggregate.erroredCaseCount == 0)
        let aggregate = report.aggregate
        #expect((aggregate.recallAtK ?? 0) == 1.0)
        #expect((aggregate.ndcgAtK ?? 0) == 1.0)
        #expect((aggregate.meanReciprocalRank ?? 0) == 1.0)
    }

    @Test("the abstention case is measured, not silently excluded")
    func abstentionIsMeasured() async throws {
        // `RetrievalMetrics` returns nil — not zero — where a metric is
        // undefined, so an abstention case must not drag mean recall down.
        // It still has to be present and scored on precision.
        let world = try await MemoryEvalFixtures.make()
        let report = try await RetrievalEvalRunner(k: MemoryArchivalEvalCases.k, limit: 10)
            .run(MemoryArchivalEvalCases.suite(world), against: world.archivalRetriever)
        let abstention = try #require(report.cases.first { $0.caseID == "archival/abstention-unknown-topic" })
        #expect(abstention.isAbstention)
        let scores = try #require(abstention.scores)
        #expect(scores.recall == nil)
        #expect(scores.precision == 0.0)
    }

    @Test("a purged round is unreachable through the archive")
    func purgedRoundIsUnreachable() async throws {
        // The fixture's purge went through an index that failed once, so
        // this is the state the *retry* left behind. Asserted on both
        // indexes directly, because a removal that reached only the lexical
        // side still serves the content through the vector side.
        let world = try await MemoryEvalFixtures.make()
        let survivingIDs = Set(world.rounds.map(\.id))
        let hits = try await world.archive.retrieve(
            query: "acct-77219 billing account Borealis compute spend",
            limit: 10,
            threadID: world.threadID
        )
        #expect(hits.allSatisfy { survivingIDs.contains($0.round.id) })
        #expect(hits.allSatisfy { !$0.round.displayText.contains("acct-77219") })
        #expect(try await world.archive.pendingRemovalIDs().isEmpty)
    }

    @Test("removal reached both the lexical and the vector index")
    func removalFannedOut() async throws {
        let world = try await MemoryEvalFixtures.make()
        let survivingIDs = Set(world.rounds.map(\.id))
        // Every id the journal no longer knows about must be gone from both
        // actors. ForgetEval measured these as complementary rather than
        // redundant (32/39 vs 12/39 on prefix collision, 21/38 vs 0/38 on
        // aliases), so "removed from one" is not removed.
        let built = RoundBuilder.rounds(
            from: Array(MemoryEvalFixtures.messages.prefix(MemoryEvalFixtures.archivedMessageCount)),
            threadID: MemoryEvalFixtures.threadID
        ).rounds
        let removed = built.map(\.id).filter { !survivingIDs.contains($0) }
        #expect(removed.count == 2, "the fixture should have removed the Kestrel and billing rounds")
        for id in removed {
            #expect(!(await world.archiveLexical.contains(id: id)), "lexical index still holds \(id)")
            #expect(!(await world.archiveVector.contains(id: id)), "vector index still holds \(id)")
        }
    }
}

// MARK: - Token budget adherence

@Suite("MemoryBudgetEval")
struct MemoryBudgetEvalTests {

    @Test("budget scenarios all hold under the shipping defaults")
    func budgetScenariosHold() async throws {
        let world = try await MemoryEvalFixtures.make()
        let report = try await EvalRunner(concurrency: 2, caseTimeout: .seconds(20))
            .run(MemoryBudgetEvalCases.suite(world), against: MemoryBudgetEvalCases.target(world))
        #expect(report.passRate == 1.0, "\(report.detailedReport())")
    }

    @Test("budget scenarios are deterministic across runs")
    func budgetScenariosAreDeterministic() async throws {
        let world = try await MemoryEvalFixtures.make()
        let target = MemoryBudgetEvalCases.target(world)
        let suite = MemoryBudgetEvalCases.suite(world)
        var outputs: [[String]] = []
        for _ in 0..<3 {
            let report = try await EvalRunner(concurrency: 2).run(suite, against: target)
            outputs.append(report.cases.map { c in
                if case .completed(let output, _, _) = c.result { return output }
                return "non-completed"
            })
        }
        #expect(Set(outputs.map { $0.joined(separator: "|") }).count == 1)
    }
}
