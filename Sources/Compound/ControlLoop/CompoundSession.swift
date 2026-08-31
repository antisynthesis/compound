import Foundation
import FoundationModels

/// User-facing facade. Bundles the six layers of the Compound pattern
/// (context, verifiers, tools, governance, observability, control) into a
/// single configurable entry point so callers can `try await session.respond(to:)`
/// without assembling parts by hand.
///
/// Each call is a fresh run with its own ``RunContext``, ``ModelClient``,
/// and ``Budget`` — there is no hidden mutable state across calls beyond
/// the long-lived registry and configuration.
///
/// # Example
/// ```swift
/// let session = CompoundSession(.init(
///     assembler: DefaultContextAssembler(baseInstructions: "Be concise."),
///     tools: registry,
///     outputVerifier: chain,
///     budget: .default
/// ))
/// let outcome = try await session.respond(to: "Plan a trip.")
/// ```
public struct CompoundSession: Sendable {
    /// Active configuration. Read-only after construction.
    public let configuration: Configuration

    /// Creates a session bound to `configuration`.
    public init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Long-lived configuration shared across runs of a session.
    public struct Configuration: Sendable {
        /// Builds the rendered prompt + system instructions for each run.
        public var assembler: any ContextAssembler
        /// Tools available to the model.
        public var tools: ToolRegistry
        /// Cheapest-first chain applied to every model output.
        public var outputVerifier: VerifierChain<String>
        /// Policy authority for privileged operations.
        public var policy: any Policy
        /// Trace sink for governance and audit.
        public var tracer: any Tracer
        /// Per-run resource caps.
        public var budget: Budget
        /// Generation options passed to the model.
        public var generationOptions: GenerationOptions
        /// On-device model. Defaults to ``SystemLanguageModel/default``.
        /// Ignored when ``makeModel`` is non-nil.
        public var model: SystemLanguageModel
        /// Token counter used for context-overflow recovery and, when the
        /// standard ``ModelClient`` transport is constructed, for session
        /// occupancy tracking. `nil` (the default) selects
        /// ``SystemModelTokenCounter`` over ``model`` for the real
        /// transport and ``HeuristicTokenCounter`` when ``makeModel`` is
        /// injected — zero behavior change for tests and fakes.
        public var tokenCounter: (any TokenCounting)?
        /// Fraction of the model's context window treated as the proactive
        /// compaction high watermark (see ``SessionTokenLedger``). Also
        /// caps the re-assembly budget when a run is retried after
        /// ``CompoundError/contextWindowExceeded(promptTokens:)``.
        /// Defaults to 0.8.
        public var contextHighWatermark: Double
        /// Optional factory for the per-run model transport. `nil` (the
        /// default) preserves the standard construction: a ``ModelClient``
        /// over ``model``, availability-checked at the start of every run.
        /// Non-nil is the injection seam — tests and alternative backends
        /// supply any ``ModelResponding`` `&` ``ModelStreaming`` conformer.
        /// The factory receives the assembled system instructions, the
        /// run's instantiated (policy-wrapped) tools, and the ``RunContext``,
        /// so injected transports can exercise the tool path exactly as the
        /// real session would.
        public var makeModel: (
            @Sendable (
                _ instructions: String,
                _ tools: [any Tool],
                _ runContext: RunContext
            ) throws -> any ModelResponding & ModelStreaming
        )?

        /// Creates a configuration. Every field has a safe default so
        /// callers only override what they care about.
        public init(
            assembler: any ContextAssembler,
            tools: ToolRegistry = ToolRegistry(),
            outputVerifier: VerifierChain<String> = .empty(),
            policy: any Policy = AllowAll(),
            tracer: any Tracer = NullTracer(),
            budget: Budget = .default,
            generationOptions: GenerationOptions = GenerationOptions(),
            model: SystemLanguageModel = .default,
            tokenCounter: (any TokenCounting)? = nil,
            contextHighWatermark: Double = 0.8,
            makeModel: (
                @Sendable (
                    _ instructions: String,
                    _ tools: [any Tool],
                    _ runContext: RunContext
                ) throws -> any ModelResponding & ModelStreaming
            )? = nil
        ) {
            precondition(
                contextHighWatermark > 0 && contextHighWatermark <= 1,
                "contextHighWatermark must be in (0, 1]"
            )
            self.assembler = assembler
            self.tools = tools
            self.outputVerifier = outputVerifier
            self.policy = policy
            self.tracer = tracer
            self.budget = budget
            self.generationOptions = generationOptions
            self.model = model
            self.tokenCounter = tokenCounter
            self.contextHighWatermark = contextHighWatermark
            self.makeModel = makeModel
        }
    }

