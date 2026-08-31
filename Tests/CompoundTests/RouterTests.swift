import Foundation
import FoundationModels
import Testing
@testable import Compound

// MARK: - Fakes

/// Serves a scripted queue of responses, one per model call, and counts
/// them. A routed call issues several *runs*, each drawing its own
/// candidates, so the script is written as one flat sequence and the test
/// asserts on how much of it was consumed.
actor ScriptedRouterModel: ModelResponding, ModelStreaming {
    private var script: [String]
    private(set) var calls = 0

    init(_ script: [String]) {
        self.script = script
    }

    func respond(to _: String, options _: GenerationOptions) async throws -> String {
        calls += 1
        guard !script.isEmpty else { return "exhausted" }
        return script.removeFirst()
    }

    func respondGenerating<T: Generable & Sendable>(
        _: T.Type,
        to _: String,
        options _: GenerationOptions
    ) async throws -> T {
        fatalError("unused in tests")
    }

    func stream(to prompt: String, options: GenerationOptions) async -> ModelStreamResult {
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let final = Task<String, Error> {
            let text = try await respond(to: prompt, options: options)
            cont.yield(text)
            cont.finish()
            return text
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

private func routedSession(
    model: ScriptedRouterModel,
    routing: RoutingPolicy?,
    tracer: any Tracer = NullTracer(),
    sampling: SamplingStrategy = .single,
    verifier: VerifierChain<String> = .empty()
) -> CompoundSession {
    CompoundSession(.init(
        assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
        outputVerifier: verifier,
        tracer: tracer,
        sampling: sampling,
        makeModel: { _, _, _ in model },
        routing: routing
    ))
}

// MARK: - Step algebra

@Suite("EscalationStep")
struct EscalationStepTests {
    @Test("a sample step turns a single-candidate strategy into best-of-N")
    func samplesStep() {
        let step = EscalationStep.samples(3)
        let strategy = step.applied(to: .single)
        guard case .bestOf(let n, let selection, _) = strategy else {
            Issue.record("expected bestOf, got \(strategy)")
            return
        }
        #expect(n == 3)
        #expect(selection == .weightedVerifierScore())
    }

    @Test("steps compose: each starts from the strategy the last attempt used")
    func stepsCompose() {
        let first = EscalationStep.samples(3).applied(to: .single)
        let second = EscalationStep.selecting(.firstPassing).applied(to: first)
        guard case .bestOf(let n, let selection, _) = second else {
            Issue.record("expected bestOf, got \(second)")
            return
        }
        // The selection step changed the policy without discarding the
        // candidate count the previous rung bought.
        #expect(n == 3)
        #expect(selection == .firstPassing)
    }

    @Test("a step that raises nothing leaves the strategy alone")
    func neutralStepIsIdentity() {
        #expect(EscalationStep(label: "noop").applied(to: .single) == .single)
        let base = SamplingStrategy.bestOf(n: 4)
        #expect(EscalationStep(label: "noop").applied(to: base) == base)
    }

    @Test("a verifier step appends members and switches the chain mode")
    func verifierStep() {
        let base = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "a", cost: .parse) { _, _ in .pass }
        ])
        let step = EscalationStep.tightenVerifiers([
            AnyVerifier<String>(name: "b", cost: .schema) { _, _ in .pass }
        ])
        let tightened = step.applied(to: base)
        #expect(tightened.members.map(\.name) == ["a", "b"])
        #expect(tightened.mode == .collectAll(maxDiagnostics: 8))
        #expect(tightened.name == "out")
        // The base chain is untouched — steps never mutate the session.
        #expect(base.members.count == 1)
    }

    @Test("routing treats a missing signal as low only when asked to")
    func missingConfidencePolicy() {
        let escalating = RoutingPolicy(minConfidence: 0.5, escalation: [])
        #expect(escalating.isLowConfidence(nil))
        #expect(escalating.isLowConfidence(0.4))
        #expect(!escalating.isLowConfidence(0.5))

        let tolerant = RoutingPolicy(minConfidence: 0.5, escalation: [], escalatesOnMissingConfidence: false)
        #expect(!tolerant.isLowConfidence(nil))
    }
}

// MARK: - Cascade

@Suite("CompoundSession routing")
struct RouterTests {
    @Test("a confident first attempt never escalates")
    func confidentRunStopsImmediately() async throws {
        let model = ScriptedRouterModel(["same words here", "same words here"])
        let session = routedSession(
            model: model,
            routing: RoutingPolicy(minConfidence: 0.6, escalation: [.samples(4)]),
            sampling: .bestOf(n: 2)
        )

        let routed = try await session.respondRouted(to: "hi")
        #expect(routed.appliedSteps.isEmpty)
        #expect(!routed.lowConfidence)
        #expect(routed.confidence == 1)
        #expect(await model.calls == 2)
    }

