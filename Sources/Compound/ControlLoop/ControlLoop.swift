import Foundation
import FoundationModels

/// Successful result of ``ControlLoop/run(prompt:modelClient:runContext:)``.
public struct LoopOutcome: Sendable {
    /// Final model output that passed every chain member.
    public let output: String
    /// Resource accounting at run completion.
    public let usage: BudgetUsage
    /// Identifier from the originating ``RunContext``.
    public let runID: UUID
}

/// How the typed loop turns a prompt into a structured value.
///
/// Guided generation is constrained decoding, and grammar constraints
/// measurably hurt reasoning-heavy tasks (CRANE; "Let Me Speak Freely?").
/// ``reasonThenExtract`` therefore reasons free-form first and constrains
/// only the extraction pass; ``direct`` skips straight to extraction for
/// tasks that need no intermediate reasoning (and no tools).
public enum TypedRunMode: Sendable, Equatable {
    /// One phase: the extractor is invoked directly on the user prompt.
    /// No free-form turn runs, so the loop's string verifier chain never
    /// executes and tools are never available — constrained decoding is
    /// the whole run.
    case direct
    /// Two phases. Phase one is a standard free-form loop turn (tools
    /// allowed, gated by the loop's string ``VerifierChain``, repairs as
    /// usual). Phase two hands the passing free-form output to the
    /// extractor, whose result is gated by the typed chain. Structured
    /// extraction is never combined with a tool-enabled turn — Apple
    /// documents that mixing tool calling with `generating:` in a single
    /// respond breaks multi-step tool invocation.
    case reasonThenExtract
}

/// Successful result of the typed control loop
/// (``ControlLoop/run(prompt:modelClient:runContext:mode:extract:verifiers:)``).
public struct TypedRunOutcome<T: Sendable>: Sendable {
    /// Extracted value that passed every typed chain member.
    public let value: T
    /// Free-form phase-one output in ``TypedRunMode/reasonThenExtract``;
    /// `nil` in ``TypedRunMode/direct`` (no reasoning turn ran).
    public let reasoning: String?
    /// Resource accounting at run completion — reasoning turns, extraction
    /// turns, and repairs all debit the same ``Budget``.
    public let usage: BudgetUsage
    /// Identifier from the originating ``RunContext``.
    public let runID: UUID
}

/// Orchestrates the propose-and-check loop. Asks a ``ModelResponding``
/// for a response, gates it through the supplied output
/// ``VerifierChain``, and on failure feeds the diagnostic into a repair
/// turn — bounded by ``Budget`` on every dimension.
///
/// The loop, not the model, decides what verifier runs and when to stop.
/// A model that could skip verification provides much weaker guarantees
/// than one whose outputs are gated unconditionally.
///
/// # Example
/// ```swift
/// let loop = ControlLoop(
///     budget: .default,
///     outputVerifier: VerifierChain(name: "out", [JSONVerifier().erased()])
/// )
/// let outcome = try await loop.run(
///     prompt: prompt,
///     modelClient: client,
///     runContext: ctx
/// )
/// ```
public struct ControlLoop: Sendable {
    /// Per-run resource caps.
    public let budget: Budget
    /// Cheapest-first verifier chain applied to every model output.
    public let outputVerifier: VerifierChain<String>
    /// Generation options passed to the model on each turn.
    public let generationOptions: GenerationOptions
    /// Backoff schedule applied when the model call fails transiently
    /// (rate limiting, connectivity hiccups, model still downloading).
    /// Retry backoff sleeps count against ``Budget/wallClock``.
    public let retryPolicy: RetryPolicy
    /// Decides which model-call errors are transient. Terminal errors —
    /// guardrail violations, refusals, unsupported language — surface
    /// immediately without consuming a retry.
    public let retryClassifier: any RetryClassifier
    /// Builds the next prompt when a turn fails verification. The default
    /// (``RepairPromptBuilder/default``) rebuilds a self-contained prompt —
    /// original task, byte-capped failed output, every diagnostic — which
    /// is required for stateless ``ModelResponding`` conformers; stateful
    /// conformers may use ``RepairPromptBuilder/diagnosticOnly``.
    public let repairPromptBuilder: RepairPromptBuilder

