import Foundation
import FoundationModels

// The stochastic core. ModelClient is the only place in the framework that
// talks to Apple's on-device LanguageModelSession. Its responsibilities are
// deliberately narrow: check availability, format the request, run the call,
// time it, trace it. The compound system's reliability does not come from
// here — it comes from the verifier and tool layers wrapping this call.

// MARK: - Session error mapping

/// Classifies errors thrown by the underlying model session into
/// ``CompoundError`` cases. The seam exists so the pure mapping in
/// ``CompoundError/mapSessionError(_:classifier:)`` is unit-testable with
/// hand-built errors, off-device, while the live conformer pattern-matches
/// the real FoundationModels error types.
public protocol SessionErrorClassifying: Sendable {
    /// Returns the mapped ``CompoundError``, or `nil` when this classifier
    /// does not recognize `error` (the caller falls back to
    /// ``CompoundError/underlying(_:)``).
    func classify(_ error: any Error) -> CompoundError?
}

/// Live classifier for Apple's FoundationModels session errors. Maps
/// `LanguageModelSession.GenerationError` (and, on OS 27+, its successor
/// `LanguageModelError`) into the ``CompoundError`` taxonomy.
public struct FoundationModelsSessionClassifier: SessionErrorClassifying {
    /// Creates an instance.
    public init() {}

    /// Pattern-matches the FoundationModels error types. Unrecognized
    /// cases (e.g. decoding failures, unsupported generation guides)
    /// return `nil` so they surface as ``CompoundError/underlying(_:)``.
    public func classify(_ error: any Error) -> CompoundError? {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            if let lmError = error as? LanguageModelError {
                switch lmError {
                case .contextSizeExceeded(let info):
                    return .contextWindowExceeded(promptTokens: info.tokenCount)
                case .rateLimited:
                    return .modelRateLimited
                case .guardrailViolation(let info):
                    return .guardrailViolation(context: info.debugDescription)
                case .refusal(let info):
                    return .refusal(info.debugDescription)
                case .unsupportedLanguageOrLocale:
                    return .unsupportedLanguage
                case .unsupportedCapability, .unsupportedTranscriptContent,
                     .unsupportedGenerationGuide, .timeout:
                    return nil
                @unknown default:
                    return nil
                }
            }
        }
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                return .contextWindowExceeded(promptTokens: nil)
            case .assetsUnavailable(let context):
                return .modelUnavailable(reason: "model assets unavailable — \(context.debugDescription)")
            case .guardrailViolation(let context):
                return .guardrailViolation(context: context.debugDescription)
            case .unsupportedLanguageOrLocale:
                return .unsupportedLanguage
            case .rateLimited, .concurrentRequests:
                return .modelRateLimited
            case .refusal(_, let context):
                return .refusal(context.debugDescription)
            case .unsupportedGuide, .decodingFailure:
                return nil
            @unknown default:
                return nil
            }
        }
        return nil
    }
}

extension CompoundError {
    /// Pure, centralized mapping applied at the ``ModelClient`` boundary by
    /// `respond`, `respondGenerating`, and `stream`:
    /// `CancellationError` becomes ``CompoundError/cancelled``, an existing
    /// ``CompoundError`` passes through unchanged, recognized session errors
    /// map to their typed cases via `classifier`, and everything else is
    /// wrapped in ``CompoundError/underlying(_:)``.
    public static func mapSessionError(
        _ error: any Error,
        classifier: any SessionErrorClassifying = FoundationModelsSessionClassifier()
    ) -> CompoundError {
        if error is CancellationError { return .cancelled }
        if let compound = error as? CompoundError { return compound }
        if let mapped = classifier.classify(error) { return mapped }
        return .underlying(error)
    }
}

// MARK: - Token counting (system model)

/// ``TokenCounting`` conformer backed by the on-device system model.
///
/// `contextSize` reports the model's real window (back-deployed by the SDK;
/// 4096 on OS releases that predate the measured value). `count(_:)` asks
/// the model's own tokenizer on 26.4+ and falls back to
/// ``Budget/approximateTokens(_:)`` earlier or when the tokenizer throws
/// (e.g. model assets unavailable).
public struct SystemModelTokenCounter: TokenCounting {
    private let model: SystemLanguageModel

    /// Creates a counter over `model` (default: the system model).
    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    /// The model's context window, in tokens.
    public var contextSize: Int { model.contextSize }

