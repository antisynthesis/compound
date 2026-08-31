import Foundation
import FoundationModels
import Testing
@testable import Compound

// MARK: - Fakes

/// Returns a scripted queue of candidate outputs, one per `respond` call,
/// and records the prompt and the generation options each call saw. When the
/// script runs out it keeps returning the last scripted output, so a test
/// that under-scripts fails on a budget assertion rather than hanging.
private actor ScriptedCandidateModel: ModelResponding {
    private var queue: [String]
    private let tail: String
    private(set) var prompts: [String] = []
    private(set) var temperatures: [Double?] = []
    private(set) var samplingModes: [GenerationOptions.SamplingMode?] = []

    init(_ outputs: [String]) {
        precondition(!outputs.isEmpty, "script at least one output")
        self.queue = outputs
        self.tail = outputs[outputs.count - 1]
    }

    var calls: Int { prompts.count }

    func respond(to prompt: String, options: GenerationOptions) async throws -> String {
        prompts.append(prompt)
        temperatures.append(options.temperature)
        samplingModes.append(options.samplingMode)
        guard !queue.isEmpty else { return tail }
        return queue.removeFirst()
    }

    func respondGenerating<T: Generable & Sendable>(
        _: T.Type,
        to _: String,
        options _: GenerationOptions
    ) async throws -> T {
        fatalError("unused in best-of-N tests")
    }
}

/// Passes exactly when `output` contains `needle`; repairs otherwise.
private func containsVerifier(_ name: String, needle: String) -> AnyVerifier<String> {
    AnyVerifier<String>(name: name, cost: .parse) { input, _ in
        input.contains(needle)
            ? .pass
            : .repair(Diagnostic(verifier: name, message: "missing \(needle)"))
    }
}

/// Terminally rejects any output containing `needle`.
private func rejectingVerifier(_ name: String, needle: String) -> AnyVerifier<String> {
    AnyVerifier<String>(name: name, cost: .parse) { input, _ in
        input.contains(needle)
            ? .reject(Diagnostic(verifier: name, message: "contraband: \(needle)"))
            : .pass
    }
}

private func bestOfNEvents(_ events: [TraceEvent]) -> [(candidates: Int, scores: [Double], agreement: Double?, selected: Int)] {
    events.compactMap { event in
        guard case .bestOfNSampled(_, let candidates, let scores, let agreement, let selected) = event else {
            return nil
        }
        return (candidates, scores, agreement, selected)
    }
}

// MARK: - Agreement rate

@Suite("AgreementRate")
struct AgreementRateTests {
    @Test("identical candidates agree completely and disjoint candidates not at all")
    func identicalAndDisjoint() {
        #expect(AgreementRate.meanPairwise(["alpha beta", "alpha beta"]) == 1)
        #expect(AgreementRate.meanPairwise(["alpha beta", "gamma delta"]) == 0)
    }

    @Test("partial overlap is the Jaccard ratio")
    func partialOverlap() throws {
        // {a, b} vs {b, c}: one shared token out of three distinct.
        let value = try #require(AgreementRate.meanPairwise(["a b", "b c"]))
        #expect(abs(value - 1.0 / 3.0) < 1e-12)
    }

    @Test("mean is taken over every unordered pair")
    func meanOverPairs() throws {
        // Pairs: (a,a)=1, (a,b)=0, (a,b)=0 → 1/3.
        let value = try #require(AgreementRate.meanPairwise(["a", "a", "b"]))
        #expect(abs(value - 1.0 / 3.0) < 1e-12)
    }

    @Test("fewer than two candidates leaves agreement undefined")
    func undefinedBelowTwo() {
        #expect(AgreementRate.meanPairwise([]) == nil)
        #expect(AgreementRate.meanPairwise(["only one"]) == nil)
    }

    @Test("normalization folds away case, punctuation, and repetition")
    func normalization() {
        #expect(AgreementRate.jaccard("Hello, world!", "hello   world") == 1)
        #expect(AgreementRate.jaccard("yes yes yes", "yes") == 1)
        #expect(AgreementRate.tokens("Hello, world! 42") == ["hello", "world", "42"])
    }

    @Test("two token-free texts agree; one empty against one non-empty does not")
    func emptyTexts() {
        #expect(AgreementRate.jaccard("", "") == 1)
        #expect(AgreementRate.jaccard("   ...  ", "!!!") == 1)
        #expect(AgreementRate.jaccard("", "something") == 0)
    }
}