    /// Everything a run needs, assembled once and shared by
    /// ``respond(to:auth:progress:metadata:)`` and
    /// ``stream(userPrompt:auth:progress:metadata:)``.
    private struct PreparedRun {
        let runContext: RunContext
        let prompt: String
        let model: any ModelResponding & ModelStreaming
    }

    /// Shared per-run setup: builds the ``RunContext``, assembles the
    /// prompt, instantiates policy-wrapped tools, and constructs the model
    /// transport. Model availability is re-checked here on every run (not
    /// only when the configuration was created), so a model that became
    /// unavailable after session construction surfaces as
    /// ``CompoundError/modelUnavailable(reason:)`` rather than a downstream
    /// session failure.
    private func makeRun(
        userPrompt: String,
        auth: AuthContext,
        progress: any ProgressReporter,
        metadata: [String: String],
        assembler: (any ContextAssembler)? = nil
    ) async throws -> PreparedRun {
        let runContext = RunContext(
            auth: auth,
            tracer: configuration.tracer,
            progress: progress,
            metadata: metadata,
            toolCallMeter: ToolCallMeter(limit: configuration.budget.maxToolCalls)
        )

        let assembled = try await (assembler ?? configuration.assembler).assemble(
            userPrompt: userPrompt,
            runContext: runContext
        )

        let instantiatedTools = configuration.tools.instantiateAll(
            runContext: runContext,
            policy: configuration.policy
        )

        let model: any ModelResponding & ModelStreaming
        if let makeModel = configuration.makeModel {
            model = try makeModel(assembled.instructions, instantiatedTools, runContext)
        } else {
            // Availability re-check at run time. ModelClient.init performs the
            // same check, but doing it here keeps the TOCTOU window explicit
            // and gives a typed error even if construction paths change.
            if case .unavailable(let reason) = configuration.model.availability {
                throw CompoundError.modelUnavailable(reason: ModelClient.label(reason))
            }
            model = try ModelClient(
                instructions: assembled.instructions,
                tools: instantiatedTools,
                runContext: runContext,
                model: configuration.model,
                tokenCounter: resolvedTokenCounter(),
                contextHighWatermark: configuration.contextHighWatermark
            )
        }

        return PreparedRun(
            runContext: runContext,
            prompt: assembled.renderedPrompt(),
            model: model
        )
    }

    /// Token counter for overflow recovery and the standard transport's
    /// occupancy ledger. An injected ``Configuration/tokenCounter`` always
    /// wins; otherwise the real transport gets the system model's counter
    /// and injected (fake) transports get the heuristic, so tests see zero
    /// behavior change.
    private func resolvedTokenCounter() -> any TokenCounting {
        if let counter = configuration.tokenCounter { return counter }
        if configuration.makeModel == nil {
            return SystemModelTokenCounter(model: configuration.model)
        }
        return HeuristicTokenCounter()
    }

    /// Runs a single non-streaming compound execution.
    ///
    /// If the model reports
    /// ``CompoundError/contextWindowExceeded(promptTokens:)`` the run is
    /// routed back through the assembler path exactly once: the assembler
    /// is wrapped in a ``TokenBudgetedAssembler`` capped at
    /// ``Configuration/contextHighWatermark`` of the counter's context
    /// window and the run is retried with the trimmed prompt. A second
    /// overflow propagates.
    ///
    /// - Parameters:
    ///   - userPrompt: The user's prompt for this run.
    ///   - auth: Identity for policy decisions.
    ///   - progress: Sink for UI progress events.
    ///   - metadata: Free-form tags propagated through the ``RunContext``.
    /// - Returns: The ``LoopOutcome`` for the completed run.
    /// - Throws: ``CompoundError`` on any failure mode (model, verifier,
    ///   budget, policy, tool).
    public func respond(
        to userPrompt: String,
        auth: AuthContext = .anonymous,
        progress: any ProgressReporter = NullProgressReporter(),
        metadata: [String: String] = [:]
    ) async throws -> LoopOutcome {
        let run = try await makeRun(
            userPrompt: userPrompt,
            auth: auth,
            progress: progress,
            metadata: metadata
        )

        let loop = ControlLoop(
            budget: configuration.budget,
            outputVerifier: configuration.outputVerifier,
            generationOptions: configuration.generationOptions
        )

        do {
            return try await loop.run(
                prompt: run.prompt,
                modelClient: run.model,
                runContext: run.runContext
            )
        } catch let error as CompoundError {
            guard case .contextWindowExceeded(let promptTokens) = error else { throw error }
            let counter = resolvedTokenCounter()
            let cap = max(1, Int(Double(counter.contextSize) * configuration.contextHighWatermark))
            await run.runContext.tracer.record(
                .info(
                    runID: run.runContext.runID,
                    category: "contextWindow",
                    message: "context window exceeded (promptTokens: \(promptTokens.map(String.init) ?? "unknown")); re-assembling under a \(cap)-token budget"
                )
            )
            let squeezed = TokenBudgetedAssembler(
                wrapping: configuration.assembler,
                maxPromptTokens: cap,
                counter: counter
            )
            let retry = try await makeRun(
                userPrompt: userPrompt,
                auth: auth,
                progress: progress,
                metadata: metadata,
                assembler: squeezed
            )
            return try await loop.run(
                prompt: retry.prompt,
                modelClient: retry.model,
                runContext: retry.runContext
            )
        }
    }