    /// Creates a control loop.
    public init(
        budget: Budget = .default,
        outputVerifier: VerifierChain<String> = .empty(),
        generationOptions: GenerationOptions = GenerationOptions(),
        retryPolicy: RetryPolicy = .default,
        retryClassifier: any RetryClassifier = DefaultRetryClassifier(),
        repairPromptBuilder: RepairPromptBuilder = .default
    ) {
        self.budget = budget
        self.outputVerifier = outputVerifier
        self.generationOptions = generationOptions
        self.retryPolicy = retryPolicy
        self.retryClassifier = retryClassifier
        self.repairPromptBuilder = repairPromptBuilder
    }

    /// Runs the propose-and-check loop until one of:
    /// pass, reject, escalate, or budget exhausted. Honors task
    /// cancellation between turns and around the model call.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to start the loop with.
    ///   - modelClient: Any ``ModelResponding``-conforming actor.
    ///   - runContext: Carries trace IDs, progress reporter, and identity.
    /// - Returns: The final ``LoopOutcome`` on a passing verdict.
    /// - Throws: ``CompoundError/budgetExhausted(_:_:)`` on budget exhaustion,
    ///   ``CompoundError/verifierRejected(reason:lastDiagnostic:)`` on a
    ///   terminal verifier verdict, ``CompoundError/escalationRequired(reason:lastDiagnostic:)``
    ///   on escalation, or `CancellationError` on cancellation. Model-layer
    ///   failures surface typed: transient ones (``CompoundError/modelRateLimited``,
    ///   retryable unavailability, connectivity hiccups) are retried on
    ///   ``retryPolicy`` first; ``CompoundError/guardrailViolation(context:)``
    ///   and ``CompoundError/unsupportedLanguage`` throw immediately without
    ///   consuming retry or repair budget; ``CompoundError/contextWindowExceeded(promptTokens:)``
    ///   surfaces as its typed error for the caller to route to compaction.
    public func run(
        prompt: String,
        modelClient: any ModelResponding,
        runContext: RunContext
    ) async throws -> LoopOutcome {
        var usage = BudgetUsage()
        let started = ContinuousClock.now
        let core = LoopCore(
            budget: budget,
            outputVerifier: outputVerifier,
            retryPolicy: retryPolicy,
            retryClassifier: retryClassifier,
            repairPromptBuilder: repairPromptBuilder
        )

        await runContext.tracer.record(
            .runStarted(
                runID: runContext.runID,
                prompt: prompt,
                budget: budget,
                auth: runContext.auth.principal
            )
        )

        let output = try await freeformPhase(
            prompt: prompt,
            modelClient: modelClient,
            core: core,
            usage: &usage,
            started: started,
            runContext: runContext,
            isFinal: true
        )
        return LoopOutcome(output: output, usage: usage, runID: runContext.runID)
    }

