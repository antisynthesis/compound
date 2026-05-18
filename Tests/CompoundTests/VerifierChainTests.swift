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
