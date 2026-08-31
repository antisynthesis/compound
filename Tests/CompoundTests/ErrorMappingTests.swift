import Foundation
import FoundationModels
import Testing
@testable import Compound

// FailingModel throws a queue of errors; once the queue is exhausted it
// returns `finalResponse`. Lets tests drive the retry/mapping paths with
// hand-built session errors, no device model required.
actor FailingModel: ModelResponding {
    private var errors: [any Error]
    private let finalResponse: String
    private(set) var calls = 0

    init(errors: [any Error], then finalResponse: String = "ok") {
        self.errors = errors
        self.finalResponse = finalResponse
    }

    func respond(to _: String, options _: GenerationOptions) async throws -> String {
        calls += 1
        if !errors.isEmpty {
            throw errors.removeFirst()
        }
        return finalResponse
    }

    func respondGenerating<T: Generable & Sendable>(
        _: T.Type,
        to _: String,
        options _: GenerationOptions
    ) async throws -> T {
        fatalError("unused in tests")
    }
}

// Streaming fake whose final task throws the supplied error after yielding
// the given chunks.
struct FailingStreamingModel: ModelStreaming {
    let chunks: [String]
    let error: any Error

    func stream(to _: String, options _: GenerationOptions) async -> ModelStreamResult {
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let chunks = self.chunks
        let error = self.error
        let final = Task<String, Error> {
            for chunk in chunks {
                cont.yield(chunk)
            }
            cont.finish(throwing: error)
            throw error
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

private func passChain() -> VerifierChain<String> {
    VerifierChain<String>(name: "out", [
        AnyVerifier<String>(name: "pass", cost: .parse) { _, _ in .pass }
    ])
}

@Suite("ErrorMapping")
struct ErrorMappingTests {
    // MARK: - mapSessionError basics

    @Test("CancellationError maps to .cancelled")
    func cancellationMapsToCancelled() {
        let mapped = CompoundError.mapSessionError(CancellationError())
        guard case .cancelled = mapped else {
            Issue.record("expected .cancelled, got \(mapped)")
            return
        }
        #expect(mapped.severity == .recoverable)
        #expect(mapped.layer == .control)
    }

    @Test("an existing CompoundError passes through unchanged")
    func compoundErrorPassesThrough() {
        let original = CompoundError.policyDenied(reason: "nope")
        let mapped = CompoundError.mapSessionError(original)
        guard case .policyDenied(let reason) = mapped else {
            Issue.record("expected passthrough, got \(mapped)")
            return
        }
        #expect(reason == "nope")
    }

    @Test("unrecognized errors wrap in .underlying")
    func unknownErrorWrapsUnderlying() {
        struct Mystery: Error {}
        let mapped = CompoundError.mapSessionError(Mystery())
        guard case .underlying(let inner) = mapped else {
            Issue.record("expected .underlying, got \(mapped)")
            return
        }
        #expect(inner is Mystery)
        #expect(mapped.severity == .terminal)
        #expect(mapped.layer == .unknown)
    }

    @Test("the classifier seam overrides the default mapping")
    func classifierSeam() {
        struct Custom: Error {}
        struct CustomClassifier: SessionErrorClassifying {
            func classify(_ error: any Error) -> CompoundError? {
                error is Custom ? .modelRateLimited : nil
            }
        }
        let mapped = CompoundError.mapSessionError(Custom(), classifier: CustomClassifier())
        guard case .modelRateLimited = mapped else {
            Issue.record("expected .modelRateLimited, got \(mapped)")
            return
        }
    }

    // MARK: - GenerationError mapping

    @Test("guardrailViolation maps with context, terminal, layer .model")
    func guardrailMapping() {
        let error = LanguageModelSession.GenerationError.guardrailViolation(
            .init(debugDescription: "blocked content")
        )
        let mapped = CompoundError.mapSessionError(error)
        guard case .guardrailViolation(let context) = mapped else {
            Issue.record("expected .guardrailViolation, got \(mapped)")
            return
        }
        #expect(context == "blocked content")
        #expect(mapped.severity == .terminal)
        #expect(mapped.layer == .model)
    }

    @Test("exceededContextWindowSize maps to .contextWindowExceeded, recoverable")
    func contextWindowMapping() {
        let error = LanguageModelSession.GenerationError.exceededContextWindowSize(
            .init(debugDescription: "too big")
        )
        let mapped = CompoundError.mapSessionError(error)
        guard case .contextWindowExceeded(let promptTokens) = mapped else {
            Issue.record("expected .contextWindowExceeded, got \(mapped)")
            return
        }
        #expect(promptTokens == nil)
        #expect(mapped.severity == .recoverable)
        #expect(mapped.layer == .model)
    }

    @Test("refusal maps to .refusal, terminal")
    func refusalMapping() {
        let error = LanguageModelSession.GenerationError.refusal(
            .init(transcriptEntries: []),
            .init(debugDescription: "declined")
        )
        let mapped = CompoundError.mapSessionError(error)
        guard case .refusal(let detail) = mapped else {
            Issue.record("expected .refusal, got \(mapped)")
            return
        }
        #expect(detail == "declined")
        #expect(mapped.severity == .terminal)
        #expect(mapped.layer == .model)
    }

    @Test("unsupportedLanguageOrLocale maps to .unsupportedLanguage, terminal")
    func unsupportedLanguageMapping() {
        let error = LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(
            .init(debugDescription: "klingon")
        )
        let mapped = CompoundError.mapSessionError(error)
        guard case .unsupportedLanguage = mapped else {
            Issue.record("expected .unsupportedLanguage, got \(mapped)")
            return
        }
        #expect(mapped.severity == .terminal)
        #expect(mapped.layer == .model)
    }

    @Test("rateLimited and concurrentRequests map to .modelRateLimited, recoverable")
    func rateLimitedMapping() {
        for error: LanguageModelSession.GenerationError in [
            .rateLimited(.init(debugDescription: "slow down")),
            .concurrentRequests(.init(debugDescription: "busy")),
        ] {
            let mapped = CompoundError.mapSessionError(error)
            guard case .modelRateLimited = mapped else {
                Issue.record("expected .modelRateLimited for \(error), got \(mapped)")
                continue
            }
            #expect(mapped.severity == .recoverable)
            #expect(mapped.layer == .model)
        }
    }

    @Test("assetsUnavailable maps to .modelUnavailable with an assets reason")
    func assetsUnavailableMapping() {
        let error = LanguageModelSession.GenerationError.assetsUnavailable(
            .init(debugDescription: "still fetching")
        )
        let mapped = CompoundError.mapSessionError(error)
        guard case .modelUnavailable(let reason) = mapped else {
            Issue.record("expected .modelUnavailable, got \(mapped)")
            return
        }
        #expect(reason.contains("assets unavailable"))
        #expect(reason.contains("still fetching"))
    }

    @Test("decodingFailure and unsupportedGuide stay .underlying")
    func unmappedGenerationErrorsStayUnderlying() {
        for error: LanguageModelSession.GenerationError in [
            .decodingFailure(.init(debugDescription: "bad json")),
            .unsupportedGuide(.init(debugDescription: "bad guide")),
        ] {
            let mapped = CompoundError.mapSessionError(error)
            guard case .underlying(let inner) = mapped else {
                Issue.record("expected .underlying for \(error), got \(mapped)")
                continue
            }
            #expect(inner is LanguageModelSession.GenerationError)
        }
    }

    @Test("LanguageModelError (OS 27+) maps through the same taxonomy")
    func languageModelErrorMapping() {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let guardrail = CompoundError.mapSessionError(
            LanguageModelError.guardrailViolation(.init(debugDescription: "unsafe"))
        )
        guard case .guardrailViolation(let context) = guardrail else {
            Issue.record("expected .guardrailViolation, got \(guardrail)")
            return
        }
        #expect(context == "unsafe")

        let ctx = CompoundError.mapSessionError(
            LanguageModelError.contextSizeExceeded(
                .init(contextSize: 4096, tokenCount: 5000, debugDescription: "over")
            )
        )
        guard case .contextWindowExceeded(let promptTokens) = ctx else {
            Issue.record("expected .contextWindowExceeded, got \(ctx)")
            return
        }
        #expect(promptTokens == 5000)

        let rate = CompoundError.mapSessionError(
            LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "throttled"))
        )
        guard case .modelRateLimited = rate else {
            Issue.record("expected .modelRateLimited, got \(rate)")
            return
        }
    }

    // MARK: - ControlLoop wiring

    @Test("guardrail violation throws immediately: no retry, no repair, trace counter recorded")
    func loopGuardrailThrowsImmediately() async throws {
        let model = FailingModel(errors: [
            LanguageModelSession.GenerationError.guardrailViolation(.init(debugDescription: "blocked"))
        ])
        let tracer = InMemoryTracer()
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: passChain(),
            retryPolicy: RetryPolicy(maxAttempts: 5, initialDelay: .milliseconds(1))
        )
        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext(tracer: tracer))
            Issue.record("expected throw")
        } catch let error as CompoundError {
            guard case .guardrailViolation(let context) = error else {
                Issue.record("expected .guardrailViolation, got \(error)")
                return
            }
            #expect(context == "blocked")
        }
        // Exactly one model call: terminal errors never consume retries.
        let calls = await model.calls
        #expect(calls == 1)
        let events = await tracer.snapshot()
        let sawCounter = events.contains { event in
            if case .info(_, let category, let message) = event {
                return category == "guardrailViolation" && message.contains("#1")
            }
            return false
        }
        #expect(sawCounter)
        let sawFailedEnd = events.contains { event in
            if case .runEnded(_, let success, let usage) = event {
                return success == false && usage.repairAttempts == 0
            }
            return false
        }
        #expect(sawFailedEnd)
    }

    @Test("contextWindowExceeded surfaces typed from the loop")
    func loopContextWindowSurfacesTyped() async throws {
        let model = FailingModel(errors: [
            LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "full"))
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: passChain())
        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
            Issue.record("expected throw")
        } catch let error as CompoundError {
            guard case .contextWindowExceeded = error else {
                Issue.record("expected .contextWindowExceeded, got \(error)")
                return
            }
        }
        let calls = await model.calls
        #expect(calls == 1)
    }

    @Test("transient rate limiting is retried and the run succeeds")
    func loopRetriesTransientRateLimit() async throws {
        let model = FailingModel(
            errors: [CompoundError.modelRateLimited, CompoundError.modelRateLimited],
            then: "recovered"
        )
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: passChain(),
            retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1))
        )
        let outcome = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        #expect(outcome.output == "recovered")
        let calls = await model.calls
        #expect(calls == 3)
        // Exactly one turn was consumed: retries happen inside the turn.
        #expect(outcome.usage.turns == 1)
    }

    @Test("retries exhaust and the transient error surfaces typed")
    func loopRetriesExhaust() async throws {
        let model = FailingModel(errors: [
            CompoundError.modelRateLimited,
            CompoundError.modelRateLimited,
            CompoundError.modelRateLimited,
        ])
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: passChain(),
            retryPolicy: RetryPolicy(maxAttempts: 2, initialDelay: .milliseconds(1))
        )
        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
            Issue.record("expected throw")
        } catch let error as CompoundError {
            guard case .modelRateLimited = error else {
                Issue.record("expected .modelRateLimited, got \(error)")
                return
            }
        }
        let calls = await model.calls
        #expect(calls == 2)
    }

    @Test("streaming loop maps a session error thrown by the final task")
    func streamingLoopMapsFinalError() async throws {
        let model = FailingStreamingModel(
            chunks: ["a"],
            error: LanguageModelSession.GenerationError.guardrailViolation(.init(debugDescription: "unsafe"))
        )
        let tracer = InMemoryTracer()
        let loop = StreamingControlLoop(budget: .default, outputVerifier: passChain())
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext(tracer: tracer))
        do {
            _ = try await run.outcome.value
            Issue.record("expected throw")
        } catch let error as CompoundError {
            guard case .guardrailViolation(let context) = error else {
                Issue.record("expected .guardrailViolation, got \(error)")
                return
            }
            #expect(context == "unsafe")
        }
        let events = await tracer.snapshot()
        let sawCounter = events.contains { event in
            if case .info(_, let category, _) = event { return category == "guardrailViolation" }
            return false
        }
        #expect(sawCounter)
    }
}
