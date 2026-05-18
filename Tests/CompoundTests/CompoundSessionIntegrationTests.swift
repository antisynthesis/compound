import Foundation
import FoundationModels
import Testing
@testable import Compound

// Reuses FakeModel from ControlLoopTests via @testable import. We re-declare a
// minimal in-suite helper to drive ControlLoop directly without rebuilding
// CompoundSession (which requires the on-device LanguageModelSession that
// isn't available in unit tests).
@Suite("CompoundSessionIntegration")
struct CompoundSessionIntegrationTests {
    @Test("happy path: assembler + redactor + model + verifier")
    func happyPath() async throws {
        let email = try CommonRedactors.email()
        let assembler = DefaultContextAssembler(
            baseInstructions: "be helpful",
            retriever: EmptyRetriever(),
            redactors: [email]
        )
        let ctx = RunContext()
        let assembled = try await assembler.assemble(
            userPrompt: "my email is alice@example.com",
            runContext: ctx
        )
        #expect(!assembled.userPrompt.contains("alice@example.com"))

        let model = FakeModel(["the answer"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "len", cost: .parse) { input, _ in
                input.count >= 3 ? .pass : .repair(Diagnostic(verifier: "len", message: "too short"))
            }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let outcome = try await loop.run(
            prompt: assembled.renderedPrompt(),
            modelClient: model,
            runContext: ctx
        )
        #expect(outcome.output == "the answer")
    }

    @Test("verifier rejection triggers repair and repaired response succeeds")
    func repairThenSuccess() async throws {
        let tracer = InMemoryTracer()
        let ctx = RunContext(tracer: tracer)
        let model = FakeModel(["bad", "fixed"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "needs-fixed", cost: .parse) { input, _ in
                input == "fixed"
                    ? .pass
                    : .repair(Diagnostic(verifier: "needs-fixed", message: "say fixed"))
            }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: ctx)
        #expect(outcome.output == "fixed")
        #expect(outcome.usage.repairAttempts == 1)
        let events = await tracer.snapshot()
        let repairs = events.filter { if case .repairScheduled = $0 { return true }; return false }
        #expect(repairs.count == 1)
    }

    @Test("VerifiedTool wrapping a deterministic toy tool runs and records")
    func verifiedToolRuns() async throws {
        let tracer = InMemoryTracer()
        let ctx = RunContext(tracer: tracer)
        // CalculatorTool is deterministic and uses GeneratedContent arguments.
        let inner = CalculatorTool()
        let verified = VerifiedTool(
            wrapped: inner,
            argumentVerifiers: VerifierChain<CalculatorTool.Arguments>.empty(),
            requiredScopes: [],
            runContext: ctx,
            policy: AllowAll()
        )
        let args = try CalculatorTool.Arguments(GeneratedContent(properties: ["expression": "1 + 2"]))
        let result = try await verified.call(arguments: args)
        #expect(result == "3")
        let events = await tracer.snapshot()
        let sawRequested = events.contains { if case .toolInvocationRequested = $0 { return true }; return false }
        let sawCompleted = events.contains { ev in
            if case .toolInvocationCompleted(_, _, _, let ok) = ev { return ok }
            return false
        }
        #expect(sawRequested)
        #expect(sawCompleted)
    }
}
