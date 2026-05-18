import Foundation
import FoundationModels
import Testing
@testable import Compound

// FakeModel returns a queue of canned responses on each respond() call.
// When the queue is exhausted the last response is returned indefinitely.
actor FakeModel: ModelResponding {
    private var responses: [String]
    private(set) var calls: Int = 0
    init(_ responses: [String]) { self.responses = responses }
    func respond(to prompt: String, options _: GenerationOptions) async throws -> String {
        calls += 1
        if responses.count > 1 {
            return responses.removeFirst()
        }
        return responses.first ?? ""
    }
    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T {
        fatalError("unused in tests")
    }
}

@Suite("ControlLoop")
struct ControlLoopTests {
    @Test("loop completes when verifier passes")
    func completesWhenVerifierPasses() async throws {
        let model = FakeModel(["hello"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "pass", cost: .parse) { _, _ in .pass }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        #expect(outcome.output == "hello")
        let calls = await model.calls
        #expect(calls == 1)
    }

    @Test("loop schedules repair when verifier returns .repair then succeeds")
    func schedulesRepair() async throws {
        let model = FakeModel(["bad", "good"])
        // Pass only on second turn.
        let attempts = AttemptCounter()
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "needs-good", cost: .parse) { input, _ in
                await attempts.bump()
                return input == "good"
                    ? .pass
                    : .repair(Diagnostic(verifier: "needs-good", message: "want good"))
            }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        #expect(outcome.output == "good")
        #expect(outcome.usage.repairAttempts == 1)
    }

    @Test("loop fails with budgetExhausted when maxRepairAttempts hit")
    func budgetExhaustedRepair() async throws {
        let model = FakeModel(["bad"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "always-repair", cost: .parse) { _, _ in
                .repair(Diagnostic(verifier: "always-repair", message: "again"))
            }
        ])
        let budget = Budget(maxTurns: 10, maxToolCalls: 0, maxRepairAttempts: 1, wallClock: .seconds(60))
        let loop = ControlLoop(budget: budget, outputVerifier: chain)
        await #expect(throws: CompoundError.self) {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        }
    }

    @Test("loop emits the right TraceEvent sequence")
    func emitsTraceEventSequence() async throws {
        let tracer = InMemoryTracer()
        let model = FakeModel(["hi"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let ctx = RunContext(tracer: tracer)
        _ = try await loop.run(prompt: "p", modelClient: model, runContext: ctx)
        let events = await tracer.snapshot()
        let labels = events.map(\.label)
        #expect(labels.first == "run.started")
        #expect(labels.contains("verifier.evaluated"))
        guard let lastLabel = labels.last else {
            Issue.record("no trace events")
            return
        }
        #expect(lastLabel == "run.ended")
    }

    @Test("loop emits turnStarted/verifierStarted/verifierCompleted progress events")
    func emitsProgressEvents() async throws {
        let progress = RecordingProgressReporter()
        let model = FakeModel(["hi"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let ctx = RunContext(progress: progress)
        _ = try await loop.run(prompt: "p", modelClient: model, runContext: ctx)
        let events = await progress.snapshot()
        var sawTurn = false
        var sawVerifierStart = false
        var sawVerifierEnd = false
        for ev in events {
            switch ev {
            case .turnStarted: sawTurn = true
            case .verifierStarted: sawVerifierStart = true
            case .verifierCompleted: sawVerifierEnd = true
            default: break
            }
        }
        #expect(sawTurn)
        #expect(sawVerifierStart)
        #expect(sawVerifierEnd)
    }
}

actor AttemptCounter {
    var count = 0
    func bump() { count += 1 }
}
