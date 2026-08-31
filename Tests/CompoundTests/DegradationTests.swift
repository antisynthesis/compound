import Foundation
import FoundationModels
import Testing
@testable import Compound

// MARK: - Fakes

/// Clock stand-in for cooldown arithmetic. Cooldowns are the one part of a
/// circuit breaker that is defined in terms of wall time, and a test that
/// slept for them would be both slow and flaky — so the monitor takes its
/// reading from an injected closure and this drives it.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        lock.unlock()
    }
}

/// Model transport that either serves scripted text or throws a scripted
/// error, and counts every call so a test can prove a run never reached
/// the model at all.
actor DegradationFakeModel: ModelResponding, ModelStreaming {
    private let output: String
    private let failure: CompoundError?
    private(set) var calls = 0
    private(set) var prompts: [String] = []

    init(output: String = "ok", failure: CompoundError? = nil) {
        self.output = output
        self.failure = failure
    }

    func respond(to prompt: String, options _: GenerationOptions) async throws -> String {
        calls += 1
        prompts.append(prompt)
        if let failure { throw failure }
        return output
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
            do {
                let text = try await respond(to: prompt, options: options)
                cont.yield(text)
                cont.finish()
                return text
            } catch {
                cont.finish(throwing: error)
                throw error
            }
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

/// Records the tool lists handed to the `makeModel` seam so a test can see
/// that ``DegradedMode/noTools`` really withheld the registry.
final class ToolCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[String]] = []

    func record(_ tools: [any Tool]) {
        lock.lock()
        lists.append(tools.map(\.name))
        lock.unlock()
    }

    var toolNames: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return lists
    }
}

// MARK: - Breaker mechanics

@Suite("HealthMonitor")
struct HealthMonitorTests {
    @Test("breaker opens after the configured number of consecutive violations")
    func opensAtThreshold() async {
        let monitor = HealthMonitor(policy: .default)
        await monitor.record(.guardrailViolation)
        #expect(await monitor.state(for: .guardrailViolation) == .closed)
        await monitor.record(.guardrailViolation)
        #expect(await monitor.state(for: .guardrailViolation) == .closed)
        await monitor.record(.guardrailViolation)
        #expect(await monitor.state(for: .guardrailViolation) == .open)
        #expect(await monitor.failures(for: .guardrailViolation) == 3)
        #expect(await monitor.assess().mode == .deterministicOnly)
    }

    @Test("a success before the threshold resets the streak")
    func successResetsStreak() async {
        let monitor = HealthMonitor(policy: .default)
        await monitor.record(.guardrailViolation)
        await monitor.record(.guardrailViolation)
        await monitor.recordSuccess()
        #expect(await monitor.failures(for: .guardrailViolation) == 0)
        await monitor.record(.guardrailViolation)
        #expect(await monitor.state(for: .guardrailViolation) == .closed)
    }

    @Test("open breaker half-opens only once the cooldown elapses")
    func halfOpensAfterCooldown() async {
        let clock = ManualClock()
        let monitor = HealthMonitor(
            policy: DegradationPolicy(
                thresholds: [.deadline: 2],
                openModes: [.deadline: .noTools],
                cooldown: .seconds(30)
            ),
            now: { clock.now }
        )
        await monitor.record(.deadline)
        await monitor.record(.deadline)
        #expect(await monitor.state(for: .deadline) == .open)

        clock.advance(by: .seconds(29))
        #expect(await monitor.assess().mode == .noTools)
        #expect(await monitor.state(for: .deadline) == .open)

        clock.advance(by: .seconds(1))
        // Half-open probes one rung milder than the open mode, which is
        // what lets the withdrawn capability be tested at all.
        #expect(await monitor.assess().mode == .reducedContext)
        #expect(await monitor.state(for: .deadline) == .halfOpen)
    }