    @Test("low agreement escalates and stops at the first attempt that clears the bar")
    func escalatesUntilConfident() async throws {
        let model = ScriptedRouterModel([
            // Attempt 1: a single candidate, so no agreement signal at all.
            "alpha",
            // Attempt 2: two candidates that share nothing.
            "beta gamma delta", "epsilon zeta eta",
            // Attempt 3: three candidates that agree completely.
            "settled answer", "settled answer", "settled answer"
        ])
        let session = routedSession(
            model: model,
            routing: RoutingPolicy(
                minConfidence: 0.6,
                escalation: [.samples(2), .samples(3), .samples(4)]
            )
        )

        let routed = try await session.respondRouted(to: "hi")
        #expect(routed.appliedSteps == ["samples-2", "samples-3"])
        #expect(!routed.lowConfidence)
        #expect(routed.confidence == 1)
        #expect(routed.output == "settled answer")
        #expect(await model.calls == 6)
    }

    @Test("the cascade is bounded by the ladder and flags a still-unconfident answer")
    func boundedByLadder() async throws {
        let tracer = InMemoryTracer()
        let model = ScriptedRouterModel([
            "alpha",
            "beta gamma", "delta epsilon",
            "zeta eta", "theta iota", "kappa lambda"
        ])
        let session = routedSession(
            model: model,
            routing: RoutingPolicy(minConfidence: 0.9, escalation: [.samples(2), .samples(3)]),
            tracer: tracer
        )

        let routed = try await session.respondRouted(to: "hi")
        #expect(routed.appliedSteps == ["samples-2", "samples-3"])
        #expect(routed.lowConfidence)
        #expect(routed.confidence == 0)
        // 1 + 2 + 3 model calls: the ladder is spent, and nothing beyond it
        // runs.
        #expect(await model.calls == 6)

        let escalations = await tracer.snapshot().compactMap { event -> (String, Int)? in
            guard case .routingEscalated(_, let step, _, let attempt) = event else { return nil }
            return (step, attempt)
        }
        #expect(escalations.map(\.0) == ["samples-2", "samples-3"])
        #expect(escalations.map(\.1) == [1, 2])
    }

    @Test("an escalation step's verifiers gate the attempt it applies to")
    func escalatedVerifiersReachTheRun() async throws {
        let model = ScriptedRouterModel(["alpha", "beta", "gamma"])
        let session = routedSession(
            model: model,
            routing: RoutingPolicy(
                minConfidence: 0.9,
                escalation: [
                    EscalationStep(
                        label: "reject",
                        samples: 2,
                        additionalVerifiers: [
                            AnyVerifier<String>(name: "escalated-reject", cost: .parse) { _, _ in
                                .reject(Diagnostic(verifier: "escalated-reject", message: "nope"))
                            }
                        ]
                    )
                ]
            )
        )

        do {
            _ = try await session.respondRouted(to: "hi")
            Issue.record("expected the escalated chain to reject")
        } catch let error as CompoundError {
            guard case .verifierRejected(_, let diagnostic) = error else {
                Issue.record("expected verifierRejected, got \(error)")
                return
            }
            #expect(diagnostic?.verifier == "escalated-reject")
        }
    }

    @Test("no routing policy means one attempt and no flag")
    func withoutRoutingIsASingleRun() async throws {
        let model = ScriptedRouterModel(["only"])
        let session = routedSession(model: model, routing: nil)

        let routed = try await session.respondRouted(to: "hi")
        #expect(routed.output == "only")
        #expect(routed.appliedSteps.isEmpty)
        #expect(!routed.lowConfidence)
        #expect(routed.confidence == nil)
        #expect(await model.calls == 1)
    }

    @Test("respond() ignores the cascade — one call is one run")
    func respondDoesNotEscalate() async throws {
        let model = ScriptedRouterModel(["alpha"])
        let session = routedSession(
            model: model,
            routing: RoutingPolicy(minConfidence: 0.9, escalation: [.samples(3)])
        )

        let outcome = try await session.respond(to: "hi")
        #expect(outcome.output == "alpha")
        #expect(await model.calls == 1)
    }

    @Test("routing and the ladder compose: a degraded run still routes")
    func routingUnderDegradation() async throws {
        let model = ScriptedRouterModel([
            "alpha",
            "settled answer", "settled answer"
        ])
        let health = HealthMonitor(policy: .default)
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            makeModel: { _, _, _ in model },
            health: health,
            routing: RoutingPolicy(minConfidence: 0.6, escalation: [.samples(2)])
        ))
        await health.setOverride(.noTools)

        let routed = try await session.respondRouted(to: "hi")
        #expect(routed.appliedSteps == ["samples-2"])
        #expect(!routed.lowConfidence)
        #expect(await session.currentDegradedMode() == .noTools)
    }
}
