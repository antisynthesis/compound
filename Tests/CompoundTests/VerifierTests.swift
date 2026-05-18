import Foundation
import Testing
@testable import Compound

@Suite("Verifier")
struct VerifierTests {
    @Test("regex verifier passes on match")
    func regexPassesOnMatch() async throws {
        let v = try RegexVerifier(name: "test", pattern: #"^hello"#, mustMatch: true)
        let verdict = try await v.verify("hello world", context: RunContext())
        #expect(verdict.isPass)
    }

    @Test("regex verifier repairs on miss")
    func regexRepairsOnMiss() async throws {
        let v = try RegexVerifier(name: "test", pattern: #"^hello"#, mustMatch: true)
        let verdict = try await v.verify("goodbye", context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("length verifier rejects too short")
    func lengthRejectsShort() async throws {
        let v = LengthVerifier(min: 5)
        #expect((try await v.verify("hi", context: RunContext())).isRepair)
    }

    @Test("length verifier rejects too long")
    func lengthRejectsLong() async throws {
        let v = LengthVerifier(max: 3)
        #expect((try await v.verify("toolong", context: RunContext())).isRepair)
    }

    @Test("json verifier passes on valid json")
    func jsonPassesValid() async throws {
        let v = JSONParseVerifier()
        #expect((try await v.verify(#"{"a": 1}"#, context: RunContext())).isPass)
    }

    @Test("json verifier repairs on invalid json")
    func jsonRepairsInvalid() async throws {
        let v = JSONParseVerifier()
        #expect((try await v.verify("not json", context: RunContext())).isRepair)
    }

    @Test("predicate verifier runs the predicate")
    func predicateRuns() async throws {
        let v = PredicateVerifier<String>(
            name: "starts-with-a",
            predicate: { $0.hasPrefix("a") }
        )
        #expect((try await v.verify("apple", context: RunContext())).isPass)
        let bad = try await v.verify("banana", context: RunContext())
        #expect(bad.isRepair)
    }

    @Test("citation verifier accepts known ids")
    func citationAcceptsKnown() async throws {
        let v = try CitationVerifier(knownSourceIDs: ["src-1", "src-2"])
        let verdict = try await v.verify("claim one [src-1] and claim two [src-2]", context: RunContext())
        #expect(verdict.isPass)
    }

    @Test("citation verifier flags unknown ids")
    func citationFlagsUnknown() async throws {
        let v = try CitationVerifier(knownSourceIDs: ["src-1"])
        #expect((try await v.verify("claim [src-2]", context: RunContext())).isRepair)
    }

    @Test("citation verifier flags missing citations")
    func citationFlagsMissing() async throws {
        let v = try CitationVerifier(knownSourceIDs: ["src-1"])
        #expect((try await v.verify("a claim with no source", context: RunContext())).isRepair)
    }

    @Test("compound error severity classifies recoverable vs terminal")
    func errorSeverity() {
        let usage = BudgetUsage()
        #expect(CompoundError.budgetExhausted(.turns, usage).severity == .recoverable)
        #expect(CompoundError.verifierRejected(reason: "x", lastDiagnostic: nil).severity == .recoverable)
        #expect(CompoundError.escalationRequired(reason: "x", lastDiagnostic: nil).severity == .recoverable)
        #expect(CompoundError.cancelled.severity == .recoverable)
        #expect(CompoundError.toolArgumentRejected(name: "t", diagnostic: Diagnostic(verifier: "v", message: "m")).severity == .recoverable)
        #expect(CompoundError.policyDenied(reason: "x").severity == .terminal)
        #expect(CompoundError.toolUnavailable(name: "t").severity == .terminal)
        #expect(CompoundError.modelUnavailable(reason: "x").severity == .terminal)
    }

    @Test("compound error layer maps each case to an architectural layer")
    func errorLayer() {
        let usage = BudgetUsage()
        #expect(CompoundError.budgetExhausted(.turns, usage).layer == .budget)
        #expect(CompoundError.verifierRejected(reason: "x", lastDiagnostic: nil).layer == .verifier)
        #expect(CompoundError.escalationRequired(reason: "x", lastDiagnostic: nil).layer == .verifier)
        #expect(CompoundError.policyDenied(reason: "x").layer == .policy)
        #expect(CompoundError.toolUnavailable(name: "t").layer == .tool)
        #expect(CompoundError.toolArgumentRejected(name: "t", diagnostic: Diagnostic(verifier: "v", message: "m")).layer == .tool)
        #expect(CompoundError.modelUnavailable(reason: "x").layer == .model)
        #expect(CompoundError.cancelled.layer == .control)
        #expect(CompoundError.underlying(NSError(domain: "x", code: 0)).layer == .unknown)
    }

    @Test("compound error conforms to LocalizedError")
    func errorLocalized() {
        let err: any LocalizedError = CompoundError.policyDenied(reason: "no scope")
        #expect(err.errorDescription?.contains("policy denied") == true)
        #expect(err.failureReason == "no scope")
        #expect(err.recoverySuggestion != nil)
    }
}