    @Test("a failed probe re-opens the breaker and restarts the cooldown")
    func failedProbeReopens() async {
        let clock = ManualClock()
        let monitor = HealthMonitor(
            policy: DegradationPolicy(thresholds: [.deadline: 1], cooldown: .seconds(10)),
            now: { clock.now }
        )
        await monitor.record(.deadline)
        clock.advance(by: .seconds(10))
        #expect(await monitor.assess().states[.deadline] == .halfOpen)

        await monitor.record(.deadline)
        #expect(await monitor.state(for: .deadline) == .open)
        // Cooldown restarted at the moment of the failed probe.
        clock.advance(by: .seconds(9))
        #expect(await monitor.assess().states[.deadline] == .open)
        clock.advance(by: .seconds(1))
        #expect(await monitor.assess().states[.deadline] == .halfOpen)
    }

    @Test("a successful probe closes the breaker")
    func successfulProbeCloses() async {
        let clock = ManualClock()
        let monitor = HealthMonitor(
            policy: DegradationPolicy(thresholds: [.deadline: 1], cooldown: .seconds(10)),
            now: { clock.now }
        )
        await monitor.record(.deadline)
        clock.advance(by: .seconds(10))
        _ = await monitor.assess()
        await monitor.recordSuccess()
        #expect(await monitor.state(for: .deadline) == .closed)
        #expect(await monitor.assess().mode == .full)
    }

    @Test("a success while open leaves the breaker open")
    func successWhileOpenDoesNotClose() async {
        let monitor = HealthMonitor(policy: DegradationPolicy(thresholds: [.deadline: 1]))
        await monitor.record(.deadline)
        await monitor.recordSuccess()
        #expect(await monitor.state(for: .deadline) == .open)
    }

    @Test("the most degraded open breaker decides the rung")
    func worstBreakerWins() async {
        let monitor = HealthMonitor(policy: .default)
        for _ in 0..<3 { await monitor.record(.contextPressure) }
        #expect(await monitor.assess().mode == .reducedContext)
        for _ in 0..<3 { await monitor.record(.guardrailViolation) }
        let assessment = await monitor.assess()
        #expect(assessment.mode == .deterministicOnly)
        #expect(assessment.signal == .guardrailViolation)
        #expect(assessment.reason.contains("guardrailViolation"))
    }

    @Test("manual override replaces the computed rung in both directions")
    func manualOverride() async {
        let monitor = HealthMonitor(policy: .default)
        await monitor.setOverride(.noTools)
        #expect(await monitor.assess().mode == .noTools)
        #expect(await monitor.assess().reason == "manual override")

        for _ in 0..<3 { await monitor.record(.guardrailViolation) }
        // Even a tripped breaker loses to an explicit operator decision.
        await monitor.setOverride(.full)
        #expect(await monitor.assess().mode == .full)

        await monitor.setOverride(nil)
        #expect(await monitor.assess().mode == .deterministicOnly)
    }

    @Test("every state transition is traced")
    func transitionsAreTraced() async {
        let clock = ManualClock()
        let tracer = InMemoryTracer()
        let runID = UUID()
        let monitor = HealthMonitor(
            policy: DegradationPolicy(thresholds: [.guardrailViolation: 2], cooldown: .seconds(5)),
            tracer: tracer,
            now: { clock.now }
        )
        await monitor.record(.guardrailViolation, runID: runID)
        await monitor.record(.guardrailViolation, runID: runID)
        clock.advance(by: .seconds(5))
        _ = await monitor.assess(runID: runID)
        await monitor.recordSuccess(runID: runID)

        let transitions: [(BreakerState, BreakerState)] = await tracer.snapshot().compactMap { event in
            guard case .breakerTransitioned(let id, let signal, let from, let to, _) = event else { return nil }
            #expect(id == runID)
            #expect(signal == .guardrailViolation)
            return (from, to)
        }
        #expect(transitions.count == 3)
        #expect(transitions[0] == (.closed, .open))
        #expect(transitions[1] == (.open, .halfOpen))
        #expect(transitions[2] == (.halfOpen, .closed))
    }

    @Test("reset clears breakers and the override")
    func resetClears() async {
        let monitor = HealthMonitor(policy: .default)
        for _ in 0..<3 { await monitor.record(.guardrailViolation) }
        await monitor.setOverride(.noTools)
        await monitor.reset()
        #expect(await monitor.assess().mode == .full)
        #expect(await monitor.override() == nil)
    }
}

// MARK: - Classification and mapping

