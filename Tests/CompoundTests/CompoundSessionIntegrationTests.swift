import Foundation
import FoundationModels
import Testing
@testable import Compound

// Drives the CompoundSession facade end-to-end off-device via the
// Configuration.makeModel seam (SessionFakeModel / ToolInvokingFakeModel
// live in CompoundSessionTests.swift). Every test here goes through
// session.respond(to:) so assembly, redaction, tool instantiation, the
// control loop, and tracing are exercised as one stack — no layer is
// bypassed.
@Suite("CompoundSessionIntegration")
struct CompoundSessionIntegrationTests {
    @Test("happy path: assembler + redactor + model + verifier through the facade")
    func happyPath() async throws {
        let email = try CommonRedactors.email()
        let assembler = DefaultContextAssembler(
            baseInstructions: "be helpful",
            retriever: EmptyRetriever(),
            redactors: [email]
        )
        let model = SessionFakeModel(["the answer"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "len", cost: .parse) { input, _ in
                input.count >= 3 ? .pass : .repair(Diagnostic(verifier: "len", message: "too short"))
            }
        ])
        let session = CompoundSession(.init(
            assembler: assembler,
            outputVerifier: chain,
            makeModel: { _, _, _ in model }
        ))

        let outcome = try await session.respond(to: "my email is alice@example.com")
        #expect(outcome.output == "the answer")

        // The prompt that reached the model transport was redacted by the
        // assembler before the facade handed it to the loop.
        let prompts = await model.prompts
        #expect(prompts.count == 1)
        #expect(!(prompts.first ?? "").contains("alice@example.com"))
    }

    @Test("verifier rejection triggers repair and repaired response succeeds")
    func repairThenSuccess() async throws {
        let tracer = InMemoryTracer()
        let model = SessionFakeModel(["bad", "fixed"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "needs-fixed", cost: .parse) { input, _ in
                input == "fixed"
                    ? .pass
                    : .repair(Diagnostic(verifier: "needs-fixed", message: "say fixed"))
            }
        ])
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            outputVerifier: chain,
            tracer: tracer,
            makeModel: { _, _, _ in model }
        ))

        let outcome = try await session.respond(to: "p")
        #expect(outcome.output == "fixed")
        #expect(outcome.usage.repairAttempts == 1)
        let events = await tracer.snapshot()
        let repairs = events.filter { if case .repairScheduled = $0 { return true }; return false }
        #expect(repairs.count == 1)
    }

    @Test("registered tool is policy-wrapped, runs, and records through the facade")
    func verifiedToolRuns() async throws {
        let tracer = InMemoryTracer()
        var registry = ToolRegistry()
        try registry.register(CalculatorTool())
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            tools: registry,
            tracer: tracer,
            makeModel: { _, tools, _ in
                // The fake invokes the instantiated (VerifiedTool-wrapped)
                // calculator exactly as the on-device model would.
                ToolInvokingFakeModel(tools: tools, expression: "1 + 2")
            }
        ))

        let outcome = try await session.respond(to: "compute 1 + 2")
        #expect(outcome.output == "3")

        let events = await tracer.snapshot()
        let sawRequested = events.contains { if case .toolInvocationRequested = $0 { return true }; return false }
        let sawCompleted = events.contains { ev in
            if case .toolInvocationCompleted(_, _, _, let ok) = ev { return ok }
            return false
        }
        #expect(sawRequested)
        #expect(sawCompleted)
        #expect(outcome.usage.toolCalls == 1)
    }
}
