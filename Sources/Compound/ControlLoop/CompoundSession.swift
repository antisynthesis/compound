import Foundation
import FoundationModels

/// The front door. The six layers of the Compound pattern — context,
/// verifiers, tools, governance, observability, control — assembled into one
/// instrument so callers can `try await session.respond(to:)` without wiring
/// the machine by hand. Easy to hold; that ease is not where the guarantees
/// come from.
///
/// Each call is a fresh run with its own ``RunContext``, ``ModelClient``, and
/// ``Budget``. Nothing leaks between calls but the long-lived registry and
/// configuration — no hidden state, no surprises carried forward.
///
/// # Example
/// ```swift
/// let session = CompoundSession(.init(
///     assembler: PromptOnlyAssembler(instructions: "Be concise."),
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
        public var model: SystemLanguageModel

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
            model: SystemLanguageModel = .default
        ) {
            self.assembler = assembler
            self.tools = tools
            self.outputVerifier = outputVerifier
            self.policy = policy
            self.tracer = tracer
            self.budget = budget
            self.generationOptions = generationOptions
            self.model = model
        }
    }

    /// One run, end to end: assemble the context, let the model propose, gate
    /// the proposal, dispose of what fails. The model proposes; the system
    /// disposes — and this is where that happens, start to finish.
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
        let runContext = RunContext(
            auth: auth,
            tracer: configuration.tracer,
            progress: progress,
            metadata: metadata
        )

        let assembled = try await configuration.assembler.assemble(
            userPrompt: userPrompt,
            runContext: runContext
        )

        let instantiatedTools = configuration.tools.instantiateAll(
            runContext: runContext,
            policy: configuration.policy
        )

        let modelClient = try ModelClient(
            instructions: assembled.instructions,
            tools: instantiatedTools,
            runContext: runContext,
            model: configuration.model
        )

        let loop = ControlLoop(
            budget: configuration.budget,
            outputVerifier: configuration.outputVerifier,
            generationOptions: configuration.generationOptions
        )

        return try await loop.run(
            prompt: assembled.renderedPrompt(),
            modelClient: modelClient,
            runContext: runContext
        )
    }

    /// The same run with the tokens delivered live. Same gates, no exceptions —
    /// streaming changes what you see, never what gets to pass.
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
        let runContext = RunContext(
            auth: auth,
            tracer: configuration.tracer,
            progress: progress,
            metadata: metadata
        )

        let assembled = try await configuration.assembler.assemble(
            userPrompt: userPrompt,
            runContext: runContext
        )

        let instantiatedTools = configuration.tools.instantiateAll(
            runContext: runContext,
            policy: configuration.policy
        )

        let modelClient = try ModelClient(
            instructions: assembled.instructions,
            tools: instantiatedTools,
            runContext: runContext,
            model: configuration.model
        )

        let loop = StreamingControlLoop(
            budget: configuration.budget,
            outputVerifier: configuration.outputVerifier,
            generationOptions: configuration.generationOptions
        )

        return loop.run(
            prompt: assembled.renderedPrompt(),
            modelClient: modelClient,
            runContext: runContext
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