@Suite("Degradation classification")
struct DegradationClassificationTests {
    @Test("health-bearing errors classify into signal classes")
    func classifiesHealthSignals() {
        #expect(DegradationSignal(.guardrailViolation(context: nil)) == .guardrailViolation)
        #expect(DegradationSignal(.modelUnavailable(reason: "downloading")) == .modelUnavailable)
        #expect(DegradationSignal(.contextWindowExceeded(promptTokens: 9000)) == .contextPressure)
        #expect(DegradationSignal(.budgetExhausted(.wallClock, BudgetUsage())) == .deadline)
        #expect(DegradationSignal(.budgetExhausted(.firstToken, BudgetUsage())) == .deadline)
        #expect(DegradationSignal(.budgetExhausted(.interChunkGap, BudgetUsage())) == .deadline)
    }

    @Test("errors about one prompt or one caller never trip a breaker")
    func ignoresNonHealthErrors() {
        let diagnostic = Diagnostic(verifier: "v", message: "no")
        #expect(DegradationSignal(.verifierRejected(reason: "no", lastDiagnostic: diagnostic)) == nil)
        #expect(DegradationSignal(.policyDenied(reason: "scope")) == nil)
        #expect(DegradationSignal(.toolUnavailable(name: "shell")) == nil)
        #expect(DegradationSignal(.budgetExhausted(.turns, BudgetUsage())) == nil)
        #expect(DegradationSignal(.budgetExhausted(.toolCalls, BudgetUsage())) == nil)
        #expect(DegradationSignal(.cancelled) == nil)
    }

    @Test("the ladder is cumulative")
    func ladderIsCumulative() {
        #expect(DegradedMode.full.allowsTools)
        #expect(!DegradedMode.full.reducesContext)
        #expect(DegradedMode.reducedContext.allowsTools)
        #expect(DegradedMode.reducedContext.reducesContext)
        #expect(!DegradedMode.noTools.allowsTools)
        #expect(DegradedMode.noTools.reducesContext)
        #expect(!DegradedMode.deterministicOnly.allowsModelCalls)
        #expect(!DegradedMode.deterministicOnly.allowsTools)
        #expect(DegradedMode.full < DegradedMode.reducedContext)
        #expect(DegradedMode.noTools < DegradedMode.deterministicOnly)
        #expect(DegradedMode.deterministicOnly.milder == .noTools)
        #expect(DegradedMode.reducedContext.milder == .full)
    }

    @Test("policy maps breaker state onto a rung")
    func policyMapping() {
        let policy = DegradationPolicy.default
        #expect(policy.mode(for: .closed, signal: .guardrailViolation) == .full)
        #expect(policy.mode(for: .open, signal: .guardrailViolation) == .deterministicOnly)
        #expect(policy.mode(for: .halfOpen, signal: .guardrailViolation) == .noTools)
        #expect(policy.mode(for: .open, signal: .deadline) == .noTools)
        #expect(policy.threshold(for: .modelUnavailable) == 2)
        // Unknown-to-the-policy classes fall back to the defaults.
        let bare = DegradationPolicy()
        #expect(bare.threshold(for: .deadline) == 3)
        #expect(bare.openMode(for: .deadline) == .reducedContext)
    }
}

// MARK: - Session wiring

@Suite("CompoundSession degradation")
struct SessionDegradationTests {
    private func sources() -> [RetrievedSource] {
        [
            RetrievedSource(
                id: "SRC-HIGH",
                title: "high",
                content: String(repeating: "alpha ", count: 40),
                score: 0.9
            ),
            RetrievedSource(
                id: "SRC-LOW",
                title: "low",
                content: String(repeating: "omega ", count: 40),
                score: 0.1
            )
        ]
    }

