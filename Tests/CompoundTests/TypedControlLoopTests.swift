import Foundation
import FoundationModels
import Testing
@testable import Compound

// MARK: - Typed-loop fakes

// Plain Sendable value for loop-layer tests — deliberately NOT Generable,
// pinning that the typed loop surface is Generable-free.
private struct Ticket: Sendable, Equatable {
    var title: String
    var priority: Int
}

private struct ScriptExhausted: Error {}
private struct ExtractionBroke: Error {}

// Scripted extractor standing in for the production respondGenerating
// binding: returns queued values (last repeats indefinitely) and records
// every input it was invoked with.
private actor ScriptedExtractor<Value: Sendable> {
    private var script: [Value]
    private(set) var inputs: [String] = []

    init(_ script: [Value]) { self.script = script }

    func extract(_ input: String) throws -> Value {
        inputs.append(input)
        if script.count > 1 { return script.removeFirst() }
        guard let last = script.first else { throw ScriptExhausted() }
        return last
    }
}

// Order-of-operations log shared between a fake transport and a fake
// extractor, for pinning the two-phase split.
private actor PhaseLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

// Free-form transport that records tool-style activity against the run's
// meter and logs each respond() into the shared PhaseLog.
private actor ToolLoggingModel: ModelResponding {
    private let log: PhaseLog
    private let meter: ToolCallMeter
    private let response: String

    init(log: PhaseLog, meter: ToolCallMeter, response: String) {
        self.log = log
        self.meter = meter
        self.response = response
    }

    func respond(to prompt: String, options _: GenerationOptions) async throws -> String {
        try await meter.record()
        await log.append("respond(tools)")
        return response
    }

    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T {
        Issue.record("phase-one transport must never receive a structured-extraction call")
        throw ExtractionBroke()
    }
}

// MARK: - Session-level fakes

// Hand-conformed Generable (matching the codebase's no-macro style) for the
// CompoundSession.respond(to:generating:) surface.
struct ExtractedNote: Generable, Sendable {
    let headline: String

    static var generationSchema: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "ExtractedNote",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "headline",
                    schema: DynamicGenerationSchema(type: String.self)
                )
            ]
        )
        // Force-unwrap: constant schema we author; failure is programmer error.
        return try! GenerationSchema(root: root, dependencies: [])
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["headline": headline])
    }

    init(headline: String) {
        self.headline = headline
    }

    init(_ content: GeneratedContent) throws {
        self.headline = try content.value(String.self, forProperty: "headline")
    }
}

