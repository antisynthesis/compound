import Foundation

/// Strategy for compressing the early portion of a conversation when
/// the full history would overflow the model's context window.
///
/// The assembler decides which slice counts as "earlier"; the
/// summarizer's job is to render that slice into a compact form.
public protocol ConversationSummarizer: Sendable {
    /// Returns a compressed rendering of `messages`.
    func summarize(_ messages: [ConversationMessage]) async throws -> String
}

/// Default ``ConversationSummarizer``. Replaces the input with a
/// `"(earlier N turns omitted)"` placeholder. Apps that want true
/// summarization can plug in a ``CompoundSession``-driven summarizer
/// running against the same on-device model.
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

/// ``ContextAssembler`` that folds prior ``ConversationMessage``s into
/// the rendered prompt alongside retrieved sources and redactors. The
/// default rendering puts a transcript section ahead of the user
/// prompt so the model has turn history; the supplied
/// ``ConversationSummarizer`` compresses long conversations before they
/// overflow the model's context window.
public struct ConversationContextAssembler: ContextAssembler {
    /// Static system instructions.
    public let baseInstructions: String
    /// Conversation history backing store.
    public let store: any ConversationStore
    /// Retriever for grounding sources.
    public let retriever: any Retriever
    /// Maximum number of sources to request per turn.
    public let retrievalLimit: Int
    /// Redactors applied, in order, to every input in ``redactionScope``.
    public let redactors: [any Redactor]
    /// Which inputs the redactor chain runs over.
    public let redactionScope: RedactionScope
    /// Policy gate consulted for the redacted prompt.
    public let policy: any Policy
    /// Summarizer for the earlier-than-recent slice.
    public let summarizer: any ConversationSummarizer
    /// Number of most-recent messages to include verbatim.
    public let keepRecent: Int
    /// Frame used to render the final prompt.
    public let framing: any PromptFraming

    /// Creates an assembler.
    public init(
        baseInstructions: String,
        store: any ConversationStore,
        retriever: any Retriever = EmptyRetriever(),
        retrievalLimit: Int = 5,
        redactors: [any Redactor] = [],
        redactionScope: RedactionScope = .all,
        policy: any Policy = AllowAll(),
        summarizer: any ConversationSummarizer = TruncatingSummarizer(),
        keepRecent: Int = 12,
        framing: any PromptFraming = PromptFrame()
    ) {
        self.baseInstructions = baseInstructions
        self.store = store
        self.retriever = retriever
        self.retrievalLimit = retrievalLimit
        self.redactors = redactors
        self.redactionScope = redactionScope
        self.policy = policy
        self.summarizer = summarizer
        self.keepRecent = keepRecent
        self.framing = framing
    }

    /// Redacts the user prompt, evaluates policy, summarizes the older
    /// slice of conversation history (redacting stored messages before
    /// they reach the summarizer when history is in scope), and returns
    /// a context whose ``AssembledContext/transcript`` carries the
    /// structured history for the frame to fence at render time.
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

        let history = try await store.messages()
        var recent = Array(history.suffix(keepRecent))
        var earlier = Array(history.dropLast(recent.count))
        if redactionScope.contains(.history) {
            recent = recent.map { redacted($0, applied: &applied) }
            earlier = earlier.map { redacted($0, applied: &applied) }
        }
        var summary = try await summarizer.summarize(earlier)
        if redactionScope.contains(.history) {
            // Defense in depth: the summarizer saw redacted input, but a
            // model-backed summarizer could still emit secret-shaped text.
            summary = runRedactors(redactors, on: summary, applied: &applied)
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
            transcript: PromptTranscript(summary: summary, messages: recent),
            framing: framing
        )
    }

    /// Returns `message` with its content run through the redactor chain.
    private func redacted(_ message: ConversationMessage, applied: inout [String]) -> ConversationMessage {
        ConversationMessage(
            id: message.id,
            role: message.role,
            content: runRedactors(redactors, on: message.content, applied: &applied),
            createdAt: message.createdAt,
            metadata: message.metadata
        )
    }
}
