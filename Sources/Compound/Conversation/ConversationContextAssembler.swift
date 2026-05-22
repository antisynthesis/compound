import Foundation

/// The art of forgetting on purpose. Compresses the early portion of a
/// conversation when the full history would overflow the model's context
/// window — because a window stuffed to the edges does not remember more,
/// it just loses the middle.
///
/// The assembler decides which slice counts as "earlier"; the
/// summarizer's job is to render that slice into a compact form.
public protocol ConversationSummarizer: Sendable {
    /// Returns a compressed rendering of `messages`.
    func summarize(_ messages: [ConversationMessage]) async throws -> String
}

/// The default ``ConversationSummarizer``, and an honest one: it does not
/// pretend to summarize. It replaces the input with a
/// `"(earlier N turns omitted)"` placeholder and admits the loss. Apps
/// that want true summarization can plug in a ``CompoundSession``-driven
/// summarizer running against the same on-device model.
public struct TruncatingSummarizer: ConversationSummarizer {
    /// Creates an instance.
    public init() {}
    /// Returns the omission placeholder, or an empty string for an
    /// empty input.
    public func summarize(_ messages: [ConversationMessage]) async throws -> String {
        if messages.isEmpty { return "" }
        let n = messages.count
        return "(earlier \(n) turn\(n == 1 ? "" : "s") omitted)\n"
    }
}

/// A ``ContextAssembler`` that gives the model a memory without giving it
/// the whole archive. Folds prior ``ConversationMessage``s into the
/// rendered prompt alongside retrieved sources and redactors, putting a
/// transcript section ahead of the user prompt so the model has turn
/// history. The supplied ``ConversationSummarizer`` compresses the long
/// tail before it overflows the context window and buries what matters.
public struct ConversationContextAssembler: ContextAssembler {
    /// Static system instructions.
    public let baseInstructions: String
    /// Conversation history backing store.
    public let store: any ConversationStore
    /// Retriever for grounding sources.
    public let retriever: any Retriever
    /// Maximum number of sources to request per turn.
    public let retrievalLimit: Int
    /// Redactors applied to the user prompt.
    public let redactors: [any Redactor]
    /// Policy gate consulted for the redacted prompt.
    public let policy: any Policy
    /// Summarizer for the earlier-than-recent slice.
    public let summarizer: any ConversationSummarizer
    /// Number of most-recent messages to include verbatim.
    public let keepRecent: Int

    /// Creates an assembler.
    public init(
        baseInstructions: String,
        store: any ConversationStore,
        retriever: any Retriever = EmptyRetriever(),
        retrievalLimit: Int = 5,
        redactors: [any Redactor] = [],
        policy: any Policy = AllowAll(),
        summarizer: any ConversationSummarizer = TruncatingSummarizer(),
        keepRecent: Int = 12
    ) {
        self.baseInstructions = baseInstructions
        self.store = store
        self.retriever = retriever
        self.retrievalLimit = retrievalLimit
        self.redactors = redactors
        self.policy = policy
        self.summarizer = summarizer
        self.keepRecent = keepRecent
    }

    /// Redacts the user prompt, evaluates policy, summarizes the older
    /// slice of conversation history, and composes a transcript-aware
    /// prompt.
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

        let history = try await store.messages()
        let recent = Array(history.suffix(keepRecent))
        let earlier = Array(history.dropLast(recent.count))
        let summary = try await summarizer.summarize(earlier)

        let sources = try await retriever.retrieve(query: working, limit: retrievalLimit)

        let transcriptBlock = Self.renderTranscript(summary: summary, recent: recent)

        let assembled = AssembledContext(
            instructions: baseInstructions,
            userPrompt: working,
            sources: sources,
            redactionsApplied: applied
        )
        // Render the final prompt as: sources + transcript + new user message.
        // We override renderedPrompt by carrying the transcript in metadata-like
        // form via a custom struct.
        return AssembledContext(
            instructions: baseInstructions,
            userPrompt: Self.compose(transcriptBlock: transcriptBlock, userPrompt: working),
            sources: assembled.sources,
            redactionsApplied: assembled.redactionsApplied
        )
    }

    private static func renderTranscript(summary: String, recent: [ConversationMessage]) -> String {
        if summary.isEmpty && recent.isEmpty { return "" }
        var out = "Conversation so far:\n"
        if !summary.isEmpty { out += summary }
        for m in recent {
            let role: String
            switch m.role {
            case .user: role = "User"
            case .assistant: role = "Assistant"
            case .system: role = "System"
            case .tool: role = "Tool(\(m.metadata["tool"] ?? "unknown"))"
            }
            out += "\(role): \(m.content)\n"
        }
        return out + "\n"
    }

    private static func compose(transcriptBlock: String, userPrompt: String) -> String {
        if transcriptBlock.isEmpty { return userPrompt }
        return transcriptBlock + "New user message: " + userPrompt
    }
}
