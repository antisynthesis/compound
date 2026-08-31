import Foundation
import FoundationModels
import Testing
@testable import Compound

// MARK: - Fixtures

/// Assembler returning a fixed context, so tests control every field the
/// token-budgeted wrapper reads.
private struct FixedSourcesAssembler: ContextAssembler {
    var instructions: String = ""
    var sources: [RetrievedSource]
    var transcript: PromptTranscript?
    var framing: any PromptFraming = PromptFrame()

    init(
        instructions: String = "",
        sources: [RetrievedSource],
        transcript: PromptTranscript? = nil,
        framing: any PromptFraming = PromptFrame()
    ) {
        self.instructions = instructions
        self.sources = sources
        self.transcript = transcript
        self.framing = framing
    }

    func assemble(userPrompt: String, runContext _: RunContext) async throws -> AssembledContext {
        AssembledContext(
            instructions: instructions,
            userPrompt: userPrompt,
            sources: sources,
            redactionsApplied: [],
            transcript: transcript,
            framing: framing
        )
    }
}

/// Frame that renders only source IDs — its cost is independent of source
/// content, which lets tests prove the assembler charges the *frame's*
/// rendering, not a hardcoded format.
private struct MarkerFrame: PromptFraming {
    func render(sources: [RetrievedSource], transcript _: PromptTranscript?, userPrompt: String) -> String {
        "MARKER|\(sources.map(\.id).joined(separator: "+"))|\(userPrompt)"
    }
}

/// One token per UTF-8 byte — a deliberately different scale from the
/// heuristic, to prove the injected counter is the one consulted.
private struct CharCounter: TokenCounting {
    var contextSize: Int = 1000
    func count(_ text: String) async -> Int { text.utf8.count }
}

private func bigSource(_ id: String, score: Double?, bytes: Int = 1000) -> RetrievedSource {
    RetrievedSource(id: id, title: id.uppercased(), content: String(repeating: "x", count: bytes), score: score)
}

private func infoMessages(_ events: [TraceEvent], category: String) -> [String] {
    events.compactMap {
        if case .info(_, let cat, let message) = $0, cat == category { return message }
        return nil
    }
}

// MARK: - HeuristicTokenCounter

@Suite("HeuristicTokenCounter")
struct HeuristicTokenCounterTests {
    @Test("matches Budget.approximateTokens at the default divisor")
    func matchesBudgetHeuristic() async {
        let counter = HeuristicTokenCounter()
        for sample in ["", "abc", "hello world", String(repeating: "é", count: 100)] {
            #expect(await counter.count(sample) == Budget.approximateTokens(sample))
        }
    }

    @Test("custom divisor and floor of one")
    func customDivisor() async {
        let counter = HeuristicTokenCounter(charsPerToken: 2)
        #expect(await counter.count("abcd") == 2)
        #expect(await counter.count("") == 1)
    }

    @Test("defaults document the on-device floor")
    func defaults() {
        let counter = HeuristicTokenCounter()
        #expect(counter.contextSize == 4096)
        #expect(counter.charsPerToken == 4)
    }
}

// MARK: - SessionTokenLedger

@Suite("SessionTokenLedger")
struct SessionTokenLedgerTests {
    @Test("crossing fires exactly once on the transition")
    func crossingOnlyOnTransition() async {
        let ledger = SessionTokenLedger(contextSize: 100, highWatermarkFraction: 0.8)
        #expect(ledger.highWatermark == 80)
        #expect(await ledger.record(promptTokens: 40, outputTokens: 0) == false)
        #expect(await ledger.record(promptTokens: 40, outputTokens: 0) == true)
        #expect(await ledger.record(promptTokens: 10, outputTokens: 0) == false)
        #expect(await ledger.isAboveWatermark)
        #expect(await ledger.estimatedTokens == 90)
    }

    @Test("reconcile below the watermark re-arms crossing detection")
    func reconcileRearms() async {
        let ledger = SessionTokenLedger(contextSize: 100, highWatermarkFraction: 0.8)
        _ = await ledger.record(promptTokens: 90, outputTokens: 0)
        #expect(await ledger.reconcile(measuredTokens: 10) == false)
        #expect(await ledger.isAboveWatermark == false)
        #expect(await ledger.record(promptTokens: 80, outputTokens: 0) == true)
    }