// Transport for the makeModel seam: respond() serves a canned reasoning
// string; respondGenerating decodes a canned GeneratedContent payload into
// the requested type, recording each structured prompt.
private actor TypedSessionFakeModel: ModelResponding, ModelStreaming {
    private let reasoning: String
    private let headline: String
    private(set) var respondCalls = 0
    private(set) var generatingPrompts: [String] = []

    init(reasoning: String, headline: String) {
        self.reasoning = reasoning
        self.headline = headline
    }

    func respond(to prompt: String, options _: GenerationOptions) async throws -> String {
        respondCalls += 1
        return reasoning
    }

    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T {
        generatingPrompts.append(prompt)
        return try T(GeneratedContent(properties: ["headline": headline]))
    }

    func stream(to prompt: String, options: GenerationOptions) async -> ModelStreamResult {
        let response = try? await respond(to: prompt, options: options)
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let final = Task<String, Error> {
            cont.yield(response ?? "")
            cont.finish()
            return response ?? ""
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

// MARK: - Tests

@Suite("TypedControlLoop")
struct TypedControlLoopTests {
    private func passChain() -> VerifierChain<String> {
        VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "pass", cost: .parse) { _, _ in .pass }
        ])
    }

    @Test("reasonThenExtract runs a free-form turn, then extracts from its output")
    func reasonThenExtractHappyPath() async throws {
        let model = FakeModel(["free-form reasoning"])
        let extractor = ScriptedExtractor([Ticket(title: "fix bug", priority: 2)])
        let loop = ControlLoop(budget: .default, outputVerifier: passChain())
        let outcome = try await loop.run(
            prompt: "p",
            modelClient: model,
            runContext: RunContext(),
            mode: .reasonThenExtract,
            extract: { try await extractor.extract($0) },
            verifiers: VerifierChain<Ticket>.empty()
        )
        #expect(outcome.value == Ticket(title: "fix bug", priority: 2))
        #expect(outcome.reasoning == "free-form reasoning")
        // Reasoning turn + extraction turn.
        #expect(outcome.usage.turns == 2)
        let inputs = await extractor.inputs
        #expect(inputs == ["free-form reasoning"])
        let calls = await model.calls
        #expect(calls == 1)
    }

    @Test("direct mode extracts straight from the prompt; no free-form turn runs")
    func directModeSkipsReasoning() async throws {
        let model = FakeModel(["never used"])
        let extractor = ScriptedExtractor([Ticket(title: "t", priority: 1)])
        // A string chain that would fail proves the string chain never runs
        // in direct mode.
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "never", cost: .parse) { _, _ in
                .reject(Diagnostic(verifier: "never", message: "must not run"))
            }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let outcome = try await loop.run(
            prompt: "extract the ticket",
            modelClient: model,
            runContext: RunContext(),
            mode: .direct,
            extract: { try await extractor.extract($0) },
            verifiers: VerifierChain<Ticket>.empty()
        )
        #expect(outcome.value.title == "t")
        #expect(outcome.reasoning == nil)
        #expect(outcome.usage.turns == 1)
        let calls = await model.calls
        #expect(calls == 0)
        let inputs = await extractor.inputs
        #expect(inputs == ["extract the ticket"])
    }

    @Test("typed-verifier .repair feeds the standard repair path and re-extracts")
    func typedRepairRound() async throws {
        let model = FakeModel(["the reasoning document"])
        let extractor = ScriptedExtractor([
            Ticket(title: "bad", priority: 0),
            Ticket(title: "good", priority: 2),
        ])
        let typed = VerifierChain<Ticket>(name: "typed", [
            AnyVerifier<Ticket>(name: "priority", cost: .parse) { ticket, _ in
                ticket.priority >= 1
                    ? .pass
                    : .repair(Diagnostic(verifier: "priority", message: "priority must be >= 1"))
            }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: passChain())
        let outcome = try await loop.run(
            prompt: "p",
            modelClient: model,
            runContext: RunContext(),
            extract: { try await extractor.extract($0) },
            verifiers: typed
        )
        #expect(outcome.value == Ticket(title: "good", priority: 2))
        #expect(outcome.usage.repairAttempts == 1)
        let inputs = await extractor.inputs
        #expect(inputs.count == 2)
        #expect(inputs.first == "the reasoning document")
        // The repair prompt is self-contained: extraction source, the
        // stringified failed value, and the diagnostic.
        let repairPrompt = try #require(inputs.last)
        #expect(repairPrompt.contains("the reasoning document"))
        #expect(repairPrompt.contains("priority must be >= 1"))
        #expect(repairPrompt.contains("priority: 0"))
    }

    @Test("typed-verifier .reject throws verifierRejected with the typed diagnostic")
    func typedReject() async throws {
        let model = FakeModel(["reasoning"])
        let extractor = ScriptedExtractor([Ticket(title: "t", priority: 9)])
        let typed = VerifierChain<Ticket>(name: "typed", [
            AnyVerifier<Ticket>(name: "gate", cost: .parse) { _, _ in
                .reject(Diagnostic(verifier: "gate", message: "not allowed"))
            }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: passChain())
        do {
            _ = try await loop.run(
                prompt: "p",
                modelClient: model,
                runContext: RunContext(),
                extract: { try await extractor.extract($0) },
                verifiers: typed
            )
            Issue.record("expected verifierRejected")
        } catch CompoundError.verifierRejected(let reason, let diag) {
            #expect(reason == "not allowed")
            #expect(diag?.verifier == "gate")
        }
    }

    @Test("extractor failure surfaces through the standard error taxonomy")
    func extractionFailure() async throws {
        let model = FakeModel(["reasoning"])
        let loop = ControlLoop(budget: .default, outputVerifier: passChain())
        do {
            _ = try await loop.run(
                prompt: "p",
                modelClient: model,
                runContext: RunContext(),
                extract: { (_: String) -> Ticket in throw ExtractionBroke() },
                verifiers: VerifierChain<Ticket>.empty()
            )
            Issue.record("expected underlying(ExtractionBroke)")
        } catch CompoundError.underlying(let error) {
            #expect(error is ExtractionBroke)
        }
    }

    @Test("no tool-enabled turn performs extraction: tools in phase one, extract in phase two")
    func phasesAreStructurallySeparate() async throws {
        let log = PhaseLog()
        let meter = ToolCallMeter(limit: 10)
        let ctx = RunContext(toolCallMeter: meter)
        let model = ToolLoggingModel(log: log, meter: meter, response: "tool-informed reasoning")
        let loop = ControlLoop(budget: .default, outputVerifier: passChain())
        let outcome = try await loop.run(
            prompt: "p",
            modelClient: model,
            runContext: ctx,
            extract: { input in
                await log.append("extract")
                return Ticket(title: input, priority: 1)
            },
            verifiers: VerifierChain<Ticket>.empty()
        )
        // Every tool-enabled respond() strictly precedes the single
        // extraction call, and the extraction input is the free-form
        // output — never the raw user prompt of a tool-enabled turn.
        let events = await log.events
        #expect(events == ["respond(tools)", "extract"])
        #expect(outcome.value.title == "tool-informed reasoning")
        #expect(outcome.usage.toolCalls == 1)
    }

    @Test("string-chain repair still gates phase one before extraction runs")
    func stringRepairPrecedesExtraction() async throws {
        let model = FakeModel(["bad", "good"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "needs-good", cost: .parse) { input, _ in
                input == "good"
                    ? .pass
                    : .repair(Diagnostic(verifier: "needs-good", message: "want good"))
            }
        ])
        let extractor = ScriptedExtractor([Ticket(title: "t", priority: 1)])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let outcome = try await loop.run(
            prompt: "p",
            modelClient: model,
            runContext: RunContext(),
            extract: { try await extractor.extract($0) },
            verifiers: VerifierChain<Ticket>.empty()
        )
        #expect(outcome.reasoning == "good")
        #expect(outcome.usage.repairAttempts == 1)
        // Two reasoning turns + one extraction turn.
        #expect(outcome.usage.turns == 3)
        let inputs = await extractor.inputs
        #expect(inputs == ["good"])
    }

    @Test("typed run traces exactly one run.ended, after extraction")
    func singleRunEndedTrace() async throws {
        let tracer = InMemoryTracer()
        let model = FakeModel(["reasoning"])
        let extractor = ScriptedExtractor([Ticket(title: "t", priority: 1)])
        let loop = ControlLoop(budget: .default, outputVerifier: passChain())
        let ctx = RunContext(tracer: tracer)
        _ = try await loop.run(
            prompt: "p",
            modelClient: model,
            runContext: ctx,
            extract: { try await extractor.extract($0) },
            verifiers: VerifierChain<Ticket>.empty()
        )
        let labels = await tracer.snapshot().map(\.label)
        #expect(labels.first == "run.started")
        #expect(labels.filter { $0 == "run.ended" }.count == 1)
        #expect(labels.last == "run.ended")
    }

    @Test("extraction turn debits the turn budget: maxTurns 1 refuses phase two")
    func extractionCountsAgainstTurns() async throws {
        let model = FakeModel(["reasoning"])
        let extractor = ScriptedExtractor([Ticket(title: "t", priority: 1)])
        let budget = Budget(maxTurns: 1, maxToolCalls: 4, maxRepairAttempts: 1, wallClock: .seconds(60))
        let loop = ControlLoop(budget: budget, outputVerifier: passChain())
        do {
            _ = try await loop.run(
                prompt: "p",
                modelClient: model,
                runContext: RunContext(),
                extract: { try await extractor.extract($0) },
                verifiers: VerifierChain<Ticket>.empty()
            )
            Issue.record("expected budgetExhausted(.turns)")
        } catch CompoundError.budgetExhausted(let kind, let usage) {
            #expect(kind == .turns)
            #expect(usage.turns == 1)
        }
        let inputs = await extractor.inputs
        #expect(inputs.isEmpty)
    }

    @Test("typed repairs debit maxRepairAttempts: cap 1 permits exactly one re-extraction")
    func typedRepairBudgetExhaustion() async throws {
        let model = FakeModel(["reasoning"])
        let extractor = ScriptedExtractor([Ticket(title: "t", priority: 0)])
        let typed = VerifierChain<Ticket>(name: "typed", [
            AnyVerifier<Ticket>(name: "always-repair", cost: .parse) { _, _ in
                .repair(Diagnostic(verifier: "always-repair", message: "again"))
            }
        ])
        let budget = Budget(maxTurns: 10, maxToolCalls: 0, maxRepairAttempts: 1, wallClock: .seconds(60))
        let loop = ControlLoop(budget: budget, outputVerifier: passChain())
        do {
            _ = try await loop.run(
                prompt: "p",
                modelClient: model,
                runContext: RunContext(),
                extract: { try await extractor.extract($0) },
                verifiers: typed
            )
            Issue.record("expected budgetExhausted(.repairAttempts)")
        } catch CompoundError.budgetExhausted(let kind, let usage) {
            #expect(kind == .repairAttempts)
            #expect(usage.repairAttempts == 1)
        }
        // Initial extraction plus exactly one repair extraction.
        let inputs = await extractor.inputs
        #expect(inputs.count == 2)
    }
}

