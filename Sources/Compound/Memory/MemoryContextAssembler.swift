import Foundation

/// ``ContextAssembler`` that folds two-tier memory — structured ``Fact``
/// records and archived transcript rounds — into the working context
/// alongside conversation history and retrieved documents.
///
/// ## Zero model calls
///
/// Nothing on this path calls a language model. Recall is a store query
/// plus a deterministic ranking; archival retrieval is BM25/dense
/// retrieval through the existing retrievers; the core block is a
/// rendering. The model-backed hooks in the memory layer live on the
/// *write* path (span selection and mutation routing), which is where the
/// published lift for small models actually is. A read path that called a
/// model would spend the latency budget memory exists to save.
///
/// ## Composition, not appending
///
/// This type owns the whole `assemble()` rather than decorating another
/// assembler's output. That is the composition rule stated on
/// ``IterativeRetrievalAssembler``: content appended to a context another
/// assembler already returned would route around exactly the redaction
/// pass it needs. Everything admitted here — core block, facts, archival
/// rounds, documents — is concatenated first and then run through a
/// single ``RedactionScope/retrievedSources`` pass, and everything
/// reaches the model through `sources` or `transcript`, so
/// ``PromptFrame``'s fencing applies to a remembered fact exactly as it
/// applies to a retrieved document.
///
/// ## Order and score semantics
///
/// Sources are emitted in a fixed order: core block, facts by descending
/// salience, archival hits in reader order, then document sources. The
/// scores are chosen so that ``TokenBudgetedAssembler``'s eviction does
/// the right thing without anyone fudging numbers to game it:
///
/// - the core block carries `nil` — the documented evict-last pin;
/// - facts carry salience normalized to `[0, 1]`;
/// - archival hits carry the reader's own fused score;
/// - document sources pass through untouched.
///
/// The consequence is explicit and intended: under budget pressure
/// individual facts are evicted before high-scoring documents. Memory is
/// a cost mechanism; the document is the task.
///
/// ## Determinism
///
/// `clock()` is read exactly once per `assemble` and reused for the
/// store query, the ranking, and liveness, so one assembly is internally
/// consistent and an eval with an injected clock replays byte for byte.
public struct MemoryContextAssembler: ContextAssembler {
    /// Static system instructions.
    public let baseInstructions: String
    /// Conversation history backing store.
    public let conversation: any ConversationStore
    /// Tier-1 fact store.
    public let memory: any MemoryStore
    /// Tier-2 archive. `nil` disables archival recall entirely.
    public let archive: (any ArchivalStore)?
    /// Tag identifying facts that belong in the pinned core block.
    /// `nil` disables the block.
    public let coreBlockFactTag: String?
    /// Retriever for document grounding sources.
    public let retriever: any Retriever
    /// Maximum number of document sources to request.
    public let retrievalLimit: Int
    /// Ranking function for recalled facts.
    public let scorer: SalienceScorer
    /// Per-tier token allowances.
    public let budget: MemoryBudget
    /// Redactors applied, in order, to every input in ``redactionScope``.
    public let redactors: [any Redactor]
    /// Which inputs the redactor chain runs over.
    public let redactionScope: RedactionScope
    /// Policy gate consulted for the redacted prompt.
    public let policy: any Policy
    /// Summarizer for the earlier-than-recent slice of history.
    public let summarizer: any ConversationSummarizer
    /// Number of most-recent messages included verbatim.
    public let keepRecent: Int
    /// Frame used to render the final prompt.
    public let framing: any PromptFraming
    /// `RunContext.metadata` key carrying the thread id.
    public let threadIDMetadataKey: String
    /// Counter used to hold the per-tier sub-budgets.
    public let counter: any TokenCounting
    /// Clock, read once per assembly.
    public let clock: @Sendable () -> Date