    @Test("reset seeds occupancy and recomputes crossing state")
    func resetSeedsOccupancy() async {
        let ledger = SessionTokenLedger(contextSize: 100, highWatermarkFraction: 0.8)
        await ledger.reset(to: 90)
        // Already above at reset: further records must not re-fire.
        #expect(await ledger.record(promptTokens: 1, outputTokens: 0) == false)
        await ledger.reset(to: 0)
        #expect(await ledger.estimatedTokens == 0)
        #expect(await ledger.record(promptTokens: 85, outputTokens: 0) == true)
    }

    @Test("default watermark is 80% of the window; negative inputs clamp")
    func defaultsAndClamping() async {
        let ledger = SessionTokenLedger(contextSize: 1000)
        #expect(ledger.highWatermark == 800)
        _ = await ledger.record(promptTokens: -5, outputTokens: -5)
        #expect(await ledger.estimatedTokens == 0)
        _ = await ledger.reconcile(measuredTokens: -7)
        #expect(await ledger.estimatedTokens == 0)
    }
}

// MARK: - TokenBudgetedAssembler

@Suite("TokenBudgetedAssembler")
struct TokenBudgetedAssemblerTests {
    @Test("passes context through untouched when it fits")
    func passthroughWhenFits() async throws {
        let transcript = PromptTranscript(summary: "earlier", messages: [])
        let inner = FixedSourcesAssembler(
            instructions: "be brief",
            sources: [bigSource("a", score: 0.9, bytes: 40)],
            transcript: transcript
        )
        let tracer = InMemoryTracer()
        let assembler = TokenBudgetedAssembler(wrapping: inner, maxPromptTokens: 10_000)
        let assembled = try await assembler.assemble(userPrompt: "hi", runContext: RunContext(tracer: tracer))
        #expect(assembled.sources.map(\.id) == ["a"])
        #expect(assembled.transcript == transcript)
        let events = await tracer.events
        #expect(infoMessages(events, category: "retrieval").isEmpty)
    }

    @Test("drops lowest-score sources first; kept sources stay in order")
    func dropsLowestScoreFirst() async throws {
        let inner = FixedSourcesAssembler(sources: [
            bigSource("a", score: 0.9),
            bigSource("b", score: 0.1),
            bigSource("c", score: 0.5),
        ])
        let assembler = TokenBudgetedAssembler(wrapping: inner, maxPromptTokens: 400)
        let assembled = try await assembler.assemble(userPrompt: "hi", runContext: RunContext())
        #expect(assembled.sources.count < 3)
        #expect(assembled.sources.contains { $0.id == "a" })
        // Whatever remains preserves original selection order.
        let keptIDs = assembled.sources.map(\.id)
        #expect(keptIDs == ["a", "b", "c"].filter(keptIDs.contains))
    }

    @Test("nil-score sources are pinned behind every scored source")
    func nilScorePinned() async throws {
        let inner = FixedSourcesAssembler(sources: [
            bigSource("pinned", score: nil),
            bigSource("scored", score: 0.99),
        ])
        // Budget fits roughly one source: the scored one must go first
        // even though its score is high, because nil means "keep".
        let assembler = TokenBudgetedAssembler(wrapping: inner, maxPromptTokens: 350)
        let assembled = try await assembler.assemble(userPrompt: "hi", runContext: RunContext())
        #expect(assembled.sources.map(\.id) == ["pinned"])
    }

    @Test("instructions are charged against the budget")
    func instructionsCharged() async throws {
        let sources = [bigSource("a", score: 0.9), bigSource("b", score: 0.1)]
        // Without instructions both sources fit this budget…
        let bare = TokenBudgetedAssembler(
            wrapping: FixedSourcesAssembler(sources: sources),
            maxPromptTokens: 700
        )
        let bareOut = try await bare.assemble(userPrompt: "hi", runContext: RunContext())
        #expect(bareOut.sources.count == 2)

        // …but 1600 bytes of instructions (~400 tokens) squeeze them out.
        let loaded = TokenBudgetedAssembler(
            wrapping: FixedSourcesAssembler(
                instructions: String(repeating: "i", count: 1600),
                sources: sources
            ),
            maxPromptTokens: 700
        )
        let loadedOut = try await loaded.assemble(userPrompt: "hi", runContext: RunContext())
        #expect(loadedOut.sources.count < 2)
    }