// MARK: - Generation-options variation

@Suite("SampleVariation")
struct SampleVariationTests {
    @Test("the default variation walks an ascending, clamped temperature ladder")
    func defaultLadder() {
        let base = GenerationOptions()
        let ladder = (0..<5).map { base.varied(forSample: $0, by: .default).temperature }
        #expect(ladder[0] == 0.3)
        #expect(ladder[1] == 0.55)
        #expect(ladder[2] == 0.8)
        // 0.3 + 3 × 0.25 = 1.05, clamped to the maximum.
        #expect(ladder[3] == 1.0)
        #expect(ladder[4] == 1.0)
    }

    @Test("the fixed variation leaves the caller's options untouched")
    func fixedVariation() {
        let base = GenerationOptions(temperature: 0.9, maximumResponseTokens: 128)
        for index in 0..<4 {
            let varied = base.varied(forSample: index, by: .fixed)
            #expect(varied.temperature == 0.9)
            #expect(varied.maximumResponseTokens == 128)
            #expect(varied.samplingMode == nil)
        }
    }

    @Test("a seed base makes each candidate's sampling mode distinct and reproducible")
    func seededSamplingMode() {
        let variation = SampleVariation(seedBase: 7, topK: 12)
        let base = GenerationOptions()
        #expect(base.varied(forSample: 0, by: variation).samplingMode == .random(top: 12, seed: 7))
        #expect(base.varied(forSample: 3, by: variation).samplingMode == .random(top: 12, seed: 10))
        // Deriving twice yields the same options — the whole point of a seed.
        #expect(
            base.varied(forSample: 2, by: variation) == base.varied(forSample: 2, by: variation)
        )
    }

    @Test("variation carries unrelated options through untouched")
    func carriesUnrelatedOptions() {
        let base = GenerationOptions(maximumResponseTokens: 64)
        let varied = base.varied(forSample: 1, by: .default)
        #expect(varied.maximumResponseTokens == 64)
        #expect(varied.temperature == 0.55)
    }
}

// MARK: - Selection