    /// How many core-tagged facts are fetched as render candidates. The
    /// block's character and token caps do the real trimming; this only
    /// bounds the query.
    static let coreBlockCandidateLimit = 32
    /// Over-fetch multiplier for the fact query: salience at the store
    /// boundary has no query relevance term, so the assembler asks for
    /// more than it will keep and re-ranks with relevance in hand.
    static let factOverfetch = 4

    /// Creates a memory-aware assembler.
    public init(
        baseInstructions: String,
        conversation: any ConversationStore,
        memory: any MemoryStore,
        archive: (any ArchivalStore)? = nil,
        coreBlockFactTag: String? = "core",
        retriever: any Retriever = EmptyRetriever(),
        retrievalLimit: Int = 5,
        scorer: SalienceScorer = SalienceScorer(),
        budget: MemoryBudget = .default,
        redactors: [any Redactor] = [],
        redactionScope: RedactionScope = .all,
        policy: any Policy = AllowAll(),
        summarizer: any ConversationSummarizer = TruncatingSummarizer(),
        keepRecent: Int = 8,
        framing: any PromptFraming = PromptFrame(),
        threadIDMetadataKey: String = MemorySessionConfiguration.defaultThreadIDMetadataKey,
        counter: any TokenCounting = HeuristicTokenCounter(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(retrievalLimit >= 0, "retrievalLimit must be non-negative")
        precondition(keepRecent >= 0, "keepRecent must be non-negative")
        self.baseInstructions = baseInstructions
        self.conversation = conversation
        self.memory = memory
        self.archive = archive
        self.coreBlockFactTag = coreBlockFactTag
        self.retriever = retriever
        self.retrievalLimit = retrievalLimit
        self.scorer = scorer
        self.budget = budget
        self.redactors = redactors
        self.redactionScope = redactionScope
        self.policy = policy
        self.summarizer = summarizer
        self.keepRecent = keepRecent
        self.framing = framing
        self.threadIDMetadataKey = threadIDMetadataKey
        self.counter = counter
        self.clock = clock
    }

    /// Assembles the working context.
    ///
    /// The step order mirrors ``ConversationContextAssembler`` so the two
    /// can be audited side by side: redact, gate, read history,
    /// summarize, recall, retrieve, order, redact everything admitted,
    /// trim the transcript, return.
    ///
    /// - Throws: ``CompoundError/policyDenied(reason:)`` when the policy
    ///   denies the redacted prompt — *before* any memory store is read,
    ///   so a denied turn leaves no access trail — or any error thrown by
    ///   the fact store, the conversation store, the summarizer, or the
    ///   document retriever. A throwing **archive** is the one exception:
    ///   it degrades to zero archival sources rather than failing the
    ///   turn, because bulk transcript recall is an enhancement and the
    ///   user asked a question.
    public func assemble(userPrompt: String, runContext: RunContext) async throws -> AssembledContext {
        var applied: [String] = []

        // 1. Redact the incoming prompt.
        var working = userPrompt
        if redactionScope.contains(.userPrompt) {
            working = runRedactors(redactors, on: working, applied: &applied)
        }

        // 2. Gate. Deliberately ahead of every store read.
        let decision = await policy.evaluate(
            .promptContent(redactedSize: working.utf8.count, classification: nil),
            auth: runContext.auth
        )
        if case .deny(let reason) = decision {
            throw CompoundError.policyDenied(reason: reason)
        }

        // 3. Thread scope rides in run metadata; ConversationStore has no
        //    thread concept and is not extended to gain one.
        let threadID = MemorySessionConfiguration.threadID(
            in: runContext.metadata,
            key: threadIDMetadataKey
        )

        // 4. One clock read for the whole assembly.
        let now = clock()

        // 5. History: recent verbatim, earlier summarized.
        let history = try await conversation.messages()
        var recent = Array(history.suffix(keepRecent))
        var earlier = Array(history.dropLast(recent.count))
        if redactionScope.contains(.history) {
            recent = recent.map { redacted($0, applied: &applied) }
            earlier = earlier.map { redacted($0, applied: &applied) }
        }
        var summary = try await summarizer.summarize(earlier)
        if redactionScope.contains(.history) {
            // Defense in depth: the summarizer saw redacted input, but a
            // model-backed summarizer can still emit secret-shaped text.
            summary = runRedactors(redactors, on: summary, applied: &applied)
        }

        // 6. Core block first, so the facts step can skip what the block
        //    already shows rather than paying for it twice.
        let coreBlock = try await renderCoreBlock(threadID: threadID, now: now)

        // 7. Facts, re-ranked with real query relevance.
        let facts = try await recallFacts(
            query: working,
            threadID: threadID,
            now: now,
            excluding: coreBlock.factIDs
        )

        // 8. Archival rounds. A failing archive is degraded, not fatal.
        let archival = await recallArchival(
            query: working,
            threadID: threadID,
            runContext: runContext
        )

        // 9. Documents.
        let documents = retrievalLimit > 0
            ? try await retriever.retrieve(query: working, limit: retrievalLimit)
            : []

        // 10. Fixed order, each memory tier fitted to its own sub-budget.
        var sources: [RetrievedSource] = []
        if let block = coreBlock.block {
            sources.append(block.retrievedSource)
        }
        sources += await fit(facts, toTokens: budget.factTokens)
        sources += await fit(archival, toTokens: budget.archivalTokens)
        sources += documents

        // 11. One redaction pass over everything admitted, titles and
        //     bodies alike — the pass that makes stored memory as safe as
        //     a retrieved document, since it is the same pass.
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

        // 12. Trim the transcript here, because nothing downstream will.
        //     TokenBudgetedAssembler evicts sources only: an oversized
        //     transcript would be charged against the prompt budget, be
        //     untrimmable, starve retrieval completely, and then merely
        //     log that the prompt still does not fit.
        recent = await trimTranscript(recent, summary: summary)

        return AssembledContext(
            instructions: baseInstructions,
            userPrompt: working,
            sources: sources,
            redactionsApplied: applied,
            transcript: PromptTranscript(summary: summary, messages: recent),
            framing: framing
        )
    }

    // MARK: - Core block

    /// A rendered core block plus the ids of the facts it actually shows.
    private struct CoreBlockResult {
        var block: CoreMemoryBlock?
        var factIDs: Set<String>
    }

    /// Renders the pinned block from core-tagged live facts, holding both
    /// the character cap and ``MemoryBudget/coreBlockTokens``.
    ///
    /// Lines are added one at a time and measured with the injected
    /// counter, so the block never exceeds its share and never ends
    /// mid-fact.
    ///
    /// ASYMMETRY, DELIBERATE: this is the one tier measured on its *body*
    /// alone. Facts, archival rounds, and documents are fitted on
    /// ``costText(of:)`` (title plus body) because their titles vary with
    /// content — an archival title carries thread, ordinal, and
    /// timestamp. The core block's title is a fixed string, so charging
    /// it would only subtract a constant from the cap, expressible by
    /// lowering the default instead.
    ///
    /// Charging it was tried and rejected, because it breaks the pin.
    /// Under a one-character-per-token counter the title costs 29 and the
    /// first fact line 23, so a starved `coreBlockTokens` of 40 admits no
    /// lines at all and the block disappears — and the core block is
    /// precisely the thing this design guarantees survives budget
    /// pressure (``CoreMemoryBlock/retrievedSource`` pins it with
    /// `score: nil`). A cap that deletes the un-evictable source is worse
    /// than a cap that undercounts a constant.
    ///
    /// The title is therefore fixed overhead outside this sub-budget but
    /// inside the advertised total: the memory eval's
    /// `budget/default-share-holds` scenario asserts the whole share
    /// title-inclusive against ``MemoryBudget/memoryTokens``, so the
    /// number the design argues for is measured, not assumed.
    private func renderCoreBlock(threadID: String, now: Date) async throws -> CoreBlockResult {
        guard let tag = coreBlockFactTag else { return CoreBlockResult(block: nil, factIDs: []) }
        let candidates = try await memory.query(MemoryQuery(
            now: now,
            threadID: threadID,
            tagsAny: [tag],
            includeInvalidated: false,
            limit: Self.coreBlockCandidateLimit,
            order: .salience
        ))
        guard !candidates.isEmpty else { return CoreBlockResult(block: nil, factIDs: []) }

        var text = ""
        var ids: Set<String> = []
        for fact in CoreMemoryBlock.ordered(candidates) {
            let candidate = CoreMemoryBlock.appending(CoreMemoryBlock.line(for: fact), to: text)
            if candidate.count > CoreMemoryBlock.defaultMaxCharacters { break }
            if await counter.count(candidate) > budget.coreBlockTokens { break }
            text = candidate
            ids.insert(fact.id)
        }
        guard !text.isEmpty else { return CoreBlockResult(block: nil, factIDs: []) }
        return CoreBlockResult(block: CoreMemoryBlock(threadID: threadID, text: text), factIDs: ids)
    }

    // MARK: - Facts

    /// Queries live facts for the thread, re-ranks them against the
    /// query, and returns at most ``MemoryBudget/maxFacts`` sources.
    ///
    /// The store's own `.salience` order has no relevance term — it
    /// cannot, since the store never sees the query — so the read is an
    /// over-fetch and the ranking that matters happens here, with
    /// relevance computed deterministically from
    /// ``BM25Retriever/defaultTokenize`` overlap. No embeddings, no model.
    private func recallFacts(
        query: String,
        threadID: String,
        now: Date,
        excluding: Set<String>
    ) async throws -> [RetrievedSource] {
        guard budget.maxFacts > 0 else { return [] }
        let candidates = try await memory.query(MemoryQuery(
            now: now,
            threadID: threadID,
            includeInvalidated: false,
            limit: budget.maxFacts * Self.factOverfetch,
            order: .salience
        )).filter { !excluding.contains($0.id) }
        guard !candidates.isEmpty else { return [] }

        let queryTokens = Set(BM25Retriever.defaultTokenize(query))
        var relevance: [String: Double] = [:]
        for fact in candidates {
            relevance[fact.id] = Self.overlap(queryTokens: queryTokens, text: fact.text)
        }
        let scored = scorer.score(candidates, relevance: relevance, now: now)
        let weightTotal = scorer.weights.recency + scorer.weights.importance + scorer.weights.relevance
        return scored.prefix(budget.maxFacts).map { entry in
            Self.source(for: entry, weightTotal: weightTotal)
        }
    }

    /// Fraction of the query's distinct tokens that occur in `text`.
    ///
    /// A ratio rather than a raw count so a long fact cannot outrank a
    /// short one merely by containing more words, and normalized by the
    /// *query* so the value stays comparable across facts of different
    /// lengths. Empty queries score zero for everything, which leaves the
    /// ranking to recency and importance — the right answer when the user
    /// gave nothing to match on.
    static func overlap(queryTokens: Set<String>, text: String) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        let factTokens = Set(BM25Retriever.defaultTokenize(text))
        guard !factTokens.isEmpty else { return 0 }
        let hits = queryTokens.intersection(factTokens).count
        return Double(hits) / Double(queryTokens.count)
    }