    @Test("cost is measured through the context's own framing (no drift)")
    func costGoesThroughFraming() async throws {
        // MarkerFrame renders only IDs, so huge source bodies cost nothing.
        // A format-string duplicate of the default frame would evict both.
        let inner = FixedSourcesAssembler(
            sources: [bigSource("a", score: 0.9, bytes: 10_000), bigSource("b", score: 0.1, bytes: 10_000)],
            framing: MarkerFrame()
        )
        let assembler = TokenBudgetedAssembler(wrapping: inner, maxPromptTokens: 50)
        let assembled = try await assembler.assemble(userPrompt: "hi", runContext: RunContext())
        #expect(assembled.sources.count == 2)
        #expect(assembled.renderedPrompt().hasPrefix("MARKER|"))
    }

    @Test("trimmed result actually fits: instructions + rendered prompt within budget")
    func trimmedResultFits() async throws {
        let instructions = String(repeating: "i", count: 200)
        let inner = FixedSourcesAssembler(
            instructions: instructions,
            sources: (0..<5).map { bigSource("s\($0)", score: Double($0) / 10, bytes: 600) }
        )
        let max = 500
        let counter = HeuristicTokenCounter()
        let assembler = TokenBudgetedAssembler(wrapping: inner, maxPromptTokens: max, counter: counter)
        let assembled = try await assembler.assemble(userPrompt: "question?", runContext: RunContext())
        #expect(!assembled.sources.isEmpty)
        let cost = (await counter.count(instructions)) + (await counter.count(assembled.renderedPrompt()))
        #expect(cost <= max)
    }

    @Test("empty-source edge: cost re-check uses the framing-free render")
    func emptySourcesRecheck() async throws {
        let inner = FixedSourcesAssembler(sources: [bigSource("a", score: 0.5), bigSource("b", score: 0.6)])
        let tracer = InMemoryTracer()
        // Tight budget: every source must go. With no sources PromptFrame
        // renders the bare user prompt, which fits — so the final cost
        // check must not report an over-budget prompt.
        let assembler = TokenBudgetedAssembler(wrapping: inner, maxPromptTokens: 2)
        let assembled = try await assembler.assemble(userPrompt: "hi", runContext: RunContext(tracer: tracer))
        #expect(assembled.sources.isEmpty)
        #expect(assembled.renderedPrompt() == "hi")
        let messages = infoMessages(await tracer.events, category: "retrieval")
        #expect(messages.count == 1)
        #expect(messages[0].contains("dropped sources for budget"))
        #expect(!messages.contains { $0.contains("exceeds token budget") })
    }

    @Test("still-over-budget prompt is surfaced, not silently accepted")
    func overBudgetSurfaced() async throws {
        let inner = FixedSourcesAssembler(
            instructions: String(repeating: "i", count: 400),
            sources: [bigSource("a", score: 0.5)]
        )
        let tracer = InMemoryTracer()
        let assembler = TokenBudgetedAssembler(wrapping: inner, maxPromptTokens: 20)
        let assembled = try await assembler.assemble(userPrompt: "hi", runContext: RunContext(tracer: tracer))
        #expect(assembled.sources.isEmpty)
        let messages = infoMessages(await tracer.events, category: "retrieval")
        #expect(messages.contains { $0.contains("exceeds token budget") })
    }

    @Test("dropped-source trace lists exactly the evicted IDs")
    func traceListsDroppedIDs() async throws {
        let inner = FixedSourcesAssembler(sources: [
            bigSource("keep", score: 0.9),
            bigSource("drop1", score: 0.1),
            bigSource("drop2", score: 0.2),
        ])
        let tracer = InMemoryTracer()
        let assembler = TokenBudgetedAssembler(wrapping: inner, maxPromptTokens: 400)
        let assembled = try await assembler.assemble(userPrompt: "hi", runContext: RunContext(tracer: tracer))
        #expect(assembled.sources.map(\.id) == ["keep"])
        let messages = infoMessages(await tracer.events, category: "retrieval")
        #expect(messages.contains { $0.contains("drop1") && $0.contains("drop2") && !$0.contains("keep") })
    }

    @Test("injected counter is the one consulted")
    func injectedCounterUsed() async throws {
        let sources = [bigSource("a", score: 0.9), bigSource("b", score: 0.1)]
        // Heuristic scale (~4 bytes/token): everything fits under 2000.
        let heuristic = TokenBudgetedAssembler(
            wrapping: FixedSourcesAssembler(sources: sources),
            maxPromptTokens: 2000
        )
        let heuristicOut = try await heuristic.assemble(userPrompt: "hi", runContext: RunContext())
        #expect(heuristicOut.sources.count == 2)

        // CharCounter scale (1 byte/token): the same budget forces drops.
        let charBased = TokenBudgetedAssembler(
            wrapping: FixedSourcesAssembler(sources: sources),
            maxPromptTokens: 2000,
            counter: CharCounter()
        )
        let charOut = try await charBased.assemble(userPrompt: "hi", runContext: RunContext())
        #expect(charOut.sources.count < 2)
    }

