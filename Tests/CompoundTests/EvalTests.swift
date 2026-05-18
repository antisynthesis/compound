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
        let report = await runner.run(suite, against: target)
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
        let report = await EvalRunner().run(suite, against: ThrowingTarget())
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
}