    /// Runs a typed compound execution producing a structured `T`.
    ///
    /// Built on the same makeRun seam as ``respond(to:auth:progress:metadata:)``:
    /// the assembler renders the prompt, tools are policy-wrapped, and the
    /// transport comes from ``Configuration/makeModel`` when injected. The
    /// typed loop's extraction phase is bound to the transport's
    /// `respondGenerating` via ``ModelResponding/extractor(_:options:)``.
    ///
    /// In ``TypedRunMode/reasonThenExtract`` (the default) the model first
    /// reasons free-form — tools allowed, gated by
    /// ``Configuration/outputVerifier`` — and only the extraction pass is
    /// constrained to `T`'s schema; grammar-constrained decoding
    /// measurably hurts reasoning-heavy tasks, so the constraint is applied
    /// as late as possible. ``TypedRunMode/direct`` extracts straight from
    /// the assembled prompt (no tools, no string verifiers).
    ///
    /// - Parameters:
    ///   - userPrompt: The user's prompt for this run.
    ///   - type: The `Generable` type to produce.
    ///   - verifiers: Typed chain gating every extracted value. A
    ///     ``Verdict/repair(_:)`` verdict feeds the standard repair path.
    ///   - mode: Phase structure; defaults to ``TypedRunMode/reasonThenExtract``.
    ///   - auth: Identity for policy decisions.
    ///   - progress: Sink for UI progress events.
    ///   - metadata: Free-form tags propagated through the ``RunContext``.
    /// - Returns: The ``TypedRunOutcome`` for the completed run.
    /// - Throws: ``CompoundError`` on any failure mode (model, verifier,
    ///   budget, policy, tool).
    public func respond<T: Generable & Sendable>(
        to userPrompt: String,
        generating type: T.Type,
        verifiers: VerifierChain<T> = .empty(),
        mode: TypedRunMode = .reasonThenExtract,
        auth: AuthContext = .anonymous,
        progress: any ProgressReporter = NullProgressReporter(),
        metadata: [String: String] = [:]
    ) async throws -> TypedRunOutcome<T> {
        let run = try await makeRun(
            userPrompt: userPrompt,
            auth: auth,
            progress: progress,
            metadata: metadata
        )

        let loop = ControlLoop(
            budget: configuration.budget,
            outputVerifier: configuration.outputVerifier,
            generationOptions: configuration.generationOptions
        )

        return try await loop.run(
            prompt: run.prompt,
            modelClient: run.model,
            runContext: run.runContext,
            mode: mode,
            extract: run.model.extractor(type, options: configuration.generationOptions),
            verifiers: verifiers
        )
    }

    /// Runs a streaming compound execution.
    ///
    /// Returns a ``StreamingControlLoop/Run`` whose `stream` yields every
    /// ``ProgressEvent`` (model chunks, repair scheduling, completion)
    /// and whose `outcome` resolves to the final ``StreamingLoopOutcome``.
    /// Cancelling the outcome task or terminating the stream cancels the
    /// underlying loop.
    public func stream(
        userPrompt: String,
        auth: AuthContext = .anonymous,
        progress: any ProgressReporter = NullProgressReporter(),
        metadata: [String: String] = [:]
    ) async throws -> StreamingControlLoop.Run {
        let run = try await makeRun(
            userPrompt: userPrompt,
            auth: auth,
            progress: progress,
            metadata: metadata
        )

        let loop = StreamingControlLoop(
            budget: configuration.budget,
            outputVerifier: configuration.outputVerifier,
            generationOptions: configuration.generationOptions
        )

        return loop.run(
            prompt: run.prompt,
            modelClient: run.model,
            runContext: run.runContext
        )
    }

    /// Current availability of the underlying on-device model.
    public func availability() -> SystemLanguageModel.Availability {
        configuration.model.availability
    }

    /// Convenience boolean equivalent of ``availability()``.
    public func isAvailable() -> Bool {
        configuration.model.isAvailable
    }
}