@Suite("BestOfN selection")
struct BestOfNSelectionTests {
    @Test("firstPassing takes the first verifier-passing candidate and stops drawing")
    func firstPassingStopsEarly() async throws {
        let model = ScriptedCandidateModel(["bad", "good", "never drawn"])
        let chain = VerifierChain<String>(name: "out", [containsVerifier("wants-good", needle: "good")])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: chain,
            sampling: .bestOf(n: 3, selection: .firstPassing)
        )

        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())

        #expect(outcome.output == "good")
        #expect(outcome.usage.samples == 2, "the third candidate must never be drawn")
        #expect(outcome.usage.turns == 1)
        let calls = await model.calls
        #expect(calls == 2)
        // "bad" and "good" share no tokens.
        #expect(outcome.confidence == 0)
    }

    @Test("weighted selection prefers the candidate that passed the heavier verifier")
    func weightedPrefersHeavyVerifier() async throws {
        let model = ScriptedCandidateModel(["alpha LOOSE", "beta STRICT", "gamma LOOSE STRICT"])
        let chain = VerifierChain<String>(name: "out", [
            containsVerifier("loose", needle: "LOOSE"),
            containsVerifier("strict", needle: "STRICT")
        ])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: chain,
            sampling: .bestOf(n: 2, selection: .weightedVerifierScore(weights: ["strict": 5, "loose": 1]))
        )

        let outcome = try await loop.run(prompt: "task", modelClient: model, runContext: RunContext())

        #expect(outcome.output == "gamma LOOSE STRICT")
        #expect(outcome.usage.repairAttempts == 1)
        let prompts = await model.prompts
        let repairPrompt = try #require(prompts.dropFirst(2).first)
        #expect(repairPrompt.contains("beta STRICT"), "the 5-weighted winner must seed the repair")
        #expect(!repairPrompt.contains("alpha LOOSE"), "a losing candidate must not leak into the repair prompt")
        #expect(!repairPrompt.contains("missing STRICT"), "a losing candidate's diagnostics must not leak either")
    }

    @Test("uniform weights break the same tie toward the earliest candidate")
    func uniformWeightsBreakTiesByIndex() async throws {
        let model = ScriptedCandidateModel(["alpha LOOSE", "beta STRICT", "gamma LOOSE STRICT"])
        let chain = VerifierChain<String>(name: "out", [
            containsVerifier("loose", needle: "LOOSE"),
            containsVerifier("strict", needle: "STRICT")
        ])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: chain,
            sampling: .bestOf(n: 2, selection: .weightedVerifierScore())
        )

        _ = try await loop.run(prompt: "task", modelClient: model, runContext: RunContext())

        let prompts = await model.prompts
        let repairPrompt = try #require(prompts.dropFirst(2).first)
        #expect(repairPrompt.contains("alpha LOOSE"))
        #expect(!repairPrompt.contains("beta STRICT"))
    }

    @Test("a fully-passing candidate wins outright over a higher-indexed one")
    func passingCandidateWins() async throws {
        let model = ScriptedCandidateModel(["nope", "LOOSE STRICT", "also nope"])
        let chain = VerifierChain<String>(name: "out", [
            containsVerifier("loose", needle: "LOOSE"),
            containsVerifier("strict", needle: "STRICT")
        ])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: chain,
            sampling: .bestOf(n: 3, selection: .weightedVerifierScore())
        )

        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        #expect(outcome.output == "LOOSE STRICT")
        #expect(outcome.usage.repairAttempts == 0)
        #expect(outcome.usage.samples == 3, "weighted selection always draws the full set")
    }

    @Test("best-of-N evaluates every member even when the chain short-circuits")
    func evaluatesEveryMemberDespiteShortCircuit() async throws {
        // Under short-circuit evaluation both candidates would stop at
        // "a-fail" and score identically, so the tie would go to index 0.
        let model = ScriptedCandidateModel(["y", "x", "x SECOND"])
        let chain = VerifierChain<String>(name: "out", mode: .shortCircuit, [
            AnyVerifier<String>(name: "a-fail", cost: .parse) { _, _ in
                .repair(Diagnostic(verifier: "a-fail", message: "always fails"))
            },
            containsVerifier("b-wants-x", needle: "x")
        ])
        let loop = ControlLoop(
            budget: Budget(maxTurns: 2, maxRepairAttempts: 1),
            outputVerifier: chain,
            sampling: .bestOf(n: 2, selection: .weightedVerifierScore())
        )

        await #expect(throws: CompoundError.self) {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        }
        let prompts = await model.prompts
        let repairPrompt = try #require(prompts.dropFirst(2).first)
        #expect(repairPrompt.contains("Failed response:\nx"), "the half-passing candidate must win")
    }

    @Test("a terminally rejected candidate is skipped while a clean one survives")
    func disqualifiedCandidateIsSkipped() async throws {
        let model = ScriptedCandidateModel(["poison here", "clean"])
        let chain = VerifierChain<String>(name: "out", [rejectingVerifier("gate", needle: "poison")])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: chain,
            sampling: .bestOf(n: 2, selection: .weightedVerifierScore())
        )

        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        #expect(outcome.output == "clean")
        #expect(outcome.usage.repairAttempts == 0)
    }

    @Test("when every candidate is rejected the run fails with the terminal verdict")
    func allDisqualifiedRejects() async throws {
        let model = ScriptedCandidateModel(["poison one", "poison two"])
        let chain = VerifierChain<String>(name: "out", [rejectingVerifier("gate", needle: "poison")])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: chain,
            sampling: .bestOf(n: 2, selection: .weightedVerifierScore())
        )

        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
            Issue.record("expected verifierRejected")
        } catch CompoundError.verifierRejected(let reason, let diagnostic) {
            #expect(reason.contains("contraband"))
            #expect(diagnostic?.verifier == "gate")
        }
    }
}

// MARK: - Budget