    /// Renders a scored fact as evidence.
    ///
    /// The score is the weighted salience sum divided by the total weight,
    /// which lands it in `[0, 1]` because every component is already
    /// min-max normalized across the candidate set. Provenance — subject,
    /// predicate, validity instant, origin — rides in the title, escaped
    /// as an attribute by ``PromptFrame``.
    static func source(for entry: ScoredFact, weightTotal: Double) -> RetrievedSource {
        let formatter = ISO8601DateFormatter()
        let normalized = weightTotal > 0 ? entry.score / weightTotal : 0
        return RetrievedSource(
            id: entry.fact.id,
            title: "fact \(entry.fact.subject) \(entry.fact.predicate)"
                + " [\(formatter.string(from: entry.fact.validFrom))]"
                + " origin=\(entry.fact.origin.rawValue)",
            content: entry.fact.text,
            score: min(1, max(0, normalized))
        )
    }

    // MARK: - Archival

    /// Retrieves archival rounds, degrading to none on failure.
    private func recallArchival(
        query: String,
        threadID: String,
        runContext: RunContext
    ) async -> [RetrievedSource] {
        guard let archive, budget.maxArchivalRounds > 0 else { return [] }
        do {
            let hits = try await archive.retrieve(
                query: query,
                limit: budget.maxArchivalRounds,
                threadID: threadID
            )
            return hits.map(\.retrievedSource)
        } catch {
            // Uses the `MemoryTrace` grammar so every memory `.info` line
            // in the package scrapes the same way. The error is reported
            // by *type*, never by message: an error thrown out of the
            // archive can quote archived user content, and a diagnostic
            // line is not a place to leak it. The type name is also
            // space-free, which the grammar requires.
            await runContext.tracer.record(
                .info(
                    runID: runContext.runID,
                    category: MemoryTrace.category,
                    message: MemoryTrace.message(event: "archive_degraded", [
                        ("thread", threadID),
                        ("sources", "0"),
                        ("error", String(describing: type(of: error)))
                    ])
                )
            )
            return []
        }
    }

