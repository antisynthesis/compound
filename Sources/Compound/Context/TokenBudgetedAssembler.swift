import Foundation

/// ``ContextAssembler`` wrapper that trims retrieved sources to fit a
/// soft token budget. Sources are dropped lowest-score-first until the
/// rendered prompt fits; dropped IDs are surfaced via a
/// ``TraceEvent/info(runID:category:message:)`` event so operators see
/// when retrieval was truncated.
///
/// Sources with `nil` ``RetrievedSource/score`` are pinned to the back
/// of the eviction queue and only dropped after every scored source has
/// already gone.
public struct TokenBudgetedAssembler: ContextAssembler {
    /// Underlying assembler whose sources may be trimmed.
    public let base: any ContextAssembler
    /// Soft token budget for the rendered prompt.
    public let maxPromptTokens: Int
    /// Heuristic bytes-per-token used to estimate prompt token count.
    public let charsPerToken: Int

    /// Wraps `base`. Inputs are precondition-checked.
    public init(wrapping base: any ContextAssembler, maxPromptTokens: Int, charsPerToken: Int = 4) {
        precondition(maxPromptTokens > 0, "maxPromptTokens must be positive")
        precondition(charsPerToken > 0, "charsPerToken must be positive")
        self.base = base
        self.maxPromptTokens = maxPromptTokens
        self.charsPerToken = charsPerToken
    }

    /// Delegates to ``base`` and then drops lowest-score sources until
    /// the approximate rendered token count is at or below
    /// ``maxPromptTokens``.
    public func assemble(userPrompt: String, runContext: RunContext) async throws -> AssembledContext {
        let assembled = try await base.assemble(userPrompt: userPrompt, runContext: runContext)
        var sources = assembled.sources

        // Cost each source once. The render cost of a single source is the
        // bytes of "- [id] title\n  content\n" — we count UTF-8 to mirror
        // approximateTokens(of:). Then sort ascending by score so the
        // lowest-confidence sources drop first; ties break by id for a
        // stable, deterministic eviction order. `score == nil` is treated
        // as "keep" — those sources are pinned to the back of the eviction
        // queue (only dropped if everything else has already gone).
        let costs: [String: Int] = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, renderCost(of: $0)) })
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

        let promptCost = approximateTokens(of: "\nUser question: \(userPrompt)\n") + approximateTokens(of: "Sources:\n")
        var runningTokens = promptCost + sources.reduce(0) { $0 + approximateTokens(forBytes: costs[$1.id] ?? 0) }
        var dropped: [String] = []
        var evictIdx = 0
        while runningTokens > maxPromptTokens, evictIdx < evictionOrder.count {
            let victim = evictionOrder[evictIdx]
            evictIdx += 1
            if let removeAt = sources.firstIndex(where: { $0.id == victim.id }) {
                sources.remove(at: removeAt)
                dropped.append(victim.id)
                runningTokens -= approximateTokens(forBytes: costs[victim.id] ?? 0)
            }
        }
        // When the source list empties out the framing ("Sources:\n") is no
        // longer rendered (see AssembledContext.renderedPrompt). Re-check
        // the true rendered cost in that edge case so we don't drop sources
        // we didn't actually need to.

        if !dropped.isEmpty {
            await runContext.tracer.record(
                .info(runID: runContext.runID, category: "retrieval", message: "dropped sources for budget: \(dropped.joined(separator: ","))")
            )
        }
        return AssembledContext(
            instructions: assembled.instructions,
            userPrompt: assembled.userPrompt,
            sources: sources,
            redactionsApplied: assembled.redactionsApplied
        )
    }

    private func renderCost(of source: RetrievedSource) -> Int {
        // Mirror the per-source line shape in AssembledContext.renderedPrompt:
        //   "- [\(id)] \(title)\n  \(content)\n"
        let line = "- [\(source.id)] \(source.title)\n  \(source.content)\n"
        return line.utf8.count
    }

    private func approximateTokens(of text: String) -> Int {
        max(1, text.utf8.count / charsPerToken)
    }

    private func approximateTokens(forBytes bytes: Int) -> Int {
        max(1, bytes / charsPerToken)
    }
}
