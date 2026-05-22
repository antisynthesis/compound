import Foundation

// Context assembly is where you decide what the model is allowed to see:
// instructions, retrieved sources, redacted user input, recent transcript.
// Everything past this point is the model's reality. This is the layer that
// draws the line — the model only ever knows what assembly chose to admit.

/// One unit of retrieved evidence handed to the model. The model proposes
/// against what you put in front of it; this is how you choose what that is.
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

/// Pulls signal out of a sea of irrelevance. Returns ``RetrievedSource``s
/// relevant to a query; implementations are expected to bound the result set
/// by `limit` rather than drown the model in everything they could find.
public protocol Retriever: Sendable {
    /// Retrieves up to `limit` sources for `query`.
    func retrieve(query: String, limit: Int) async throws -> [RetrievedSource]
}

/// Retriever that refuses to ground anything — it returns nothing. The
/// default for runs that must stand on instructions and prompt alone.
public struct EmptyRetriever: Retriever {
    /// Creates an instance.
    public init() {}
    /// Returns an empty list.
    public func retrieve(query _: String, limit _: Int) async throws -> [RetrievedSource] { [] }
}

/// Retriever that hands back a fixed source list and ignores the query
/// entirely. No retrieval, no surprises — a known reality for tests and demos.
public struct StaticRetriever: Retriever {
    private let sources: [RetrievedSource]
    /// Creates a retriever over the supplied static sources.
    public init(_ sources: [RetrievedSource]) { self.sources = sources }
    /// Returns the first `limit` sources unchanged.
    public func retrieve(query _: String, limit: Int) async throws -> [RetrievedSource] {
        Array(sources.prefix(limit))
    }
}

/// The exact reality handed to the model for one run: instructions, the
/// (possibly redacted) user prompt, retrieved evidence, and a record of
/// every redactor that fired so nothing scrubbed leaves without a trace.
public struct AssembledContext: Sendable {
    /// System instructions for the model.
    public var instructions: String
    /// The (post-redaction) user prompt.
    public var userPrompt: String
    /// Retrieved evidence, in selection order.
    public var sources: [RetrievedSource]
    /// Names of every ``Redactor`` whose output differed from its input.
    public var redactionsApplied: [String]

    /// Creates an assembled context.
    public init(instructions: String, userPrompt: String, sources: [RetrievedSource], redactionsApplied: [String]) {
        self.instructions = instructions
        self.userPrompt = userPrompt
        self.sources = sources
        self.redactionsApplied = redactionsApplied
    }

    /// Set of every source identifier in ``sources``. Useful when wiring
    /// citation verifiers.
    public var sourceIDs: Set<String> {
        Set(sources.map(\.id))
    }

    /// Produces the final string passed to the model. When ``sources`` is
    /// non-empty, prepends a "Sources:" block and instructs the model to
    /// annotate factual claims with the source identifier.
    public func renderedPrompt() -> String {
        if sources.isEmpty { return userPrompt }
        var out = "Sources:\n"
        for s in sources {
            out += "- [\(s.id)] \(s.title)\n  \(s.content)\n"
        }
        out += "\n"
        out += "User question: \(userPrompt)\n"
        out += "Annotate every factual claim with a [source-id] taken from the list above."
        return out
    }
}

/// Builds an ``AssembledContext`` for a single run. The model only sees
/// what assembly chose to admit, so this is where governance actually
/// lives — redaction, retrieval, and policy gating, decided on device
/// before a single token reaches the model.
public protocol ContextAssembler: Sendable {
    /// Assembles the working context for `userPrompt` under `runContext`.
    func assemble(userPrompt: String, runContext: RunContext) async throws -> AssembledContext
}

/// The default assembler, in order: scrub the prompt through the
/// ``Redactor`` chain, ask the policy whether what remains is admissible,
/// then ground the model with sources from the configured ``Retriever``.
/// Refusal first, retrieval second.
public struct DefaultContextAssembler: ContextAssembler {
    /// Static system instructions for the model.
    public let baseInstructions: String
    /// Retriever for grounding sources.
    public let retriever: any Retriever
    /// Maximum number of sources to request.
    public let retrievalLimit: Int
    /// Redactors applied to the user prompt in order.
    public let redactors: [any Redactor]
    /// Policy gate that may reject the redacted prompt.
    public let policy: any Policy

    /// Creates a default assembler.
    public init(
        baseInstructions: String,
        retriever: any Retriever = EmptyRetriever(),
        retrievalLimit: Int = 5,
        redactors: [any Redactor] = [],
        policy: any Policy = AllowAll()
    ) {
        self.baseInstructions = baseInstructions
        self.retriever = retriever
        self.retrievalLimit = retrievalLimit
        self.redactors = redactors
        self.policy = policy
    }

    /// Redacts, evaluates policy, retrieves sources, and returns the
    /// assembled context.
    ///
    /// - Throws: ``CompoundError/policyDenied(reason:)`` if the policy
    ///   denies the redacted prompt, or any error thrown by the
    ///   retriever.
    public func assemble(userPrompt: String, runContext: RunContext) async throws -> AssembledContext {
        var working = userPrompt
        var applied: [String] = []
        for r in redactors {
            let next = r.redact(working)
            if next != working {
                applied.append(r.name)
                working = next
            }
        }

        let decision = await policy.evaluate(
            .promptContent(redactedSize: working.utf8.count, classification: nil),
            auth: runContext.auth
        )
        if case .deny(let reason) = decision {
            throw CompoundError.policyDenied(reason: reason)
        }

        let sources = try await retriever.retrieve(query: working, limit: retrievalLimit)

        return AssembledContext(
            instructions: baseInstructions,
            userPrompt: working,
            sources: sources,
            redactionsApplied: applied
        )
    }
}