@Suite("BestOfN budget")
struct BestOfNBudgetTests {
    @Test("each candidate debits one sample")
    func debitsOneSamplePerCandidate() async throws {
        let model = ScriptedCandidateModel(["one", "two", "three"])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: .empty(),
            sampling: .bestOf(n: 3, selection: .weightedVerifierScore())
        )

        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        #expect(outcome.usage.samples == 3)
        #expect(outcome.usage.turns == 1, "a best-of-N draw is still one loop turn")
        let calls = await model.calls
        #expect(calls == 3)
    }

    @Test("single-candidate runs never debit the sample dimension")
    func singleStrategyRecordsNoSamples() async throws {
        let model = ScriptedCandidateModel(["only"])
        let loop = ControlLoop(budget: .default, outputVerifier: .empty())

        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        #expect(outcome.usage.samples == 0)
        #expect(outcome.confidence == nil, "one candidate has no one to agree with")
    }

    @Test("maxSamples stops the draw early and selects from what was drawn")
    func maxSamplesCapsTheDraw() async throws {
        let model = ScriptedCandidateModel(["one", "two", "three", "four"])
        let budget = Budget(maxTurns: 4, maxSamples: 2)
        let loop = ControlLoop(
            budget: budget,
            outputVerifier: .empty(),
            sampling: .bestOf(n: 4, selection: .weightedVerifierScore())
        )

        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        #expect(outcome.usage.samples == 2)
        #expect(outcome.output == "one")
        let calls = await model.calls
        #expect(calls == 2)
    }

    @Test("a sample budget of zero fails the run before any candidate exists")
    func zeroSampleBudgetThrows() async throws {
        let model = ScriptedCandidateModel(["never drawn"])
        let budget = Budget(maxTurns: 4, maxSamples: 0)
        let loop = ControlLoop(
            budget: budget,
            outputVerifier: .empty(),
            sampling: .bestOf(n: 2, selection: .weightedVerifierScore())
        )

        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
            Issue.record("expected budgetExhausted(.samples)")
        } catch CompoundError.budgetExhausted(let kind, let usage) {
            #expect(kind == .samples)
            #expect(usage.samples == 0)
        }
        let calls = await model.calls
        #expect(calls == 0)
    }

    @Test("every drawn candidate's output tokens are accounted for, winners and losers alike")
    func accountsForEveryCandidatesTokens() async throws {
        let text = String(repeating: "z", count: 40)
        let model = ScriptedCandidateModel([text, text, text])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: .empty(),
            sampling: .bestOf(n: 3, selection: .weightedVerifierScore())
        )

        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        #expect(outcome.usage.outputTokens == 3 * Budget.approximateTokens(text))
    }

    @Test("Budget and BudgetUsage round-trip the new sampling dimensions")
    func samplingDimensionsRoundTrip() throws {
        let budget = Budget(maxTurns: 2, wallClock: .seconds(5), maxSamples: 6)
        let decoded = try JSONDecoder().decode(Budget.self, from: JSONEncoder().encode(budget))
        #expect(decoded == budget)
        #expect(decoded.maxSamples == 6)

        var usage = BudgetUsage()
        usage.recordSample()
        usage.recordSample()
        let decodedUsage = try JSONDecoder().decode(BudgetUsage.self, from: JSONEncoder().encode(usage))
        #expect(decodedUsage == usage)
        #expect(decodedUsage.samples == 2)

        // A budget with no cap omits the key entirely, so older traces
        // keep decoding and older readers keep working.
        let uncapped = String(decoding: try JSONEncoder().encode(Budget.default), as: UTF8.self)
        #expect(!uncapped.contains("max_samples"))
    }

    @Test("a negative maxSamples in a decoded budget throws instead of trapping")
    func negativeMaxSamplesThrows() throws {
        let json = Data(
            #"{"max_turns":1,"max_tool_calls":1,"max_repair_attempts":1,"wall_clock_ns":1000,"max_samples":-1}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Budget.self, from: json)
        }
    }
}

// MARK: - Observability

@Suite("BestOfN observability")
struct BestOfNObservabilityTests {
    @Test("the sampling trace event pins candidates, scores, agreement, and the winner")
    func traceEventPinned() async throws {
        let tracer = InMemoryTracer()
        let model = ScriptedCandidateModel(["alpha", "LOOSE STRICT", "gamma"])
        let chain = VerifierChain<String>(name: "out", [
            containsVerifier("loose", needle: "LOOSE"),
            containsVerifier("strict", needle: "STRICT")
        ])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: chain,
            sampling: .bestOf(n: 3, selection: .weightedVerifierScore())
        )

        _ = try await loop.run(
            prompt: "p",
            modelClient: model,
            runContext: RunContext(tracer: tracer)
        )