@Suite("CompoundSession typed respond")
struct CompoundSessionTypedTests {
    @Test("respond(to:generating:) reasons free-form, then extracts via respondGenerating")
    func sessionReasonThenExtract() async throws {
        let model = TypedSessionFakeModel(reasoning: "session reasoning", headline: "shipping delayed")
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            makeModel: { _, _, _ in model }
        ))
        let outcome = try await session.respond(
            to: "summarize the status update",
            generating: ExtractedNote.self
        )
        #expect(outcome.value.headline == "shipping delayed")
        #expect(outcome.reasoning == "session reasoning")
        let respondCalls = await model.respondCalls
        #expect(respondCalls == 1)
        // Extraction is prompted with the free-form output, not the user prompt.
        let generatingPrompts = await model.generatingPrompts
        #expect(generatingPrompts == ["session reasoning"])
    }

    @Test("respond(to:generating:mode: .direct) never runs a free-form turn")
    func sessionDirectMode() async throws {
        let model = TypedSessionFakeModel(reasoning: "unused", headline: "hi")
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            makeModel: { _, _, _ in model }
        ))
        let outcome = try await session.respond(
            to: "extract the note",
            generating: ExtractedNote.self,
            mode: .direct
        )
        #expect(outcome.value.headline == "hi")
        #expect(outcome.reasoning == nil)
        let respondCalls = await model.respondCalls
        #expect(respondCalls == 0)
        let generatingPrompts = await model.generatingPrompts
        #expect(generatingPrompts.count == 1)
        #expect(generatingPrompts.first?.contains("extract the note") == true)
    }

    @Test("typed-verifier repair at the session level re-extracts with the diagnostic")
    func sessionTypedRepair() async throws {
        let model = TypedSessionFakeModel(reasoning: "session reasoning", headline: "fixed")
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            makeModel: { _, _, _ in model }
        ))
        let seen = SeenCounter()
        let typed = VerifierChain<ExtractedNote>(name: "typed", [
            AnyVerifier<ExtractedNote>(name: "once", cost: .parse) { _, _ in
                await seen.bump() == 1
                    ? .repair(Diagnostic(verifier: "once", message: "needs work"))
                    : .pass
            }
        ])
        let outcome = try await session.respond(
            to: "summarize",
            generating: ExtractedNote.self,
            verifiers: typed
        )
        #expect(outcome.value.headline == "fixed")
        #expect(outcome.usage.repairAttempts == 1)
        let generatingPrompts = await model.generatingPrompts
        #expect(generatingPrompts.count == 2)
        #expect(generatingPrompts.last?.contains("needs work") == true)
    }
}

private actor SeenCounter {
    private var count = 0
    func bump() -> Int {
        count += 1
        return count
    }
}
