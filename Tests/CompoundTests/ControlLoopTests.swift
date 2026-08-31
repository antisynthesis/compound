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

    @Test("maxRepairAttempts 1 permits exactly one repair then throws .repairAttempts")
    func budgetExhaustedRepair() async throws {
        let model = FakeModel(["bad"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "always-repair", cost: .parse) { _, _ in
                .repair(Diagnostic(verifier: "always-repair", message: "again"))
            }
        ])
        let budget = Budget(maxTurns: 10, maxToolCalls: 0, maxRepairAttempts: 1, wallClock: .seconds(60))
        let loop = ControlLoop(budget: budget, outputVerifier: chain)
        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
            Issue.record("expected budgetExhausted(.repairAttempts)")
        } catch CompoundError.budgetExhausted(let kind, let usage) {
            #expect(kind == .repairAttempts)
            #expect(usage.repairAttempts == 1)
            #expect(usage.turns == 2)
        }
        // Initial turn plus exactly one repair turn.
        let calls = await model.calls
        #expect(calls == 2)
    }

    @Test("maxTurns 1 permits exactly one model call on the happy path")
    func maxTurnsOnePermitsOneCall() async throws {
        let model = FakeModel(["hello"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "pass", cost: .parse) { _, _ in .pass }
        ])
        let budget = Budget(maxTurns: 1, maxToolCalls: 4, maxRepairAttempts: 1, wallClock: .seconds(60))
        let loop = ControlLoop(budget: budget, outputVerifier: chain)
        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        #expect(outcome.output == "hello")
        #expect(outcome.usage.turns == 1)
        let calls = await model.calls
        #expect(calls == 1)
    }

    @Test("maxTurns 1 refuses the second turn with .turns after one model call")
    func maxTurnsOneRefusesSecondTurn() async throws {
        let model = FakeModel(["bad"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "always-repair", cost: .parse) { _, _ in
                .repair(Diagnostic(verifier: "always-repair", message: "again"))
            }
        ])
        let budget = Budget(maxTurns: 1, maxToolCalls: 4, maxRepairAttempts: 5, wallClock: .seconds(60))
        let loop = ControlLoop(budget: budget, outputVerifier: chain)
        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
            Issue.record("expected budgetExhausted(.turns)")
        } catch CompoundError.budgetExhausted(let kind, let usage) {
            #expect(kind == .turns)
            #expect(usage.turns == 1)
        }
        let calls = await model.calls
        #expect(calls == 1)
    }

    @Test("reject verdict throws verifierRejected carrying the rejecting diagnostic")
    func rejectVerdict() async throws {
        let model = FakeModel(["anything"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "gate", cost: .parse) { _, _ in
                .reject(Diagnostic(verifier: "gate", message: "not allowed"))
            }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
            Issue.record("expected verifierRejected")
        } catch CompoundError.verifierRejected(let reason, let diag) {
            #expect(reason == "not allowed")
            #expect(diag?.message == "not allowed")
            #expect(diag?.verifier == "gate")
        }
    }

    @Test("escalate verdict throws escalationRequired carrying the escalating diagnostic")
    func escalateVerdict() async throws {
        let model = FakeModel(["anything"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "hitl", cost: .parse) { _, _ in
                .escalate(Diagnostic(verifier: "hitl", message: "needs a human"))
            }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
            Issue.record("expected escalationRequired")
        } catch CompoundError.escalationRequired(let reason, let diag) {
            #expect(reason == "needs a human")
            #expect(diag?.message == "needs a human")
        }
    }

    @Test("reject after a repair carries the rejecting diagnostic, not the stale repair one")
    func rejectAfterRepairCarriesFreshDiagnostic() async throws {
        let model = FakeModel(["bad", "worse"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "moody", cost: .parse) { input, _ in
                input == "bad"
                    ? .repair(Diagnostic(verifier: "moody", message: "first"))
                    : .reject(Diagnostic(verifier: "moody", message: "second"))
            }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
            Issue.record("expected verifierRejected")
        } catch CompoundError.verifierRejected(let reason, let diag) {
            #expect(reason == "second")
            #expect(diag?.message == "second")
        }
    }

    @Test("loop folds tool-call meter count into outcome usage")
    func foldsToolCallMeterIntoUsage() async throws {
        let meter = ToolCallMeter(limit: 10)
        let ctx = RunContext(toolCallMeter: meter)
        let model = ToolCallingFakeModel(meter: meter, toolCallsPerTurn: 3, response: "ok")
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "pass", cost: .parse) { _, _ in .pass }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: ctx)
        #expect(outcome.usage.toolCalls == 3)
    }

    @Test("maxToolCalls 2 aborts the third tool call mid-turn")
    func maxToolCallsAbortsThirdCall() async throws {
        let meter = ToolCallMeter(limit: 2)
        let ctx = RunContext(toolCallMeter: meter)
        let model = ToolCallingFakeModel(meter: meter, toolCallsPerTurn: 3, response: "ok")
        let loop = ControlLoop(budget: .default, outputVerifier: .empty())
        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: ctx)
            Issue.record("expected budgetExhausted(.toolCalls)")
        } catch CompoundError.budgetExhausted(let kind, _) {
            #expect(kind == .toolCalls)
        }
        let count = await meter.count
        #expect(count == 2)
    }

    @Test("VerifiedTool refuses the call once the meter cap trips")
    func verifiedToolRefusesOverCap() async throws {
        let ctx = RunContext(toolCallMeter: ToolCallMeter(limit: 2))
        let verified = VerifiedTool(
            wrapped: CalculatorTool(),
            argumentVerifiers: VerifierChain<CalculatorTool.Arguments>.empty(),
            requiredScopes: [],
            runContext: ctx,
            policy: AllowAll()
        )
        let args = try CalculatorTool.Arguments(GeneratedContent(properties: ["expression": "1 + 2"]))
        let first = try await verified.call(arguments: args)
        #expect(first == "3")
        _ = try await verified.call(arguments: args)
        do {
            _ = try await verified.call(arguments: args)
            Issue.record("expected budgetExhausted(.toolCalls) on the third call")
        } catch CompoundError.budgetExhausted(let kind, let usage) {
            #expect(kind == .toolCalls)
            #expect(usage.toolCalls == 2)
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

// Simulates a model turn that invokes tools while responding: each respond()
// records `toolCallsPerTurn` calls against the shared meter, mirroring how
// VerifiedTool records during a real FoundationModels turn. A tripped cap
// surfaces mid-turn as the meter's budgetExhausted error.
actor ToolCallingFakeModel: ModelResponding {
    private let meter: ToolCallMeter
    private let toolCallsPerTurn: Int
    private let response: String

    init(meter: ToolCallMeter, toolCallsPerTurn: Int, response: String) {
        self.meter = meter
        self.toolCallsPerTurn = toolCallsPerTurn
        self.response = response
    }

    func respond(to prompt: String, options _: GenerationOptions) async throws -> String {
        for _ in 0..<toolCallsPerTurn {
            try await meter.record()
        }
        return response
    }

    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T {
        fatalError("unused in tests")
    }
}
