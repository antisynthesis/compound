import Foundation

/// ``ContextAssembler`` wrapper that trims retrieved sources to fit a
/// soft token budget. Sources are dropped lowest-score-first until the
/// rendered prompt — measured through the context's own ``PromptFraming``
/// and charged together with the system instructions — fits; dropped IDs
/// are surfaced via a ``TraceEvent/info(runID:category:message:)`` event
/// so operators see when retrieval was truncated.
///
/// Sources with `nil` ``RetrievedSource/score`` are pinned to the back
/// of the eviction queue and only dropped after every scored source has
/// already gone.
///
/// Costing is exact by construction: every check renders the candidate
/// source set through ``AssembledContext/framing`` and counts the result
/// with the injected ``TokenCounting`` counter, so the budget math cannot
/// drift from what ``AssembledContext/renderedPrompt()`` actually sends
/// (including the framing overhead that disappears when the source list
/// empties out — the re-check the previous implementation only promised).
public struct TokenBudgetedAssembler: ContextAssembler {
    /// Underlying assembler whose sources may be trimmed.
    public let base: any ContextAssembler
    /// Soft token budget for the rendered prompt plus instructions.
    public let maxPromptTokens: Int
    /// Heuristic bytes-per-token used when no counter is injected.
    public let charsPerToken: Int
    /// Counter used to measure instructions and the rendered prompt.
    /// Defaults to ``HeuristicTokenCounter`` over ``charsPerToken`` so
    /// behavior is unchanged until a real counter is injected.
    public let counter: any TokenCounting

    /// Wraps `base`. Inputs are precondition-checked.
    public init(
        wrapping base: any ContextAssembler,
        maxPromptTokens: Int,
        charsPerToken: Int = 4,
        counter: (any TokenCounting)? = nil
    ) {
        precondition(maxPromptTokens > 0, "maxPromptTokens must be positive")
        precondition(charsPerToken > 0, "charsPerToken must be positive")
        self.base = base
        self.maxPromptTokens = maxPromptTokens
        self.charsPerToken = charsPerToken
        self.counter = counter ?? HeuristicTokenCounter(charsPerToken: charsPerToken)
    }

    /// Delegates to ``base`` and then drops lowest-score sources until
    /// instructions + rendered prompt fit ``maxPromptTokens``. Transcript,
    /// framing, and every other field of the assembled context pass
    /// through untouched.
    public func assemble(userPrompt: String, runContext: RunContext) async throws -> AssembledContext {
        let assembled = try await base.assemble(userPrompt: userPrompt, runContext: runContext)
        let sources = assembled.sources

        // Instructions occupy the same context window as the prompt, so
        // they debit the same budget.
        let instructionTokens = assembled.instructions.isEmpty
            ? 0
            : await counter.count(assembled.instructions)

        var total = instructionTokens + (await renderedTokens(of: sources, in: assembled))
        if total <= maxPromptTokens {
            return assembled
        }

        // Sort ascending by score so the lowest-confidence sources drop
        // first; ties break by id for a stable, deterministic eviction
        // order. `score == nil` is treated as "keep" — those sources are
        // pinned to the back of the eviction queue (only dropped if
        // everything else has already gone).
        let evictionOrder = sources.sorted { a, b in
            switch (a.score, b.score) {
            case let (sa?, sb?):
                if sa != sb { return sa < sb }
                return a.id < b.id
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                return a.id < b.id
            }
        }

        // Index map keyed by id (first occurrence wins) so each eviction
        // is an O(1) flag flip instead of a linear scan + remove.
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(sources.count)
        for (index, source) in sources.enumerated() where indexByID[source.id] == nil {
            indexByID[source.id] = index
        }
        var keep = [Bool](repeating: true, count: sources.count)
        func keptSources() -> [RetrievedSource] {
            zip(sources, keep).compactMap { source, kept in kept ? source : nil }
        }

        // Evict until the *actual* rendered cost fits. Re-rendering per
        // eviction keeps the check exact — it charges the framing overhead
        // correctly, including the edge where the emptied source list
        // stops rendering any source framing at all, so a source is never
        // dropped that did not need to go.
        var dropped: [String] = []
        var evictIdx = 0
        while total > maxPromptTokens, evictIdx < evictionOrder.count {
            let victim = evictionOrder[evictIdx]
            evictIdx += 1
            guard let index = indexByID[victim.id], keep[index] else { continue }
            keep[index] = false
            dropped.append(victim.id)
            total = instructionTokens + (await renderedTokens(of: keptSources(), in: assembled))
        }

        if !dropped.isEmpty {
            await runContext.tracer.record(
                .info(
                    runID: runContext.runID,
                    category: "retrieval",
                    message: "dropped sources for budget: \(dropped.joined(separator: ","))"
                )
            )
        }
        if total > maxPromptTokens {
            // Soft budget: with every source gone, instructions + prompt
            // still exceed the cap. Surface it and proceed — trimming the
            // user's own prompt is not this wrapper's call to make.
            await runContext.tracer.record(
                .info(
                    runID: runContext.runID,
                    category: "retrieval",
                    message: "prompt exceeds token budget after dropping all sources: \(total) > \(maxPromptTokens)"
                )
            )
        }

        var trimmed = assembled
        trimmed.sources = keptSources()
        return trimmed
    }

    /// Cost of the prompt as it will really render: the shared framing is
    /// the single source of the format, so this cannot drift from
    /// ``AssembledContext/renderedPrompt()``.
    private func renderedTokens(of sources: [RetrievedSource], in assembled: AssembledContext) async -> Int {
        let rendered = assembled.framing.render(
            sources: sources,
            transcript: assembled.transcript,
            userPrompt: assembled.userPrompt
        )
        return await counter.count(rendered)
    }
}