    /// Runs the typed control loop: same propose-and-check discipline as
    /// ``run(prompt:modelClient:runContext:)``, but the run's product is a
    /// structured `T` produced by `extract` and gated by a typed
    /// ``VerifierChain``. The loop layer is deliberately `Generable`-free —
    /// `extract` is any `(String) async throws -> T` closure; production
    /// callers bind it to `respondGenerating` via
    /// ``ModelResponding/extractor(_:options:)``.
    ///
    /// In ``TypedRunMode/reasonThenExtract`` (the default), phase one is a
    /// standard free-form loop — `respond()` turns with tools allowed,
    /// gated by ``outputVerifier``, string-level repairs as usual — and
    /// phase two invokes `extract` on the passing free-form output. In
    /// ``TypedRunMode/direct``, `extract` is invoked on `prompt` itself and
    /// ``outputVerifier`` never runs. The two phases are structurally
    /// separate: no turn both uses tools and performs structured
    /// extraction.
    ///
    /// A typed-verifier ``Verdict/repair(_:)`` feeds the standard repair
    /// path: ``repairPromptBuilder`` renders a self-contained repair prompt
    /// (extraction source + stringified failed value + diagnostics) and the
    /// extractor is re-invoked with it, debiting
    /// ``Budget/maxRepairAttempts`` and ``Budget/maxTurns`` exactly like a
    /// string repair. Extraction calls run under the same retry policy and
    /// wall-clock deadline as model calls; an extractor failure surfaces
    /// through the standard error taxonomy
    /// (``CompoundError/underlying(_:)`` for unrecognized errors).
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to start the loop with.
    ///   - modelClient: Transport for phase-one reasoning turns. Unused in
    ///     ``TypedRunMode/direct``.
    ///   - runContext: Carries trace IDs, progress reporter, and identity.
    ///   - mode: Phase structure; defaults to ``TypedRunMode/reasonThenExtract``.
    ///   - extract: Produces a `T` from a prompt string — the free-form
    ///     reasoning output, the raw prompt (in `.direct`), or a repair
    ///     prompt. Must be self-contained (stateless-safe).
    ///   - verifiers: Typed chain gating every extracted value.
    /// - Returns: The final ``TypedRunOutcome`` on a passing typed verdict.
    /// - Throws: Everything ``run(prompt:modelClient:runContext:)`` throws,
    ///   from either phase.
    public func run<T: Sendable>(
        prompt: String,
        modelClient: any ModelResponding,
        runContext: RunContext,
        mode: TypedRunMode = .reasonThenExtract,
        extract: @escaping @Sendable (String) async throws -> T,
        verifiers: VerifierChain<T> = .empty()
    ) async throws -> TypedRunOutcome<T> {
        var usage = BudgetUsage()
        let started = ContinuousClock.now
        let core = LoopCore(
            budget: budget,
            outputVerifier: outputVerifier,
            retryPolicy: retryPolicy,
            retryClassifier: retryClassifier,
            repairPromptBuilder: repairPromptBuilder
        )

        await runContext.tracer.record(
            .runStarted(
                runID: runContext.runID,
                prompt: prompt,
                budget: budget,
                auth: runContext.auth.principal
            )
        )

        // Phase one (reasonThenExtract only): free-form reasoning, tools
        // allowed, string chain gating. A pass here does NOT end the run —
        // isFinal: false defers the successful run-ended trace to the
        // typed settle.
        var reasoning: String?
        var extractionSource = prompt
        if mode == .reasonThenExtract {
            let freeform = try await freeformPhase(
                prompt: prompt,
                modelClient: modelClient,
                core: core,
                usage: &usage,
                started: started,
                runContext: runContext,
                isFinal: false
            )
            reasoning = freeform
            extractionSource = freeform
        }

        // Phase two: structured extraction, no tools, typed chain gating.
        var nextInput = extractionSource
        while true {
            try await core.beginTurn(usage: &usage, started: started, runContext: runContext)

            let input = nextInput
            let value = try await core.invokeModel(
                usage: &usage,
                started: started,
                runContext: runContext
            ) {
                try await extract(input)
            }
            try Task.checkCancellation()
            let rendered = String(describing: value)
            usage.recordOutputTokens(Budget.approximateTokens(rendered))

            switch try await core.settleTyped(
                value: value,
                renderedOutput: rendered,
                verifiers: verifiers,
                originalTask: extractionSource,
                usage: &usage,
                started: started,
                runContext: runContext
            ) {
            case .done(let final):
                return TypedRunOutcome(
                    value: final,
                    reasoning: reasoning,
                    usage: usage,
                    runID: runContext.runID
                )
            case .repair(let next):
                nextInput = next
            }
        }
    }

    /// The free-form propose-and-check loop shared by the string run and
    /// the typed run's reasoning phase: `respond()` turns gated by the
    /// string chain, repairs until pass or a terminal disposition.
    /// `isFinal` is forwarded to ``LoopCore/settle(output:originalTask:usage:started:runContext:isFinal:)``
    /// so the typed run can defer the successful run-ended trace to its
    /// extraction phase.
    private func freeformPhase(
        prompt: String,
        modelClient: any ModelResponding,
        core: LoopCore,
        usage: inout BudgetUsage,
        started: ContinuousClock.Instant,
        runContext: RunContext,
        isFinal: Bool
    ) async throws -> String {
        var nextPrompt = prompt

        while true {
            try await core.beginTurn(usage: &usage, started: started, runContext: runContext)

            let turnPrompt = nextPrompt
            let output = try await core.invokeModel(
                usage: &usage,
                started: started,
                runContext: runContext
            ) {
                try await modelClient.respond(to: turnPrompt, options: generationOptions)
            }
            try Task.checkCancellation()
            usage.recordOutputTokens(Budget.approximateTokens(output))

            switch try await core.settle(
                output: output,
                originalTask: prompt,
                usage: &usage,
                started: started,
                runContext: runContext,
                isFinal: isFinal
            ) {
            case .done(let final):
                return final
            case .repair(let next):
                nextPrompt = next
            }
        }
    }
}