    /// Measured token count on 26.4+, heuristic fallback otherwise.
    public func count(_ text: String) async -> Int {
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
            if let measured = try? await model.tokenCount(for: text), measured > 0 {
                return measured
            }
        }
        return Budget.approximateTokens(text)
    }
}

/// Non-streaming model surface. Extracted so tests and alternative backends
/// can inject a fake in place of the concrete ``ModelClient`` actor.
///
/// ## Statefulness contract
///
/// The protocol makes **no promise** that a conformer retains conversation
/// state between calls. ``ModelClient`` is stateful — its underlying
/// `LanguageModelSession` accumulates a transcript, so a later prompt can
/// refer back to earlier turns — but a conformer backed by a one-shot HTTP
/// endpoint or a test fake is typically stateless: every
/// ``respond(to:options:)`` call must carry the full task in `prompt`.
///
/// The control loops therefore default to
/// ``RepairPromptBuilder/default``, which rebuilds a self-contained repair
/// prompt (original task + failed output + diagnostics) and is correct for
/// both kinds of conformer. Only configure
/// ``RepairPromptBuilder/diagnosticOnly`` when the transport is known to be
/// stateful — sending a bare diagnostic to a stateless conformer strips
/// the task away entirely and the repair turn cannot succeed.
public protocol ModelResponding: Sendable {
    /// Sends `prompt` and returns the full response as a string.
    func respond(to prompt: String, options: GenerationOptions) async throws -> String
    /// Sends `prompt` and decodes a `Generable` value of type `T`.
    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T
}

extension ModelResponding {
    /// Binds the typed control loop's extraction phase to
    /// ``respondGenerating(_:to:options:)`` — the production adapter that
    /// keeps the loop layer `Generable`-free. The returned closure sends
    /// its input (the free-form reasoning output, the raw prompt in
    /// ``TypedRunMode/direct``, or a repair prompt) as a fresh prompt and
    /// decodes a `T` via guided generation.
    ///
    /// The extraction prompt is a self-contained document, so the
    /// extraction turn needs no tools — keeping structured generation and
    /// tool calling in separate turns, per Apple's guidance that combining
    /// them in one respond breaks multi-step tool invocation.
    public func extractor<T: Generable & Sendable>(
        _ type: T.Type,
        options: GenerationOptions = GenerationOptions()
    ) -> @Sendable (String) async throws -> T {
        { text in try await self.respondGenerating(type, to: text, options: options) }
    }
}

/// Result of a streaming model call.
///
/// ``stream`` yields delta chunks (the suffix added since the previous
/// yield, not the rolling whole) and ``final`` resolves to the full
/// accumulated output once generation finishes. Cancelling the stream
/// cancels ``final`` and vice versa.
public struct ModelStreamResult: Sendable {
    /// Delta-chunk stream.
    public let stream: AsyncThrowingStream<String, Error>
    /// Resolves to the full accumulated output when generation finishes.
    public let final: Task<String, Error>

    /// Creates a streaming result.
    public init(stream: AsyncThrowingStream<String, Error>, final: Task<String, Error>) {
        self.stream = stream
        self.final = final
    }
}

/// Streaming model surface. Lets the control loop hold a protocol
/// existential rather than the concrete ``ModelClient`` actor.
public protocol ModelStreaming: Sendable {
    /// Begins streaming a response to `prompt`. The returned
    /// ``ModelStreamResult`` exposes both per-chunk and final-output APIs.
    func stream(to prompt: String, options: GenerationOptions) async -> ModelStreamResult
}

