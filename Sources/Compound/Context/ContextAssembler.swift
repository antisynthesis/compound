import Foundation

// Context assembly is where the model's working context is constructed:
// instructions, retrieved sources, redacted user input, recent transcript.
// This is the layer in which most enterprise governance lives — the model
// only sees what assembly chose to admit.

/// One unit of retrieved evidence supplied to the model.
public struct RetrievedSource: Sendable, Equatable, Hashable {
    /// Stable identifier the model is required to cite by reference.
    public let id: String
    /// Human-readable title.
    public let title: String
    /// Source body text.
    public let content: String
    /// Optional relevance score from the originating retriever.
    public let score: Double?

    /// Creates a retrieved source.
    public init(id: String, title: String, content: String, score: Double? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.score = score
    }
}

/// Returns ``RetrievedSource``s relevant to a query. Implementations are
/// expected to bound the result set by `limit`.
public protocol Retriever: Sendable {
    /// Retrieves up to `limit` sources for `query`.
    func retrieve(query: String, limit: Int) async throws -> [RetrievedSource]
}

/// Retriever that always returns no sources.
public struct EmptyRetriever: Retriever {
    /// Creates an instance.
    public init() {}
    /// Returns an empty list.
    public func retrieve(query _: String, limit _: Int) async throws -> [RetrievedSource] { [] }
}

/// Retriever that returns a prefix of a fixed source list, ignoring the
/// query. Useful for tests and demos.
public struct StaticRetriever: Retriever {
    private let sources: [RetrievedSource]
    /// Creates a retriever over the supplied static sources.
    public init(_ sources: [RetrievedSource]) { self.sources = sources }
    /// Returns the first `limit` sources unchanged.
    public func retrieve(query _: String, limit: Int) async throws -> [RetrievedSource] {
        Array(sources.prefix(limit))
    }
}

/// Result of running a ``ContextAssembler``. Bundles the instructions,
/// the (possibly redacted) user prompt, retrieved evidence, prior
/// conversation, and a list of redactor names that fired so callers can
/// attribute scrubbing.
public struct AssembledContext: Sendable {
    /// System instructions for the model.
    public var instructions: String
    /// The (post-redaction) user prompt.
    public var userPrompt: String
    /// Retrieved evidence, in selection order.
    public var sources: [RetrievedSource]
    /// Names of every ``Redactor`` whose output differed from its input.
    public var redactionsApplied: [String]
    /// Prior conversation to render ahead of the user prompt, if any.
    public var transcript: PromptTranscript?
    /// Frame that renders this context into the final prompt string.
    public var framing: any PromptFraming

    /// Creates an assembled context.
    public init(
        instructions: String,
        userPrompt: String,
        sources: [RetrievedSource],
        redactionsApplied: [String],
        transcript: PromptTranscript? = nil,
        framing: any PromptFraming = PromptFrame()
    ) {
        self.instructions = instructions
        self.userPrompt = userPrompt
        self.sources = sources
        self.redactionsApplied = redactionsApplied
        self.transcript = transcript
        self.framing = framing
    }

    /// Set of every source identifier in ``sources``. Useful when wiring
    /// citation verifiers.
    public var sourceIDs: Set<String> {
        Set(sources.map(\.id))
    }

    /// Produces the final string passed to the model by delegating to
    /// ``framing``. The default ``PromptFrame`` fences sources and
    /// transcript messages so their content cannot parse as prompt
    /// structure, and instructs the model to cite source identifiers
    /// when sources are present.
    public func renderedPrompt() -> String {
        framing.render(sources: sources, transcript: transcript, userPrompt: userPrompt)
    }
}

/// Builds an ``AssembledContext`` for a single run. The model only sees
/// what assembly chose to admit — this is where most enterprise
/// governance (redaction, retrieval, policy gating) lives.
public protocol ContextAssembler: Sendable {
    /// Assembles the working context for `userPrompt` under `runContext`.
    func assemble(userPrompt: String, runContext: RunContext) async throws -> AssembledContext
}

/// Default assembler. Runs the supplied ``Redactor`` chain over every
/// input admitted by ``redactionScope`` (user prompt and retrieved
/// sources by default), asks the policy whether the resulting content is
/// admissible, and retrieves grounding sources via the configured
/// ``Retriever``.
public struct DefaultContextAssembler: ContextAssembler {
    /// Static system instructions for the model.
    public let baseInstructions: String
    /// Retriever for grounding sources.
    public let retriever: any Retriever
    /// Maximum number of sources to request.
    public let retrievalLimit: Int
    /// Redactors applied, in order, to every input in ``redactionScope``.
    public let redactors: [any Redactor]
    /// Which inputs the redactor chain runs over.
    public let redactionScope: RedactionScope
    /// Policy gate that may reject the redacted prompt.
    public let policy: any Policy
    /// Frame used to render the final prompt.
    public let framing: any PromptFraming

    /// Creates a default assembler.
    public init(
        baseInstructions: String,
        retriever: any Retriever = EmptyRetriever(),
        retrievalLimit: Int = 5,
        redactors: [any Redactor] = [],
        redactionScope: RedactionScope = .all,
        policy: any Policy = AllowAll(),
        framing: any PromptFraming = PromptFrame()
    ) {
        self.baseInstructions = baseInstructions
        self.retriever = retriever
        self.retrievalLimit = retrievalLimit
        self.redactors = redactors
        self.redactionScope = redactionScope
        self.policy = policy
        self.framing = framing
    }

    /// Redacts, evaluates policy, retrieves sources (redacting their
    /// titles and bodies when in scope), and returns the assembled
    /// context.
    ///
    /// - Throws: ``CompoundError/policyDenied(reason:)`` if the policy
    ///   denies the redacted prompt, or any error thrown by the
    ///   retriever.
    public func assemble(userPrompt: String, runContext: RunContext) async throws -> AssembledContext {
        var applied: [String] = []
        var working = userPrompt
        if redactionScope.contains(.userPrompt) {
            working = runRedactors(redactors, on: working, applied: &applied)
        }

        let decision = await policy.evaluate(
            .promptContent(redactedSize: working.utf8.count, classification: nil),
            auth: runContext.auth
        )
        if case .deny(let reason) = decision {
            throw CompoundError.policyDenied(reason: reason)
        }

        var sources = try await retriever.retrieve(query: working, limit: retrievalLimit)
        if redactionScope.contains(.retrievedSources) {
            sources = sources.map { s in
                RetrievedSource(
                    id: s.id,
                    title: runRedactors(redactors, on: s.title, applied: &applied),
                    content: runRedactors(redactors, on: s.content, applied: &applied),
                    score: s.score
                )
            }
        }

        return AssembledContext(
            instructions: baseInstructions,
            userPrompt: working,
            sources: sources,
            redactionsApplied: applied,
            transcript: nil,
            framing: framing
        )
    }
}
