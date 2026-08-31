import Foundation
import Testing
@testable import Compound

@Suite("Eval")
struct EvalTests {
    @Test("contains predicate")
    func containsPredicate() async throws {
        let p = ContainsPredicate("hello")
        let check = try await p.evaluate(output: "hello world", runContext: RunContext())
        #expect(check.passed)
        let miss = try await p.evaluate(output: "goodbye", runContext: RunContext())
        #expect(!miss.passed)
    }

    @Test("does-not-contain predicate")
    func doesNotContainPredicate() async throws {
        let p = DoesNotContainPredicate("bad")
        #expect((try await p.evaluate(output: "all good", runContext: RunContext())).passed)
        #expect(!(try await p.evaluate(output: "bad day", runContext: RunContext())).passed)
    }

    @Test("matches-regex predicate")
    func matchesRegexPredicate() async throws {
        let p = try MatchesRegexPredicate(#"^\d+$"#)
        #expect((try await p.evaluate(output: "42", runContext: RunContext())).passed)
        #expect(!(try await p.evaluate(output: "abc", runContext: RunContext())).passed)
    }

    @Test("verifier predicate maps verdict to check")
    func verifierPredicate() async throws {
        let p = VerifierPredicate(JSONParseVerifier())
        #expect((try await p.evaluate(output: #"{"a":1}"#, runContext: RunContext())).passed)
        #expect(!(try await p.evaluate(output: "not json", runContext: RunContext())).passed)
    }

    @Test("runner produces report with mixed outcomes")
    func runnerProducesReport() async throws {
        let target = StubEvalTarget([
            "hello?": "hello, friend",
            "fail?": "nope",
        ])
        let suite = EvalSuite(name: "demo", cases: [
            EvalCase(id: "case-1", prompt: "hello?", predicates: [
                ContainsPredicate("hello")
            ]),
            EvalCase(id: "case-2", prompt: "fail?", predicates: [
                ContainsPredicate("yes")
            ]),
        ])
        let runner = EvalRunner(concurrency: 2)
        let report = try await runner.run(suite, against: target)
        #expect(report.cases.count == 2)
        #expect(report.passed == 1)
        #expect(report.failed == 1)
        #expect(report.summary().contains("1/2"))
    }

    @Test("runner captures errors as errored result")
    func runnerCapturesErrors() async throws {
        struct ThrowingTarget: EvalTarget {
            struct E: Error {}
            func respond(to prompt: String, auth _: AuthContext, metadata _: [String: String]) async throws -> String { throw E() }
        }
        let suite = EvalSuite(name: "err", cases: [
            EvalCase(id: "throws", prompt: "x", predicates: [ContainsPredicate("y")])
        ])
        let report = try await EvalRunner().run(suite, against: ThrowingTarget())
        #expect(report.passed == 0)
        if case .errored = report.cases[0].result {
            // ok
        } else {
            Issue.record("expected .errored result")
        }
    }

    @Test("suite filters by tags")
    func filtersByTags() async throws {
        let suite = EvalSuite(name: "tagged", cases: [
            EvalCase(id: "a", prompt: "", predicates: [], tags: ["fast"]),
            EvalCase(id: "b", prompt: "", predicates: [], tags: ["slow"]),
            EvalCase(id: "c", prompt: "", predicates: [], tags: ["fast", "important"]),
        ])
        let filtered = suite.filtered(tags: ["fast"])
        #expect(filtered.cases.map(\.id) == ["a", "c"])
    }

    @Test("duplicate case ids throw instead of trapping")
    func duplicateCaseIDsThrow() async throws {
        let suite = EvalSuite(name: "dupes", cases: [
            EvalCase(id: "same", prompt: "a", predicates: []),
            EvalCase(id: "same", prompt: "b", predicates: []),
        ])
        await #expect(throws: EvalError.duplicateCaseID("same")) {
            _ = try await EvalRunner().run(suite, against: StubEvalTarget(["a": "x", "b": "y"]))
        }
    }

