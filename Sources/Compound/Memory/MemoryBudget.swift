import Foundation

/// Per-turn token allowance for each of the three memory tiers.
///
/// ## The deflation argument
///
/// Published memory systems inject a lot of prompt: roughly 1.6k tokens
/// of retrieved graph context in one system, and 6.7–7k tokens of
/// recalled memory in another. Both numbers are affordable on a
/// cloud-scale window and *neither is affordable here*. Apple's
/// on-device window is documented at 4096 tokens; a 7k memory block does
/// not fit at all, and a 1.6k one spends 39% of the window before the
/// user's actual task has been described. Memory would then be starving
/// the work it exists to serve.
///
/// So Compound's entire memory share defaults to ~448 tokens — 96 for
/// the pinned core block, 160 for individual facts, 192 for archival
/// rounds — about 11% of the window, leaving the remainder for
/// instructions, retrieved documents, the transcript, and the answer.
/// The claim this layer makes is a cost/latency one, not an
/// accuracy-over-full-context one: at this window size there *is* no
/// full-context alternative to compare against.
///
/// ``transcriptTokens`` is not part of that share. It caps the verbatim
/// recent-message block, which ``MemoryContextAssembler`` trims itself
/// (see its documentation for why ``TokenBudgetedAssembler`` cannot).
///
/// The token fields are soft sub-budgets measured with the assembler's
/// injected ``TokenCounting``; ``maxFacts`` and ``maxArchivalRounds`` are
/// hard count caps applied first, so a pathological single source can
/// never be admitted "because there was room for one".
public struct MemoryBudget: Sendable, Equatable, Codable {
    /// Tokens allowed for the pinned core-memory block's **body**.
    ///
    /// Unlike the other tiers, this caps body text only; the block's
    /// fixed `"core memory (thread …)"` title is overhead outside the
    /// cap. Charging the title would let a small value delete the one
    /// source the design pins as un-evictable — see the note on
    /// `MemoryContextAssembler.renderCoreBlock`. The title is still real
    /// prompt weight and is counted against ``memoryTokens`` by the
    /// memory eval's `budget/default-share-holds` scenario.
    public var coreBlockTokens: Int
    /// Tokens allowed for individually recalled ``Fact`` sources.
    public var factTokens: Int
    /// Tokens allowed for archival round sources.
    public var archivalTokens: Int
    /// Tokens allowed for the verbatim recent-message transcript.
    public var transcriptTokens: Int
    /// Hard cap on recalled facts, applied before the token sub-budget.
    public var maxFacts: Int
    /// Hard cap on archival rounds, applied before the token sub-budget.
    public var maxArchivalRounds: Int

    /// The shipped defaults: 96 / 160 / 192 / 700 tokens, 6 facts, 3
    /// rounds.
    public static let `default` = MemoryBudget()

    /// Creates a budget.
    ///
    /// - Precondition: every token field is positive; `maxFacts` and
    ///   `maxArchivalRounds` are non-negative (zero switches the tier
    ///   off, which is a legitimate configuration).
    public init(
        coreBlockTokens: Int = 96,
        factTokens: Int = 160,
        archivalTokens: Int = 192,
        transcriptTokens: Int = 700,
        maxFacts: Int = 6,
        maxArchivalRounds: Int = 3
    ) {
        precondition(coreBlockTokens > 0, "coreBlockTokens must be positive")
        precondition(factTokens > 0, "factTokens must be positive")
        precondition(archivalTokens > 0, "archivalTokens must be positive")
        precondition(transcriptTokens > 0, "transcriptTokens must be positive")
        precondition(maxFacts >= 0, "maxFacts must be non-negative")
        precondition(maxArchivalRounds >= 0, "maxArchivalRounds must be non-negative")
        self.coreBlockTokens = coreBlockTokens
        self.factTokens = factTokens
        self.archivalTokens = archivalTokens
        self.transcriptTokens = transcriptTokens
        self.maxFacts = maxFacts
        self.maxArchivalRounds = maxArchivalRounds
    }

    /// Total prompt share the three memory tiers may occupy — the ~448
    /// tokens the deflation argument above is about. Excludes
    /// ``transcriptTokens``, which pays for conversation, not memory.
    ///
    /// This is the sum of the three sub-budgets. Source titles are
    /// charged inside ``factTokens`` and ``archivalTokens`` but not
    /// inside ``coreBlockTokens``, so the realized share exceeds this by
    /// the core title's fixed width (~7 tokens under a heuristic
    /// counter). The eval measures the realized, title-inclusive share
    /// against this number rather than assuming they match.
    public var memoryTokens: Int {
        coreBlockTokens + factTokens + archivalTokens
    }
}