        let events = bestOfNEvents(await tracer.snapshot())
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.candidates == 3)
        #expect(event.scores == [0, 1, 0])
        #expect(event.selected == 1)
        // "alpha", "LOOSE STRICT", "gamma" share no tokens at all.
        #expect(event.agreement == 0)
    }

    @Test("the sampling event carries a stable label and survives redaction")
    func traceEventLabelAndRedaction() async throws {
        let runID = UUID()
        let event = TraceEvent.bestOfNSampled(
            runID: runID,
            candidates: 2,
            scores: [0.5, 1],
            agreement: nil,
            selectedIndex: 1
        )
        #expect(event.label == "sampling.best_of_n")

        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(json.contains("\"type\":\"sampling.best_of_n\""))
        #expect(!json.contains("agreement"), "an undefined agreement is omitted, never fabricated")
        #expect(try JSONDecoder().decode(TraceEvent.self, from: Data(json.utf8)) == event)

        // Numeric telemetry has no strings to scrub, so a blanket redactor
        // must forward the event untouched rather than fail closed.
        let inner = InMemoryTracer()
        await RedactingTracer(inner: inner, redactors: [BlanketRedactor()]).record(event)
        #expect(await inner.snapshot() == [event])
    }

    @Test("one bestOfNSampled event is emitted per turn, repairs included")
    func oneEventPerTurn() async throws {
        let tracer = InMemoryTracer()
        let model = ScriptedCandidateModel(["no", "no", "yes GOOD", "yes GOOD"])
        let chain = VerifierChain<String>(name: "out", [containsVerifier("wants-good", needle: "GOOD")])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: chain,
            sampling: .bestOf(n: 2, selection: .weightedVerifierScore())
        )

        let outcome = try await loop.run(
            prompt: "p",
            modelClient: model,
            runContext: RunContext(tracer: tracer)
        )
        #expect(outcome.usage.repairAttempts == 1)
        #expect(outcome.usage.samples == 4)
        let events = bestOfNEvents(await tracer.snapshot())
        #expect(events.count == 2)
        #expect(events[0].scores == [0, 0])
        #expect(events[1].scores == [1, 1])
        // Both candidates on the last turn were identical.
        #expect(events[1].agreement == 1)
        #expect(outcome.confidence == 1)
    }

    @Test("the model sees the per-candidate temperature ladder")
    func modelSeesVariedOptions() async throws {
        let model = ScriptedCandidateModel(["a", "b", "c"])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: .empty(),
            sampling: .bestOf(n: 3, selection: .weightedVerifierScore(), variation: .default)
        )

        _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        let temperatures = await model.temperatures
        #expect(temperatures == [0.3, 0.55, 0.8])
    }
}

// MARK: - Session surface

@Suite("BestOfN session configuration")
struct BestOfNSessionTests {
    @Test("CompoundSession routes its sampling strategy into the control loop")
    func sessionAppliesSampling() async throws {
        let model = ScriptedCandidateModel(["one", "two", "three"])
        let session = CompoundSession(
            .init(
                assembler: DefaultContextAssembler(baseInstructions: "be brief"),
                budget: .default,
                sampling: .bestOf(n: 3, selection: .weightedVerifierScore()),
                makeModel: { _, _, _ in SamplingSessionModel(inner: model) }
            )
        )

        let outcome = try await session.respond(to: "hello")
        #expect(outcome.usage.samples == 3)
        #expect(outcome.confidence != nil)
    }

    @Test("the default session configuration samples a single candidate")
    func sessionDefaultsToSingle() async throws {
        let model = ScriptedCandidateModel(["only"])
        let session = CompoundSession(
            .init(
                assembler: DefaultContextAssembler(baseInstructions: "be brief"),
                makeModel: { _, _, _ in SamplingSessionModel(inner: model) }
            )
        )

        let outcome = try await session.respond(to: "hello")
        #expect(outcome.usage.samples == 0)
        #expect(outcome.confidence == nil)
        let calls = await model.calls
        #expect(calls == 1)
    }
}

/// Adapts the non-streaming scripted fake to the `ModelResponding & ModelStreaming`
/// pair `CompoundSession.makeModel` requires.
private struct SamplingSessionModel: ModelResponding, ModelStreaming {
    let inner: ScriptedCandidateModel

    func respond(to prompt: String, options: GenerationOptions) async throws -> String {
        try await inner.respond(to: prompt, options: options)
    }

    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T {
        try await inner.respondGenerating(type, to: prompt, options: options)
    }

    func stream(to _: String, options _: GenerationOptions) async -> ModelStreamResult {
        fatalError("unused in best-of-N tests")
    }
}