    @Test("stub target throws on unknown prompts")
    func stubThrowsOnUnknownPrompt() async throws {
        let stub = StubEvalTarget(["known": "output"])
        #expect(try await stub.respond(to: "known", auth: .anonymous, metadata: [:]) == "output")
        await #expect(throws: EvalError.unknownPrompt("mystery")) {
            _ = try await stub.respond(to: "mystery", auth: .anonymous, metadata: [:])
        }
        // Through the runner, an unknown prompt surfaces as an errored
        // case — it can no longer vacuously satisfy negative predicates.
        let suite = EvalSuite(name: "stub", cases: [
            EvalCase(id: "unknown", prompt: "mystery", predicates: [DoesNotContainPredicate("bad")])
        ])
        let report = try await EvalRunner().run(suite, against: stub)
        #expect(report.passed == 0)
        if case .errored = report.cases[0].result {
            // ok
        } else {
            Issue.record("expected .errored result for unknown stub prompt")
        }
    }

    @Test("hung case times out without hanging the suite")
    func hungCaseTimesOut() async throws {
        struct HangingTarget: EvalTarget {
            func respond(to prompt: String, auth _: AuthContext, metadata _: [String: String]) async throws -> String {
                if prompt == "hang" {
                    try await Task.sleep(for: .seconds(60))
                }
                return "done"
            }
        }
        let suite = EvalSuite(name: "timeouts", cases: [
            EvalCase(id: "hangs", prompt: "hang", predicates: [ContainsPredicate("done")]),
            EvalCase(id: "fast", prompt: "quick", predicates: [ContainsPredicate("done")]),
        ])
        let runner = EvalRunner(concurrency: 2, caseTimeout: .milliseconds(50))
        let report = try await runner.run(suite, against: HangingTarget())
        #expect(report.cases.count == 2)
        #expect(report.passed == 1)
        let hung = try #require(report.cases.first { $0.caseID == "hangs" })
        if case .timedOut = hung.result {
            #expect(!hung.passed)
        } else {
            Issue.record("expected .timedOut result, got \(hung.result)")
        }
    }

    @Test("report preserves declaration order under sliding-window concurrency")
    func preservesDeclarationOrder() async throws {
        // Earlier cases respond slower, so completion order inverts
        // declaration order; the report must still be stable.
        struct SlowFirstTarget: EvalTarget {
            func respond(to prompt: String, auth _: AuthContext, metadata _: [String: String]) async throws -> String {
                let index = Int(prompt) ?? 0
                try await Task.sleep(for: .milliseconds((8 - index) * 10))
                return "ok-\(prompt)"
            }
        }
        let cases = (0..<8).map { i in
            EvalCase(id: "case-\(i)", prompt: "\(i)", predicates: [ContainsPredicate("ok")])
        }
        let report = try await EvalRunner(concurrency: 3).run(
            EvalSuite(name: "order", cases: cases),
            against: SlowFirstTarget()
        )
        #expect(report.cases.map(\.caseID) == cases.map(\.id))
        #expect(report.passed == 8)
    }

    @Test("case outcomes surface distinct run ids")
    func surfacesRunIDs() async throws {
        let target = StubEvalTarget(["a": "1", "b": "2"])
        let suite = EvalSuite(name: "ids", cases: [
            EvalCase(id: "a", prompt: "a", predicates: []),
            EvalCase(id: "b", prompt: "b", predicates: []),
        ])
        let report = try await EvalRunner().run(suite, against: target)
        let ids = Set(report.cases.map(\.runID))
        #expect(ids.count == 2)
    }

    @Test("report round-trips through JSON")
    func reportRoundTripsThroughJSON() async throws {
        let target = StubEvalTarget(["hello?": "hello, friend"])
        let suite = EvalSuite(name: "codable", cases: [
            EvalCase(id: "case-1", prompt: "hello?", predicates: [ContainsPredicate("hello")]),
            EvalCase(id: "case-2", prompt: "missing", predicates: [ContainsPredicate("x")]),
        ])
        let report = try await EvalRunner(caseTimeout: .seconds(5)).run(suite, against: target)
        let data = try report.jsonData()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("elapsedNanoseconds"))

        let decoded = try EvalReport(jsonData: data)
        #expect(decoded.suiteName == report.suiteName)
        #expect(decoded.cases.count == report.cases.count)
        #expect(decoded.passed == report.passed)
        #expect(decoded.cases.map(\.caseID) == report.cases.map(\.caseID))
        #expect(decoded.cases.map(\.runID) == report.cases.map(\.runID))
        #expect(decoded.environment == report.environment)
        // ISO 8601 dates round-trip to sub-second-truncated instants.
        #expect(abs(decoded.started.timeIntervalSince(report.started)) < 1.0)
    }

    @Test("report records the execution environment")
    func recordsEnvironment() async throws {
        let report = try await EvalRunner().run(
            EvalSuite(name: "env", cases: []),
            against: StubEvalTarget([:])
        )
        let env = try #require(report.environment)
        #expect(!env.osVersion.isEmpty)
        #expect(!env.modelAvailability.isEmpty)
    }

    @Test("cancelling the calling task aborts the run")
    func cancellationAbortsRun() async throws {
        struct SleepyTarget: EvalTarget {
            func respond(to prompt: String, auth _: AuthContext, metadata _: [String: String]) async throws -> String {
                try await Task.sleep(for: .seconds(60))
                return "late"
            }
        }
        let cases = (0..<10).map { i in
            EvalCase(id: "case-\(i)", prompt: "\(i)", predicates: [])
        }
        let task = Task {
            try await EvalRunner(concurrency: 2).run(
                EvalSuite(name: "cancel", cases: cases),
                against: SleepyTarget()
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("gate passes when candidate holds the baseline")
    func gatePasses() throws {
        let baseline = Self.report(named: "base", passing: ["a", "b"], failing: [])
        let candidate = Self.report(named: "cand", passing: ["a", "b"], failing: [])
        let result = EvalGate(passRateThreshold: 1.0, tolerance: 0.0)
            .compare(baseline: baseline, candidate: candidate)
        #expect(result.passed)
        #expect(result.regressions.isEmpty)
        #expect(result.reasons.isEmpty)
        #expect(result.candidatePassRate == 1.0)
    }

    @Test("gate fails on threshold breach and lists per-case regressions")
    func gateFailsWithRegressions() throws {
        let baseline = Self.report(named: "base", passing: ["a", "b", "c"], failing: [])
        let candidate = Self.report(named: "cand", passing: ["a"], failing: ["b", "c"])
        let result = EvalGate(passRateThreshold: 0.9, tolerance: 0.0)
            .compare(baseline: baseline, candidate: candidate)
        #expect(!result.passed)
        #expect(result.regressions.map(\.caseID).sorted() == ["b", "c"])
        // Both the absolute threshold and the baseline comparison tripped.
        #expect(result.reasons.count == 2)
    }

    @Test("gate tolerance absorbs a small dip")
    func gateToleranceAbsorbsDip() throws {
        let baseline = Self.report(named: "base", passing: ["a", "b", "c", "d"], failing: [])
        let candidate = Self.report(named: "cand", passing: ["a", "b", "c"], failing: ["d"])
        let result = EvalGate(passRateThreshold: 0.7, tolerance: 0.3)
            .compare(baseline: baseline, candidate: candidate)
        #expect(result.passed)
        // The dip is tolerated for the verdict, but the regression is
        // still itemized for the log.
        #expect(result.regressions.map(\.caseID) == ["d"])
    }

    // MARK: - Helpers

    private static func report(named name: String, passing: [String], failing: [String]) -> EvalReport {
        var outcomes: [EvalReport.CaseOutcome] = []
        for id in passing {
            outcomes.append(EvalReport.CaseOutcome(
                caseID: id,
                prompt: id,
                runID: UUID(),
                result: .completed(output: "ok", checks: [
                    .init(name: "contains:ok", check: .pass)
                ], elapsed: .milliseconds(1))
            ))
        }
        for id in failing {
            outcomes.append(EvalReport.CaseOutcome(
                caseID: id,
                prompt: id,
                runID: UUID(),
                result: .completed(output: "nope", checks: [
                    .init(name: "contains:ok", check: .fail("output does not contain 'ok'"))
                ], elapsed: .milliseconds(1))
            ))
        }
        return EvalReport(suiteName: name, started: Date(), finished: Date(), cases: outcomes)
    }
}