    // MARK: - Budget fitting

    /// Drops the lowest-ranked members of one tier until the tier fits
    /// `maxTokens`.
    ///
    /// Input is already in rank order, so eviction is from the tail. The
    /// measurement charges each source's own title and body; the framing
    /// overhead around them is ``TokenBudgetedAssembler``'s business,
    /// which measures the real rendering exactly. Splitting the two
    /// keeps this a per-tier fairness rule rather than a second,
    /// competing whole-prompt budget.
    private func fit(_ sources: [RetrievedSource], toTokens maxTokens: Int) async -> [RetrievedSource] {
        guard !sources.isEmpty else { return [] }
        var costs: [Int] = []
        costs.reserveCapacity(sources.count)
        for source in sources {
            costs.append(await counter.count(Self.costText(of: source)))
        }
        var total = costs.reduce(0, +)
        var keep = sources.count
        while keep > 0, total > maxTokens {
            keep -= 1
            total -= costs[keep]
        }
        return Array(sources.prefix(keep))
    }

    /// The text a source is charged for: its title and body, joined the
    /// way the frame will join them.
    static func costText(of source: RetrievedSource) -> String {
        source.title.isEmpty ? source.content : source.title + "\n" + source.content
    }

    // MARK: - Transcript

    /// Drops the oldest recent messages until the transcript fits
    /// ``MemoryBudget/transcriptTokens``.
    ///
    /// The summary is never trimmed: it is already the compressed form of
    /// everything older, and cutting into it would silently discard more
    /// history per token than dropping a verbatim message does.
    private func trimTranscript(
        _ messages: [ConversationMessage],
        summary: String
    ) async -> [ConversationMessage] {
        var kept = messages
        while !kept.isEmpty,
              await counter.count(Self.transcriptText(summary: summary, messages: kept)) > budget.transcriptTokens {
            kept.removeFirst()
        }
        return kept
    }

    /// Plain-text rendering used only for measuring the transcript.
    static func transcriptText(summary: String, messages: [ConversationMessage]) -> String {
        var parts: [String] = []
        if !summary.isEmpty { parts.append(summary) }
        parts += messages.map { "\($0.role.rawValue): \($0.content)" }
        return parts.joined(separator: "\n")
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