    @Test("duplicate source IDs do not trap")
    func duplicateIDsSafe() async throws {
        let inner = FixedSourcesAssembler(sources: [
            bigSource("dup", score: 0.4),
            bigSource("dup", score: 0.6),
            bigSource("other", score: 0.9),
        ])
        let assembler = TokenBudgetedAssembler(wrapping: inner, maxPromptTokens: 400)
        let assembled = try await assembler.assemble(userPrompt: "hi", runContext: RunContext())
        #expect(assembled.sources.count <= 3)
    }
}

// MARK: - CompoundSession context-overflow rerouting

/// Fake transport that throws a scripted error for the first N calls, then
/// answers normally. Captures every prompt it is asked.
private actor OverflowFakeModel: ModelResponding, ModelStreaming {
    private var failuresRemaining: Int
    private let error: CompoundError
    private(set) var prompts: [String] = []

    init(failures: Int, error: CompoundError = .contextWindowExceeded(promptTokens: 9999)) {
        self.failuresRemaining = failures
        self.error = error
    }

    func respond(to prompt: String, options _: GenerationOptions) async throws -> String {
        prompts.append(prompt)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw error
        }
        return "ok"
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
            let output = try await self.respond(to: prompt, options: options)
            cont.yield(output)
            cont.finish()
            return output
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

private actor AssembleMeter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private struct MeteredAssembler: ContextAssembler {
    let meter: AssembleMeter
    let sources: [RetrievedSource]

    func assemble(userPrompt: String, runContext _: RunContext) async throws -> AssembledContext {
        await meter.bump()
        return AssembledContext(
            instructions: "sys",
            userPrompt: userPrompt,
            sources: sources,
            redactionsApplied: []
        )
    }
}

@Suite("CompoundSession context-overflow rerouting")
struct ContextOverflowReroutingTests {
    private func makeSession(
        model: OverflowFakeModel,
        meter: AssembleMeter,
        sourceBytes: Int = 20_000
    ) -> CompoundSession {
        CompoundSession(.init(
            assembler: MeteredAssembler(
                meter: meter,
                sources: [bigSource("huge", score: 0.1, bytes: sourceBytes)]
            ),
            makeModel: { _, _, _ in model }
        ))
    }

    @Test("contextWindowExceeded reroutes through a token-budgeted re-assembly once")
    func reroutesOnOverflow() async throws {
        let model = OverflowFakeModel(failures: 1)
        let meter = AssembleMeter()
        let session = makeSession(model: model, meter: meter)

        let outcome = try await session.respond(to: "hi")
        #expect(outcome.output == "ok")
        #expect(await meter.count == 2)

        let prompts = await model.prompts
        try #require(prompts.count == 2)
        // The retry prompt was assembled under a hard token budget: the
        // 20KB source (over 80% of the heuristic 4096-token window) must
        // be gone.
        #expect(prompts[0].utf8.count > 20_000)
        #expect(prompts[1].utf8.count < prompts[0].utf8.count)
        #expect(!prompts[1].contains(String(repeating: "x", count: 100)))
    }

    @Test("non-overflow errors propagate without re-assembly")
    func otherErrorsPropagate() async throws {
        let model = OverflowFakeModel(failures: 1, error: .guardrailViolation(context: nil))
        let meter = AssembleMeter()
        let session = makeSession(model: model, meter: meter)

        await #expect(throws: CompoundError.self) {
            _ = try await session.respond(to: "hi")
        }
        #expect(await meter.count == 1)
    }

    @Test("persistent overflow surfaces the typed error after one retry")
    func persistentOverflowPropagates() async throws {
        let model = OverflowFakeModel(failures: 2)
        let meter = AssembleMeter()
        let session = makeSession(model: model, meter: meter)

        do {
            _ = try await session.respond(to: "hi")
            Issue.record("expected contextWindowExceeded")
        } catch let error as CompoundError {
            guard case .contextWindowExceeded = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        #expect(await meter.count == 2)
    }
}
