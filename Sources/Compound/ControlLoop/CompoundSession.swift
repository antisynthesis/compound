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
        /// How many candidates each free-form turn draws and how one is
        /// selected. ``SamplingStrategy/single`` (the default) is one model
        /// call per turn.
        ///
        /// Applies to ``respond(to:auth:progress:metadata:)`` and to the
        /// reasoning phase of ``respond(to:generating:verifiers:mode:auth:progress:metadata:)``.
        /// ``stream(userPrompt:auth:progress:metadata:)`` always draws a
        /// single candidate: `n` interleaved chunk sequences cannot be
        /// replayed as one coherent stream, and picking a winner only after
        /// all `n` finished would defeat streaming entirely.
        ///
        /// Remember that best-of-N multiplies model calls — cap the cost
        /// with ``Budget/maxSamples``.
        public var sampling: SamplingStrategy
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
        /// Cross-run circuit breakers driving the degradation ladder.
        /// `nil` (the default) disables degradation entirely: every run
        /// executes at ``DegradedMode/full`` exactly as it did before the
        /// ladder existed.
        ///
        /// When non-nil, each run asks the monitor for its rung *before*
        /// assembling (see ``DegradedMode``), and reports the run's typed
        /// outcome back so the breakers learn. The monitor is a long-lived
        /// actor: share one instance across every session that talks to
        /// the same device model.
        public var health: HealthMonitor?
        /// Confidence cascade consulted by
        /// ``respondRouted(to:auth:progress:metadata:)``. `nil` (the
        /// default) means no escalation — that entry point then behaves
        /// exactly like ``respond(to:auth:progress:metadata:)``.
        ///
        /// Routing sits beside ``sampling`` because it is the same
        /// decision one level up: `sampling` says how many candidates one
        /// turn draws, `routing` says what to do when those candidates
        /// disagree.
        public var routing: RoutingPolicy?
        /// Deterministic answer used when the ladder reaches
        /// ``DegradedMode/deterministicOnly`` and no model call is
        /// permitted. Receives the user prompt; its result becomes the
        /// run's output. `nil` (the default) makes such a run throw
        /// ``CompoundError/degraded(mode:reason:)`` instead.
        ///
        /// The fallback is *not* gated by ``outputVerifier``: the chain
        /// exists to gate model output, and a repair turn — the only
        /// remedy a failing verdict has — is precisely what this rung has
        /// ruled out.
        public var degradedFallback: (@Sendable (String) async throws -> String)?
        /// Fraction of ``contextHighWatermark`` a ``DegradedMode/reducedContext``
        /// run is squeezed to. Defaults to 0.5.
        public var reducedContextFactor: Double

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
            sampling: SamplingStrategy = .single,
            model: SystemLanguageModel = .default,
            tokenCounter: (any TokenCounting)? = nil,
            contextHighWatermark: Double = 0.8,
            makeModel: (
                @Sendable (
                    _ instructions: String,
                    _ tools: [any Tool],
                    _ runContext: RunContext
                ) throws -> any ModelResponding & ModelStreaming
            )? = nil,
            health: HealthMonitor? = nil,
            routing: RoutingPolicy? = nil,
            degradedFallback: (@Sendable (String) async throws -> String)? = nil,
            reducedContextFactor: Double = 0.5
        ) {
            precondition(
                contextHighWatermark > 0 && contextHighWatermark <= 1,
                "contextHighWatermark must be in (0, 1]"
            )
            precondition(
                reducedContextFactor > 0 && reducedContextFactor <= 1,
                "reducedContextFactor must be in (0, 1]"
            )
            self.assembler = assembler
            self.tools = tools
            self.outputVerifier = outputVerifier
            self.policy = policy
            self.tracer = tracer
            self.budget = budget
            self.generationOptions = generationOptions
            self.sampling = sampling
            self.model = model
            self.tokenCounter = tokenCounter
            self.contextHighWatermark = contextHighWatermark
            self.makeModel = makeModel
            self.health = health
            self.routing = routing
            self.degradedFallback = degradedFallback
            self.reducedContextFactor = reducedContextFactor
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
        runID: UUID = UUID(),
        mode: DegradedMode = .full,
        assembler: (any ContextAssembler)? = nil
    ) async throws -> PreparedRun {
        let runContext = RunContext(
            runID: runID,
            auth: auth,
            tracer: configuration.tracer,
            progress: progress,
            metadata: metadata,
            toolCallMeter: ToolCallMeter(limit: configuration.budget.maxToolCalls)
        )

        // The ladder is applied here, at the facade, and nowhere else:
        // reducedContext squeezes the assembled prompt, noTools withholds
        // the registry. An explicitly supplied `assembler` is already
        // budgeted (the context-overflow retry path), so it is never
        // double-wrapped.
        var effectiveAssembler = assembler ?? configuration.assembler
        if assembler == nil, mode.reducesContext {
            effectiveAssembler = TokenBudgetedAssembler(
                wrapping: effectiveAssembler,
                maxPromptTokens: reducedContextCap(),
                counter: resolvedTokenCounter()
            )
        }

        let assembled = try await effectiveAssembler.assemble(
            userPrompt: userPrompt,
            runContext: runContext
        )

        let instantiatedTools = mode.allowsTools
            ? configuration.tools.instantiateAll(
                runContext: runContext,
                policy: configuration.policy
            )
            : []

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
                contextHighWatermark: mode.reducesContext
                    ? configuration.contextHighWatermark * configuration.reducedContextFactor
                    : configuration.contextHighWatermark
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

    /// Prompt-token cap for a ``DegradedMode/reducedContext`` run: the
    /// normal watermark scaled by ``Configuration/reducedContextFactor``.
    private func reducedContextCap() -> Int {
        let counter = resolvedTokenCounter()
        let fraction = configuration.contextHighWatermark * configuration.reducedContextFactor
        return max(1, Int(Double(counter.contextSize) * fraction))
    }

    // MARK: - Degradation ladder

    /// Rung the next run would execute at, advancing any circuit-breaker
    /// cooldown that has elapsed. ``DegradedMode/full`` when no
    /// ``Configuration/health`` monitor is configured.
    public func currentDegradedMode() async -> DegradedMode {
        guard let health = configuration.health else { return .full }
        return await health.assess().mode
    }

    /// Full ladder assessment behind ``currentDegradedMode()`` — the rung,
    /// why, and every breaker's state.
    public func healthAssessment() async -> HealthAssessment {
        guard let health = configuration.health else {
            return HealthAssessment(mode: .full, reason: "no health monitor", signal: nil, states: [:])
        }
        return await health.assess()
    }

    /// Pins every subsequent run to `mode`, or clears a previous pin with
    /// `nil`. An override replaces the breaker-derived rung outright — it
    /// can force a run *down* the ladder as well as up.
    public func setDegradedMode(_ mode: DegradedMode?) async {
        await configuration.health?.setOverride(mode)
    }

    /// Assesses the ladder for a run and records the rung on the trace.
    private func assess(runID: UUID) async -> HealthAssessment {
        guard let health = configuration.health else {
            return HealthAssessment(mode: .full, reason: "no health monitor", signal: nil, states: [:])
        }
        let assessment = await health.assess(runID: runID)
        if assessment.isDegraded {
            await configuration.tracer.record(
                .degradationApplied(runID: runID, mode: assessment.mode, reason: assessment.reason)
            )
        }
        return assessment
    }

    /// Deterministic short-circuit for ``DegradedMode/deterministicOnly``:
    /// the caller's fallback if there is one, otherwise the typed refusal.
    private func deterministicOutcome(
        userPrompt: String,
        runID: UUID,
        assessment: HealthAssessment
    ) async throws -> LoopOutcome {
        guard let fallback = configuration.degradedFallback else {
            throw CompoundError.degraded(mode: assessment.mode, reason: assessment.reason)
        }
        return LoopOutcome(
            output: try await fallback(userPrompt),
            usage: BudgetUsage(),
            runID: runID,
            confidence: nil
        )
    }

    /// One attempt: assess the ladder, apply the rung, run the loop, and
    /// feed the typed result back to the monitor.
    ///
    /// `sampling` and `outputVerifier` are parameters rather than reads of
    /// ``Configuration`` so the confidence cascade can hand this method an
    /// escalated strategy without mutating the session.
    private func attempt(
        userPrompt: String,
        auth: AuthContext,
        progress: any ProgressReporter,
        metadata: [String: String],
        sampling: SamplingStrategy,
        outputVerifier: VerifierChain<String>
    ) async throws -> LoopOutcome {
        let runID = UUID()
        let assessment = await assess(runID: runID)
        guard assessment.mode.allowsModelCalls else {
            return try await deterministicOutcome(
                userPrompt: userPrompt,
                runID: runID,
                assessment: assessment
            )
        }

        let loop = ControlLoop(
            budget: configuration.budget,
            outputVerifier: outputVerifier,
            generationOptions: configuration.generationOptions,
            sampling: sampling
        )

        do {
            let run = try await makeRun(
                userPrompt: userPrompt,
                auth: auth,
                progress: progress,
                metadata: metadata,
                runID: runID,
                mode: assessment.mode
            )
            let outcome = try await loop.run(
                prompt: run.prompt,
                modelClient: run.model,
                runContext: run.runContext
            )
            await configuration.health?.recordSuccess(runID: runID)
            return outcome
        } catch let error as CompoundError {
            await configuration.health?.record(error, runID: runID)
            guard case .contextWindowExceeded(let promptTokens) = error else { throw error }
            let counter = resolvedTokenCounter()
            let watermarkCap = max(1, Int(Double(counter.contextSize) * configuration.contextHighWatermark))
            // A run already squeezed by the ladder retries under the
            // tighter of the two caps: the overflow proves the reduced
            // budget was not the thing that was too generous.
            let cap = assessment.mode.reducesContext
                ? min(watermarkCap, reducedContextCap())
                : watermarkCap
            await configuration.tracer.record(
                .info(
                    runID: runID,
                    category: "contextWindow",
                    message: "context window exceeded (promptTokens: \(promptTokens.map(String.init) ?? "unknown")); re-assembling under a \(cap)-token budget"
                )
            )
            let squeezed = TokenBudgetedAssembler(
                wrapping: configuration.assembler,
                maxPromptTokens: cap,
                counter: counter
            )
            do {
                let retry = try await makeRun(
                    userPrompt: userPrompt,
                    auth: auth,
                    progress: progress,
                    metadata: metadata,
                    runID: UUID(),
                    mode: assessment.mode,
                    assembler: squeezed
                )
                let outcome = try await loop.run(
                    prompt: retry.prompt,
                    modelClient: retry.model,
                    runContext: retry.runContext
                )
                await configuration.health?.recordSuccess(runID: retry.runContext.runID)
                return outcome
            } catch let retryError as CompoundError {
                await configuration.health?.record(retryError, runID: runID)
                throw retryError
            }
        }
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
    ///   budget, policy, tool), or
    ///   ``CompoundError/degraded(mode:reason:)`` when the ladder has
    ///   reached ``DegradedMode/deterministicOnly`` and no
    ///   ``Configuration/degradedFallback`` is configured.
    ///
    /// This entry point never re-runs on low confidence — one call is one
    /// run. Configure ``Configuration/routing`` and call
    /// ``respondRouted(to:auth:progress:metadata:)`` for the cascade.
    public func respond(
        to userPrompt: String,
        auth: AuthContext = .anonymous,
        progress: any ProgressReporter = NullProgressReporter(),
        metadata: [String: String] = [:]
    ) async throws -> LoopOutcome {
        try await attempt(
            userPrompt: userPrompt,
            auth: auth,
            progress: progress,
            metadata: metadata,
            sampling: configuration.sampling,
            outputVerifier: configuration.outputVerifier
        )
    }

    /// Runs a non-streaming execution under the confidence cascade.
    ///
    /// The first attempt uses the session's own ``Configuration/sampling``
    /// and ``Configuration/outputVerifier``. If its
    /// ``LoopOutcome/confidence`` fails ``RoutingPolicy/minConfidence``,
    /// the next ``EscalationStep`` is applied — more candidates, a
    /// different selection policy, a tighter chain — and the prompt is run
    /// again. Escalation stops at the first attempt that clears the bar or
    /// when the ladder is spent, so a routed call issues at most
    /// `escalation.count + 1` runs.
    ///
    /// **Each attempt is a full run with its own ``Budget``.** Attempts are
    /// not turns: they re-assemble, re-instantiate tools, and start their
    /// budgets from zero, exactly as separate ``respond(to:auth:progress:metadata:)``
    /// calls would. Size the ladder accordingly — the real cost ceiling is
    /// `(escalation.count + 1) × budget × samples-per-attempt`.
    ///
    /// The returned ``RoutedOutcome/lowConfidence`` flag is `true` when the
    /// *final* attempt still failed the bar. That is the signal to defer to
    /// a human: the framework has spent every strategy it has and the model
    /// still does not agree with itself.
    ///
    /// - Parameters:
    ///   - userPrompt: The user's prompt for this run.
    ///   - auth: Identity for policy decisions.
    ///   - progress: Sink for UI progress events.
    ///   - metadata: Free-form tags propagated through the ``RunContext``.
    /// - Returns: The final attempt's outcome plus the routing evidence.
    /// - Throws: Everything ``respond(to:auth:progress:metadata:)`` throws.
    ///   A failing attempt is *not* retried at the next rung — escalation
    ///   answers low confidence, not failure, which the loop's own repair
    ///   and retry paths already own.
    public func respondRouted(
        to userPrompt: String,
        auth: AuthContext = .anonymous,
        progress: any ProgressReporter = NullProgressReporter(),
        metadata: [String: String] = [:]
    ) async throws -> RoutedOutcome {
        var sampling = configuration.sampling
        var verifier = configuration.outputVerifier
        var outcome = try await attempt(
            userPrompt: userPrompt,
            auth: auth,
            progress: progress,
            metadata: metadata,
            sampling: sampling,
            outputVerifier: verifier
        )

        guard let routing = configuration.routing else {
            return RoutedOutcome(outcome: outcome, appliedSteps: [], lowConfidence: false)
        }

        var applied: [String] = []
        for step in routing.escalation {
            guard routing.isLowConfidence(outcome.confidence) else { break }
            await configuration.tracer.record(
                .routingEscalated(
                    runID: outcome.runID,
                    step: step.label,
                    confidence: outcome.confidence,
                    attempt: applied.count + 1
                )
            )
            sampling = step.applied(to: sampling)
            verifier = step.applied(to: verifier)
            applied.append(step.label)
            outcome = try await attempt(
                userPrompt: userPrompt,
                auth: auth,
                progress: progress,
                metadata: metadata,
                sampling: sampling,
                outputVerifier: verifier
            )
        }

        return RoutedOutcome(
            outcome: outcome,
            appliedSteps: applied,
            lowConfidence: routing.isLowConfidence(outcome.confidence)
        )
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
        let runID = UUID()
        let assessment = await assess(runID: runID)
        guard assessment.mode.allowsModelCalls else {
            // A typed run's product is a structured value, and a fallback
            // that produced strings cannot supply one — the refusal is the
            // only honest answer here.
            throw CompoundError.degraded(mode: assessment.mode, reason: assessment.reason)
        }

        let loop = ControlLoop(
            budget: configuration.budget,
            outputVerifier: configuration.outputVerifier,
            generationOptions: configuration.generationOptions,
            sampling: configuration.sampling
        )

        do {
            let run = try await makeRun(
                userPrompt: userPrompt,
                auth: auth,
                progress: progress,
                metadata: metadata,
                runID: runID,
                mode: assessment.mode
            )
            let outcome = try await loop.run(
                prompt: run.prompt,
                modelClient: run.model,
                runContext: run.runContext,
                mode: mode,
                extract: run.model.extractor(type, options: configuration.generationOptions),
                verifiers: verifiers
            )
            await configuration.health?.recordSuccess(runID: runID)
            return outcome
        } catch let error as CompoundError {
            await configuration.health?.record(error, runID: runID)
            throw error
        }
    }

    /// Runs a streaming compound execution.
    ///
    /// Returns a ``StreamingControlLoop/Run`` whose `stream` yields every
    /// ``ProgressEvent`` (model chunks, repair scheduling, completion)
    /// and whose `outcome` resolves to the final ``StreamingLoopOutcome``.
    /// Cancelling the outcome task or terminating the stream cancels the
    /// underlying loop.
    ///
    /// The degradation ladder gates the run exactly as it gates
    /// ``respond(to:auth:progress:metadata:)``, but a
    /// ``DegradedMode/deterministicOnly`` rung always throws
    /// ``CompoundError/degraded(mode:reason:)`` here: a fallback string is
    /// not a stream, and pretending otherwise would hand callers a
    /// one-chunk "stream" that never came from a model. Health *signals*
    /// are recorded for setup failures only — a streaming run's outcome
    /// resolves after this method returns, and its failures reach the
    /// caller through ``StreamingControlLoop/Run/outcome``.
    public func stream(
        userPrompt: String,
        auth: AuthContext = .anonymous,
        progress: any ProgressReporter = NullProgressReporter(),
        metadata: [String: String] = [:]
    ) async throws -> StreamingControlLoop.Run {
        let runID = UUID()
        let assessment = await assess(runID: runID)
        guard assessment.mode.allowsModelCalls else {
            throw CompoundError.degraded(mode: assessment.mode, reason: assessment.reason)
        }
        let run: PreparedRun
        do {
            run = try await makeRun(
                userPrompt: userPrompt,
                auth: auth,
                progress: progress,
                metadata: metadata,
                runID: runID,
                mode: assessment.mode
            )
        } catch let error as CompoundError {
            await configuration.health?.record(error, runID: runID)
            throw error
        }

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