    private func session(
        model: DegradationFakeModel,
        health: HealthMonitor?,
        tracer: any Tracer = NullTracer(),
        tools: ToolRegistry = ToolRegistry(),
        capture: ToolCapture? = nil,
        fallback: (@Sendable (String) async throws -> String)? = nil
    ) -> CompoundSession {
        CompoundSession(.init(
            assembler: DefaultContextAssembler(
                baseInstructions: "be helpful",
                retriever: StaticRetriever(sources())
            ),
            tools: tools,
            tracer: tracer,
            tokenCounter: HeuristicTokenCounter(charsPerToken: 4, contextSize: 200),
            makeModel: { _, tools, _ in
                capture?.record(tools)
                return model
            },
            health: health,
            degradedFallback: fallback,
            reducedContextFactor: 0.25
        ))
    }

    @Test("full mode leaves the prompt and the tool registry alone")
    func fullModeIsUnchanged() async throws {
        let model = DegradationFakeModel()
        let capture = ToolCapture()
        var registry = ToolRegistry()
        try registry.register(CalculatorTool())
        let session = session(model: model, health: nil, tools: registry, capture: capture)

        _ = try await session.respond(to: "hi")

        let prompts = await model.prompts
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("SRC-HIGH"))
        #expect(prompts[0].contains("SRC-LOW"))
        #expect(capture.toolNames == [["calculator"]])
        #expect(await session.currentDegradedMode() == .full)
    }

    @Test("reducedContext squeezes the assembled prompt")
    func reducedContextTrimsSources() async throws {
        let model = DegradationFakeModel()
        let health = HealthMonitor(policy: .default)
        let session = session(model: model, health: health)

        _ = try await session.respond(to: "hi")
        await health.setOverride(.reducedContext)
        _ = try await session.respond(to: "hi")

        let prompts = await model.prompts
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("SRC-LOW"))
        // The reduced run evicts lowest-score-first, so the weak source is
        // the one that cannot survive the squeezed budget.
        #expect(!prompts[1].contains("SRC-LOW"))
        #expect(prompts[1].utf8.count < prompts[0].utf8.count)
    }

    @Test("noTools withholds the registry for the run")
    func noToolsSkipsRegistration() async throws {
        let model = DegradationFakeModel()
        let capture = ToolCapture()
        var registry = ToolRegistry()
        try registry.register(CalculatorTool())
        let health = HealthMonitor(policy: .default)
        let session = session(model: model, health: health, tools: registry, capture: capture)

        _ = try await session.respond(to: "hi")
        await health.setOverride(.noTools)
        _ = try await session.respond(to: "hi")

        #expect(capture.toolNames == [["calculator"], []])
    }

    @Test("deterministicOnly refuses the model call with a typed error")
    func deterministicOnlyRefuses() async throws {
        let model = DegradationFakeModel()
        let health = HealthMonitor(policy: .default)
        let session = session(model: model, health: health)
        await health.setOverride(.deterministicOnly)

        do {
            _ = try await session.respond(to: "hi")
            Issue.record("expected CompoundError.degraded")
        } catch let error as CompoundError {
            guard case .degraded(let mode, let reason) = error else {
                Issue.record("expected degraded, got \(error)")
                return
            }
            #expect(mode == .deterministicOnly)
            #expect(reason == "manual override")
            #expect(error.layer == .control)
            #expect(error.severity == .recoverable)
        }
        #expect(await model.calls == 0)
    }

    @Test("deterministicOnly returns the caller's fallback when one exists")
    func deterministicOnlyUsesFallback() async throws {
        let model = DegradationFakeModel()
        let health = HealthMonitor(policy: .default)
        let session = session(
            model: model,
            health: health,
            fallback: { prompt in "canned answer for \(prompt)" }
        )
        await health.setOverride(.deterministicOnly)

        let outcome = try await session.respond(to: "hi")
        #expect(outcome.output == "canned answer for hi")
        #expect(outcome.confidence == nil)
        #expect(outcome.usage.turns == 0)
        #expect(await model.calls == 0)
    }

    @Test("streaming refuses at deterministicOnly rather than faking a stream")
    func streamRefusesAtDeterministicOnly() async throws {
        let model = DegradationFakeModel()
        let health = HealthMonitor(policy: .default)
        let session = session(model: model, health: health, fallback: { _ in "canned" })
        await health.setOverride(.deterministicOnly)

        do {
            _ = try await session.stream(userPrompt: "hi")
            Issue.record("expected CompoundError.degraded")
        } catch let error as CompoundError {
            guard case .degraded = error else {
                Issue.record("expected degraded, got \(error)")
                return
            }
        }
        #expect(await model.calls == 0)
    }

    @Test("seeded guardrail violations trip the breaker across runs and degrade the next one")
    func violationsAcrossRunsDegrade() async throws {
        let tracer = InMemoryTracer()
        let model = DegradationFakeModel(failure: .guardrailViolation(context: "blocked"))
        let health = HealthMonitor(
            policy: DegradationPolicy(
                thresholds: [.guardrailViolation: 2],
                openModes: [.guardrailViolation: .deterministicOnly],
                cooldown: .seconds(60)
            ),
            tracer: tracer
        )
        let session = session(model: model, health: health, tracer: tracer)

        for _ in 0..<2 {
            await #expect(throws: CompoundError.self) {
                _ = try await session.respond(to: "hi")
            }
        }
        #expect(await model.calls == 2)
        #expect(await health.state(for: .guardrailViolation) == .open)

        // The third run never reaches the transport: the ladder short-
        // circuits it before the model is constructed.
        await #expect(throws: CompoundError.self) {
            _ = try await session.respond(to: "hi")
        }
        #expect(await model.calls == 2)

        let events = await tracer.snapshot()
        #expect(events.contains { if case .breakerTransitioned = $0 { return true }; return false })
        let degraded = events.compactMap { event -> DegradedMode? in
            guard case .degradationApplied(_, let mode, _) = event else { return nil }
            return mode
        }
        #expect(degraded == [.deterministicOnly])
    }

    @Test("a successful run clears the failure streak")
    func successClearsStreak() async throws {
        let failing = DegradationFakeModel(failure: .guardrailViolation(context: nil))
        let health = HealthMonitor(policy: DegradationPolicy(thresholds: [.guardrailViolation: 2]))
        let failingSession = session(model: failing, health: health)
        await #expect(throws: CompoundError.self) {
            _ = try await failingSession.respond(to: "hi")
        }
        #expect(await health.failures(for: .guardrailViolation) == 1)

        let healthy = DegradationFakeModel()
        let healthySession = session(model: healthy, health: health)
        _ = try await healthySession.respond(to: "hi")
        #expect(await health.failures(for: .guardrailViolation) == 0)
    }

    @Test("verifier rejections never degrade the session")
    func verifierRejectionIsNotAHealthSignal() async throws {
        let model = DegradationFakeModel()
        let health = HealthMonitor(policy: DegradationPolicy(thresholds: [.guardrailViolation: 1]))
        let rejecting = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            outputVerifier: VerifierChain<String>(name: "out", [
                AnyVerifier<String>(name: "always-reject", cost: .parse) { _, _ in
                    .reject(Diagnostic(verifier: "always-reject", message: "nope"))
                }
            ]),
            makeModel: { _, _, _ in model },
            health: health
        ))

        for _ in 0..<3 {
            await #expect(throws: CompoundError.self) {
                _ = try await rejecting.respond(to: "hi")
            }
        }
        #expect(await rejecting.currentDegradedMode() == .full)
    }

    @Test("session inspection reports the rung and honors an override")
    func inspectionSurface() async throws {
        let model = DegradationFakeModel()
        let health = HealthMonitor(policy: .default)
        let session = session(model: model, health: health)

        #expect(await session.currentDegradedMode() == .full)
        await session.setDegradedMode(.reducedContext)
        #expect(await session.currentDegradedMode() == .reducedContext)
        #expect(await session.healthAssessment().isDegraded)
        await session.setDegradedMode(nil)
        #expect(await session.currentDegradedMode() == .full)
    }

    @Test("a session without a monitor never degrades")
    func withoutMonitorNeverDegrades() async throws {
        let model = DegradationFakeModel(failure: .modelUnavailable(reason: "off"))
        let session = session(model: model, health: nil)
        for _ in 0..<4 {
            await #expect(throws: CompoundError.self) {
                _ = try await session.respond(to: "hi")
            }
        }
        #expect(await model.calls == 4)
        #expect(await session.currentDegradedMode() == .full)
        #expect(await session.healthAssessment().states.isEmpty)
    }
}