/// Actor-backed adapter over Apple's on-device `LanguageModelSession`.
///
/// `ModelClient` is the only place in the framework that talks to the
/// stochastic core. Its responsibilities are deliberately narrow: check
/// availability, format the request, run the call, time it, trace it.
/// System-level reliability is supplied by the verifier and tool layers
/// wrapping this call rather than by the model itself.
///
/// # Example
/// ```swift
/// let client = try ModelClient(
///     instructions: "You are a helpful assistant.",
///     tools: [calculator],
///     runContext: ctx
/// )
/// let answer = try await client.respond(to: "2 + 2?")
/// ```
public actor ModelClient: ModelResponding, ModelStreaming {
    /// Shared context for tracing and progress reporting.
    public let runContext: RunContext
    internal var session: LanguageModelSession
    internal let model: SystemLanguageModel
    /// Counter used for occupancy estimates when the OS does not report
    /// measured usage.
    public let tokenCounter: any TokenCounting
    /// Per-session context-occupancy ledger. Crossing its high watermark
    /// triggers proactive compaction (see ``compactSession(lastPrompt:lastResponse:)``).
    public let tokenLedger: SessionTokenLedger
    private let instructions: String
    private let tools: [any Tool]
    private var turnCounter: Int = 0

    /// Creates a client over the supplied on-device model.
    ///
    /// - Parameters:
    ///   - instructions: System instructions for the underlying session.
    ///   - tools: Tools exposed to the model.
    ///   - runContext: Shared context (run ID, tracer, progress).
    ///   - model: The on-device model. Defaults to ``SystemLanguageModel/default``.
    ///   - tokenCounter: Counter for occupancy estimates. `nil` (the
    ///     default) selects ``SystemModelTokenCounter`` over `model`.
    ///   - contextHighWatermark: Fraction of the model's context window at
    ///     which the session is proactively compacted. Defaults to 0.8.
    /// - Throws: ``CompoundError/modelUnavailable(reason:)`` if the model
    ///   reports an unavailable state.
    public init(
        instructions: String,
        tools: [any Tool] = [],
        runContext: RunContext,
        model: SystemLanguageModel = .default,
        tokenCounter: (any TokenCounting)? = nil,
        contextHighWatermark: Double = 0.8
    ) throws {
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw CompoundError.modelUnavailable(reason: Self.label(reason))
        }
        self.runContext = runContext
        self.model = model
        self.instructions = instructions
        self.tools = tools
        let counter = tokenCounter ?? SystemModelTokenCounter(model: model)
        self.tokenCounter = counter
        self.tokenLedger = SessionTokenLedger(
            contextSize: counter.contextSize,
            highWatermarkFraction: contextHighWatermark
        )
        self.session = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: instructions
        )
    }

    /// Sends `prompt` and returns the model's response as a string,
    /// emitting paired ``TraceEvent/modelInvocationStarted(runID:turn:promptBytes:)``
    /// and ``TraceEvent/modelInvocationCompleted(runID:turn:outputBytes:elapsed:)``
    /// events.
    ///
    /// - Throws: A ``CompoundError`` mapped through
    ///   ``CompoundError/mapSessionError(_:classifier:)`` — typed cases for
    ///   recognized session failures (guardrail violation, context-window
    ///   exhaustion, refusal, rate limiting, unsupported language),
    ///   ``CompoundError/cancelled`` for cancellation, and
    ///   ``CompoundError/underlying(_:)`` for everything else.
    public func respond(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> String {
        try ensureAvailable()
        turnCounter += 1
        let turn = turnCounter
        let promptBytes = prompt.utf8.count
        await runContext.tracer.record(
            .modelInvocationStarted(runID: runContext.runID, turn: turn, promptBytes: promptBytes)
        )

        let started = ContinuousClock.now
        do {
            let response = try await session.respond(to: prompt, options: options)
            let elapsed = ContinuousClock.now - started
            await runContext.tracer.record(
                .modelInvocationCompleted(
                    runID: runContext.runID,
                    turn: turn,
                    outputBytes: response.content.utf8.count,
                    elapsed: elapsed
                )
            )
            var measured: Int?
            if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                let usage = response.usage
                measured = usage.input.totalTokenCount + usage.output.totalTokenCount
            }
            await settleTurnAccounting(prompt: prompt, output: response.content, measuredTokens: measured)
            return response.content
        } catch {
            await runContext.tracer.record(
                .modelInvocationFailed(
                    runID: runContext.runID,
                    turn: turn,
                    reason: String(describing: error)
                )
            )
            throw CompoundError.mapSessionError(error)
        }
    }

    /// Sends `prompt` and decodes a structured `Generable` value of
    /// type `T`. Same trace and error contract as ``respond(to:options:)``.
    public func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> T {
        try ensureAvailable()
        turnCounter += 1
        let turn = turnCounter
        let promptBytes = prompt.utf8.count
        await runContext.tracer.record(
            .modelInvocationStarted(runID: runContext.runID, turn: turn, promptBytes: promptBytes)
        )

        let started = ContinuousClock.now
        do {
            let response = try await session.respond(to: prompt, generating: type, options: options)
            let elapsed = ContinuousClock.now - started
            let outputText = response.rawContent.debugDescription
            await runContext.tracer.record(
                .modelInvocationCompleted(
                    runID: runContext.runID,
                    turn: turn,
                    outputBytes: outputText.utf8.count,
                    elapsed: elapsed
                )
            )
            var measured: Int?
            if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                let usage = response.usage
                measured = usage.input.totalTokenCount + usage.output.totalTokenCount
            }
            await settleTurnAccounting(prompt: prompt, output: outputText, measuredTokens: measured)
            return response.content
        } catch {
            await runContext.tracer.record(
                .modelInvocationFailed(
                    runID: runContext.runID,
                    turn: turn,
                    reason: String(describing: error)
                )
            )
            throw CompoundError.mapSessionError(error)
        }
    }

    /// Snapshot of the underlying session's conversation transcript.
    public func currentTranscript() -> Transcript {
        session.transcript
    }

    /// Number of model invocations issued by this client so far.
    public var turnCount: Int { turnCounter }

    internal func bumpTurn() -> Int {
        turnCounter += 1
        return turnCounter
    }

    /// Updates the session token ledger after a completed turn — from
    /// measured usage where the OS provides it, otherwise from
    /// ``tokenCounter`` estimates — and compacts the session when the
    /// update crosses the ledger's high watermark.
    private func settleTurnAccounting(prompt: String, output: String, measuredTokens: Int?) async {
        let crossed: Bool
        if let measuredTokens {
            crossed = await tokenLedger.reconcile(measuredTokens: measuredTokens)
        } else {
            let promptTokens = await tokenCounter.count(prompt)
            let outputTokens = await tokenCounter.count(output)
            crossed = await tokenLedger.record(promptTokens: promptTokens, outputTokens: outputTokens)
        }
        guard crossed else { return }
        let occupancy = await tokenLedger.estimatedTokens
        await runContext.tracer.record(
            .info(
                runID: runContext.runID,
                category: "tokenLedger",
                message: "context occupancy \(occupancy)/\(tokenLedger.contextSize) crossed high watermark \(tokenLedger.highWatermark); compacting session"
            )
        )
        await compactSession(lastPrompt: prompt, lastResponse: output)
    }

    /// Proactive compaction: replaces the accumulated session with a fresh
    /// one seeded with the original instructions plus the most recent
    /// exchange, then resets the ledger to the seeded transcript's
    /// estimated size. Runs *before* the context window blows, so the
    /// typed ``CompoundError/contextWindowExceeded(promptTokens:)`` error
    /// remains the reactive backstop rather than the steady state.
    private func compactSession(lastPrompt: String, lastResponse: String) async {
        var entries: [Transcript.Entry] = []
        if !instructions.isEmpty {
            entries.append(
                .instructions(
                    Transcript.Instructions(
                        segments: [.text(Transcript.TextSegment(content: instructions))],
                        toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
                    )
                )
            )
        }
        entries.append(
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: lastPrompt))]))
        )
        entries.append(
            .response(
                Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: lastResponse))]
                )
            )
        )
        session = LanguageModelSession(
            model: model,
            tools: tools,
            transcript: Transcript(entries: entries)
        )
        var seeded = await tokenCounter.count(lastPrompt)
        seeded += await tokenCounter.count(lastResponse)
        if !instructions.isEmpty {
            seeded += await tokenCounter.count(instructions)
        }
        await tokenLedger.reset(to: seeded)
        await runContext.tracer.record(
            .info(
                runID: runContext.runID,
                category: "compaction",
                message: "session compacted: fresh transcript seeded with instructions + last exchange (~\(seeded) tokens)"
            )
        )
    }

    /// Re-checks the model's availability. Availability is validated at
    /// construction, but a model can become unavailable between init and a
    /// later call (assets evicted, Apple Intelligence toggled off), so each
    /// invocation re-checks before touching the session.
    ///
    /// - Throws: ``CompoundError/modelUnavailable(reason:)`` when the model
    ///   reports an unavailable state.
    internal func ensureAvailable() throws {
        if case .unavailable(let reason) = model.availability {
            throw CompoundError.modelUnavailable(reason: Self.label(reason))
        }
    }

    internal static func label(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "device not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence not enabled"
        case .modelNotReady: return "model not ready (still downloading)"
        @unknown default: return "unavailable (unknown reason)"
        }
    }
}
