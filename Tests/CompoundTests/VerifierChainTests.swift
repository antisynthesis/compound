import Foundation
import Testing
@testable import Compound

@Suite("VerifierChain")
struct VerifierChainTests {
    @Test("chain sorts members cheapest first")
    func sortsCheapestFirst() {
        let cheap = AnyVerifier<String>(name: "cheap", cost: .parse) { _, _ in .pass }
        let pricey = AnyVerifier<String>(name: "pricey", cost: .unitTest) { _, _ in .pass }
        let chain = VerifierChain<String>(name: "c", [pricey, cheap])
        #expect(chain.members.first?.name == "cheap")
    }

    @Test("chain short circuits on first non-pass")
    func shortCircuits() async throws {
        struct ShouldNotRun: Error {}
        let failing = AnyVerifier<String>(name: "fail", cost: .parse) { _, _ in
            .repair(Diagnostic(verifier: "fail", message: "nope"))
        }
        let later = AnyVerifier<String>(name: "later", cost: .types) { _, _ in
            throw ShouldNotRun()
        }
        let chain = VerifierChain<String>(name: "c", [failing, later])
        let verdict = try await chain.verify("x", context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.verifier == "fail")
        } else {
            Issue.record("expected .repair from fail verifier")
        }
    }

    @Test("empty chain passes")
    func emptyChainPasses() async throws {
        let chain = VerifierChain<String>.empty()
        let verdict = try await chain.verify("anything", context: RunContext())
        #expect(verdict.isPass)
    }

    @Test("reject string convenience synthesizes a Diagnostic")
    func rejectStringConvenience() async throws {
        let v = AnyVerifier<String>(name: "r", cost: .parse) { _, _ in
            .reject("bad input")
        }
        let verdict = try await v.verify("x", context: RunContext())
        if case .reject(let d) = verdict {
            #expect(d.message == "bad input")
        } else {
            Issue.record("expected .reject")
        }
    }

    @Test("escalate string convenience synthesizes a Diagnostic")
    func escalateStringConvenience() async throws {
        let v = AnyVerifier<String>(name: "e", cost: .parse) { _, _ in
            .escalate("needs human review")
        }
        let verdict = try await v.verify("x", context: RunContext())
        if case .escalate(let d) = verdict {
            #expect(d.message == "needs human review")
        } else {
            Issue.record("expected .escalate")
        }
    }

    @Test("equal-cost members order deterministically by name, regardless of insertion order")
    func stableEqualCostOrdering() {
        func v(_ name: String) -> AnyVerifier<String> {
            AnyVerifier<String>(name: name, cost: .parse) { _, _ in .pass }
        }
        let forward = VerifierChain<String>(name: "c", [v("b"), v("a"), v("c")])
        let backward = VerifierChain<String>(name: "c", [v("c"), v("b"), v("a")])
        #expect(forward.members.map(\.name) == ["a", "b", "c"])
        #expect(backward.members.map(\.name) == ["a", "b", "c"])
    }

    @Test("sort key is (cost, name): cost still dominates name")
    func costDominatesName() {
        let zCheap = AnyVerifier<String>(name: "z", cost: .parse) { _, _ in .pass }
        let aPricey = AnyVerifier<String>(name: "a", cost: .unitTest) { _, _ in .pass }
        let chain = VerifierChain<String>(name: "c", [aPricey, zCheap])
        #expect(chain.members.map(\.name) == ["z", "a"])
    }

    @Test("collectAll aggregates every repair diagnostic into one verdict")
    func collectAllAggregatesRepairs() async throws {
        func failing(_ name: String, _ cost: VerifierCost) -> AnyVerifier<String> {
            AnyVerifier<String>(name: name, cost: cost) { _, _ in
                .repair(Diagnostic(verifier: name, message: "\(name) failed"))
            }
        }
        let chain = VerifierChain<String>(
            name: "c",
            mode: .collectAll(maxDiagnostics: 8),
            [failing("one", .parse), failing("two", .schema), failing("three", .types)]
        )
        let (verdict, diagnostics) = try await chain.verifyCollecting("x", context: RunContext())
        #expect(diagnostics.map(\.verifier) == ["one", "two", "three"])
        if case .repair(let combined) = verdict {
            #expect(combined.message.contains("one failed"))
            #expect(combined.message.contains("two failed"))
            #expect(combined.message.contains("three failed"))
        } else {
            Issue.record("expected aggregated .repair verdict")
        }
    }

    @Test("collectAll caps the aggregated diagnostics at maxDiagnostics")
    func collectAllCapsDiagnostics() async throws {
        func failing(_ name: String, _ cost: VerifierCost) -> AnyVerifier<String> {
            AnyVerifier<String>(name: name, cost: cost) { _, _ in
                .repair(Diagnostic(verifier: name, message: "\(name) failed"))
            }
        }
        let chain = VerifierChain<String>(
            name: "c",
            mode: .collectAll(maxDiagnostics: 2),
            [failing("one", .parse), failing("two", .schema), failing("three", .types)]
        )
        let (_, diagnostics) = try await chain.verifyCollecting("x", context: RunContext())
        #expect(diagnostics.map(\.verifier) == ["one", "two"])
    }

    @Test("collectAll still terminates immediately on reject")
    func collectAllRejectTerminatesImmediately() async throws {
        struct ShouldNotRun: Error {}
        let repairing = AnyVerifier<String>(name: "fixable", cost: .parse) { _, _ in
            .repair(Diagnostic(verifier: "fixable", message: "small defect"))
        }
        let rejecting = AnyVerifier<String>(name: "gate", cost: .schema) { _, _ in
            .reject(Diagnostic(verifier: "gate", message: "hard no"))
        }
        let later = AnyVerifier<String>(name: "later", cost: .types) { _, _ in
            throw ShouldNotRun()
        }
        let chain = VerifierChain<String>(
            name: "c",
            mode: .collectAll(maxDiagnostics: 8),
            [repairing, rejecting, later]
        )
        let (verdict, diagnostics) = try await chain.verifyCollecting("x", context: RunContext())
        if case .reject(let d) = verdict {
            // The rejecting verifier's own diagnostic, never a stale aggregate.
            #expect(d.verifier == "gate")
            #expect(d.message == "hard no")
        } else {
            Issue.record("expected .reject to terminate the chain")
        }
        #expect(diagnostics == [Diagnostic(verifier: "gate", message: "hard no")])
    }

    @Test("collectAll still terminates immediately on escalate")
    func collectAllEscalateTerminatesImmediately() async throws {
        struct ShouldNotRun: Error {}
        let escalating = AnyVerifier<String>(name: "hitl", cost: .parse) { _, _ in
            .escalate(Diagnostic(verifier: "hitl", message: "needs a human"))
        }
        let later = AnyVerifier<String>(name: "later", cost: .types) { _, _ in
            throw ShouldNotRun()
        }
        let chain = VerifierChain<String>(
            name: "c",
            mode: .collectAll(maxDiagnostics: 8),
            [escalating, later]
        )
        let verdict = try await chain.verify("x", context: RunContext())
        if case .escalate(let d) = verdict {
            #expect(d.verifier == "hitl")
        } else {
            Issue.record("expected .escalate to terminate the chain")
        }
    }

    @Test("collectAll passes when every member passes")
    func collectAllPasses() async throws {
        let chain = VerifierChain<String>(
            name: "c",
            mode: .collectAll(maxDiagnostics: 8),
            [AnyVerifier<String>(name: "ok", cost: .parse) { _, _ in .pass }]
        )
        let (verdict, diagnostics) = try await chain.verifyCollecting("x", context: RunContext())
        #expect(verdict.isPass)
        #expect(diagnostics.isEmpty)
    }

    @Test("collectAll with a single failure returns that diagnostic uncombined")
    func collectAllSingleFailureUncombined() async throws {
        let diag = Diagnostic(verifier: "solo", message: "only defect", suggestion: "fix it")
        let chain = VerifierChain<String>(
            name: "c",
            mode: .collectAll(maxDiagnostics: 8),
            [AnyVerifier<String>(name: "solo", cost: .parse) { _, _ in .repair(diag) }]
        )
        let verdict = try await chain.verify("x", context: RunContext())
        #expect(verdict == .repair(diag))
    }

    @Test("mode defaults to shortCircuit")
    func modeDefaultsToShortCircuit() {
        let chain = VerifierChain<String>(name: "c", [])
        #expect(chain.mode == .shortCircuit)
    }

    @Test("combined diagnostic folds summaries and counts")
    func combinedDiagnostic() {
        let a = Diagnostic(verifier: "a", message: "m1")
        let b = Diagnostic(verifier: "b", message: "m2", suggestion: "s2")
        let one = Diagnostic.combined([a])
        #expect(one == a)
        let two = Diagnostic.combined([a, b], verifier: "chain")
        #expect(two.verifier == "chain")
        #expect(two.message.contains("2 verifiers failed"))
        #expect(two.message.contains("m1"))
        #expect(two.message.contains("m2"))
        let none = Diagnostic.combined([])
        #expect(none.message == "verification failed")
    }

    @Test("reject accepts a fully built Diagnostic")
    func rejectAcceptsDiagnostic() async throws {
        let diag = Diagnostic(verifier: "v", message: "m", suggestion: "s")
        let v = AnyVerifier<String>(name: "r", cost: .parse) { _, _ in
            .reject(diag)
        }
        let verdict = try await v.verify("x", context: RunContext())
        if case .reject(let d) = verdict {
            #expect(d == diag)
        } else {
            Issue.record("expected .reject")
        }
    }
}
