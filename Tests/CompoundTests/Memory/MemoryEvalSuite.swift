import Foundation
@testable import Compound

// The memory eval suite: three measurements over one deterministic corpus.
//
//   1. Recall and forgetting — `MemoryEvalSuite`, graded by the ForgetEval
//      set predicate and gated against Evals/memory-baseline.json.
//   2. Archival retrieval accuracy — `RetrievalEvalCase`s keyed by
//      DocumentChunker ids, run through the existing `RetrievalEvalRunner`
//      for recall@k / nDCG@k / MRR. Zero new metric code.
//   3. Token-budget adherence under memory pressure — a small `EvalSuite`
//      run through the existing `EvalRunner`/`EvalPredicate` path.
//
// The three are separate on purpose. Recall is measured with a loosened
// budget, because a recall number computed under a starved budget measures
// eviction; adherence is measured under the shipping defaults, because a
// budget number computed under a loose budget measures nothing.

enum MemoryEvalCases {

    /// Suite name; also the `suiteName` recorded in the baseline.
    static let suiteName = "compound-memory"

    // MARK: - Forgetting families

    /// A superseding fact wins the window and its predecessor stays out.
    ///
    /// The absence half is the measurement. Every system passes "surface
    /// Lisbon"; only a system that actually retires records passes "and not
    /// Berlin", which is why the memory-off control fails this family
    /// outright — the raw transcript contains both sentences forever.
    static let supersession: [MemoryEvalCase] = [
        MemoryEvalCase(
            id: "supersession/residence",
            query: "where do I live now",
            mustContain: ["lisbon"],
            mustNotContain: ["berlin"],
            k: MemoryEvalFixtures.k,
            tags: ["supersession"]
        ),
    ]

    /// A three-link chain leaves only the tail reachable.
    ///
    /// ForgetEval's DRIFT family. Two intermediates is the interesting case:
    /// a system that only ever compares against the immediately previous
    /// value retires the middle link and leaves the first one live.
    static let drift: [MemoryEvalCase] = [
        MemoryEvalCase(
            id: "drift/job-title-chain",
            query: "what is my job title",
            mustContain: ["principal engineer"],
            mustNotContain: ["staff engineer", "junior engineer"],
            k: MemoryEvalFixtures.k,
            tags: ["drift"]
        ),
    ]

    /// A TTL-expired record stays out while its live sibling stays in.
    ///
    /// Expiry is invalidation, not deletion, so the expired record is still
    /// in the store and still lexically matches the query. Passing requires
    /// the liveness filter to actually run at query time against the
    /// injected `now`, which is the mechanism a wall-clock read would
    /// silently break.
    static let decay: [MemoryEvalCase] = [
        MemoryEvalCase(
            id: "decay/expired-link-drops-out",
            query: "review meeting link meet example",
            mustContain: ["meet.example/review-weekly"],
            mustNotContain: ["meet.example/standup-daily"],
            k: MemoryEvalFixtures.k,
            tags: ["decay"]
        ),
    ]

    /// Forgetting one entity removes its records and leaves its siblings
    /// alone — the width control.
    ///
    /// An amnesia mechanism that is too wide is indistinguishable from a
    /// broken one, so the family is two cases: the target is gone *and* the
    /// neighbour survives. A purge implemented with substring or similarity
    /// matching passes the first and fails the second.
    static let amnesia: [MemoryEvalCase] = [
        MemoryEvalCase(
            id: "amnesia/forgotten-project-is-gone",
            query: "what happened to the Kestrel migration",
            mustNotContain: ["kestrel migration was cancelled"],
            k: MemoryEvalFixtures.k,
            tags: ["amnesia"]
        ),
        MemoryEvalCase(
            id: "amnesia/sibling-project-survives",
            query: "who reviews the Borealis release notes",
            mustContain: ["priya raman"],
            mustNotContain: ["kestrel migration was cancelled"],
            k: MemoryEvalFixtures.k,
            tags: ["amnesia"]
        ),
    ]

    /// Destructive deletion reaches both indexes, including after a
    /// fan-out failure was retried.
    ///
    /// ForgetEval measured lexical and vector deletion as complementary
    /// rather than redundant, so a purge that reaches one index leaves the
    /// content live through the other. The fixture deliberately fails the
    /// vector removal once and drives the store's retry before these cases
    /// run; they are graded on the state that recovery left behind.
    static let purge: [MemoryEvalCase] = [
        MemoryEvalCase(
            id: "purge/billing-identifier-erased",
            query: "which billing account covers the Borealis compute spend",
            mustNotContain: ["acct-77219"],
            k: MemoryEvalFixtures.k,
            tags: ["purge"]
        ),
        MemoryEvalCase(
            id: "purge/erased-after-fanout-retry",
            query: "acct-77219 compute spend billing",
            mustNotContain: ["acct-77219"],
            k: MemoryEvalFixtures.k,
            tags: ["purge"]
        ),
    ]

    /// A prefix-colliding sibling survives a purge aimed at its neighbour.
    ///
    /// `acct-772` is a proper prefix of `acct-77219`. ForgetEval reports the
    /// lexical index at 32/39 here and the vector index at 12/39, so a
    /// purge routed only through similarity deletes the wrong account. The
    /// store's exact-match-only ``PurgePredicate`` is what this case is
    /// holding in place.
    static let prefixCollision: [MemoryEvalCase] = [
        MemoryEvalCase(
            id: "prefix-collision/sibling-account-survives",
            query: "which account ran the retired sandbox",
            mustContain: ["acct-772 before we consolidated"],
            mustNotContain: ["acct-77219 covers"],
            k: MemoryEvalFixtures.k,
            tags: ["prefix-collision"]
        ),
    ]

    /// A cross-lingual alias of a forgotten fact.
    ///
    /// **Expected to fail, and recorded failing in the committed baseline.**
    /// ForgetEval puts deterministic systems at 0/38 on cross-lingual alias
    /// variation and at or below 5% on identifier obfuscation; nothing in
    /// this package claims otherwise. The case exists so the weakness is
    /// visible in the artifact a reviewer reads rather than absent from it —
    /// a suite that only contains cases the system passes is a marketing
    /// document. If a later cycle adds alias resolution, this row flipping
    /// to `passed: true` is the evidence.
    static let obfuscation: [MemoryEvalCase] = [
        MemoryEvalCase(
            id: "obfuscation/cross-lingual-alias-survives-amnesia",
            query: "Kestrel Migration Lieferantenpruefung",
            mustNotContain: ["kestrel-migration wurde"],
            k: MemoryEvalFixtures.k,
            tags: ["obfuscation"]
        ),
    ]

    /// A fact stated in the first turn is still recallable after the
    /// intervening turns have aged into the archive.
    ///
    /// This is the claim the whole memory layer exists to support on a
    /// 4096-token window: there is no full-context alternative, so "still
    /// there at turn 14" is not a convenience, it is the feature.
    static let factRecall: [MemoryEvalCase] = [
        MemoryEvalCase(
            id: "fact-recall/name-from-first-turn",
            query: "what is my name",
            mustContain: ["dana okafor"],
            k: MemoryEvalFixtures.k,
            tags: ["fact-recall"]
        ),
        MemoryEvalCase(
            id: "fact-recall/constraint-from-first-turn",
            query: "do I have any dietary constraints",
            mustContain: ["allergic to shellfish"],
            k: MemoryEvalFixtures.k,
            tags: ["fact-recall"]
        ),
        MemoryEvalCase(
            id: "fact-recall/archived-retrospective-date",
            query: "when is the Borealis retrospective scheduled",
            mustContain: ["march 12, 2024"],
            k: MemoryEvalFixtures.k,
            tags: ["fact-recall"]
        ),
        MemoryEvalCase(
            id: "fact-recall/archived-round-carries-provenance",
            query: "where does the Borealis release checklist live",
            // `RetrievedSource` has no metadata field, so an archival hit
            // carries its thread and round in the title. Asserting on it
            // here is what keeps that channel from silently disappearing:
            // recalled transcript without attribution is indistinguishable
            // from recalled transcript that was made up.
            mustContain: ["release-notes doc", "thread \(MemoryEvalFixtures.threadID) round"],
            k: MemoryEvalFixtures.k,
            tags: ["fact-recall", "provenance"]
        ),
    ]

    /// BEAM's information-updating ability: the corrected value surfaces
    /// and the stale one does not.
    static let contradictionUpdate: [MemoryEvalCase] = [
        MemoryEvalCase(
            id: "contradiction-update/desk-phone",
            query: "what is my desk phone number",
            mustContain: ["555-0181"],
            mustNotContain: ["555-0100"],
            k: MemoryEvalFixtures.k,
            tags: ["contradiction-update"]
        ),
    ]

    /// Every case, in a stable declaration order.
    static let all: [MemoryEvalCase] =
        supersession + drift + decay + amnesia + purge + prefixCollision
            + obfuscation + factRecall + contradictionUpdate

    /// The suite in ``MemoryEvalRunner`` form.
    static var suite: MemoryEvalSuite {
        MemoryEvalSuite(name: suiteName, cases: all)
    }

    /// Runner used for both gating and baseline regeneration.
    static var runner: MemoryEvalRunner { MemoryEvalRunner(concurrency: 4) }
}

// MARK: - Archival retrieval accuracy

/// Archival retrieval measured with the *existing* retrieval harness.
///
/// ``ArchivalRetriever`` is a plain ``Retriever`` and ``ArchivedRound/id``
/// is a ``DocumentChunker/chunkID(documentID:ordinal:content:)``, so
/// recall@k, nDCG@k, and MRR over the archive need no new metric code and no
/// new report type — the ground truth is just chunk ids, exactly as it is
/// for a document corpus.
enum MemoryArchivalEvalCases {
    /// Suite name.
    static let suiteName = "compound-memory-archival"

    /// Cutoff the archival metrics are reported at.
    static let k = 5

    /// Builds the cases against a live world, since ground truth is a set
    /// of content-derived chunk ids that only exist once the rounds are
    /// built.
    static func suite(_ world: MemoryEvalWorld) -> RetrievalEvalSuite {
        func roundID(containing needle: String) -> String {
            guard let round = world.rounds.first(where: { $0.displayText.contains(needle) }) else {
                // A missing fixture round is a harness bug, and a case
                // silently keyed to "" would score zero recall and read as a
                // retriever regression. Fail loudly instead.
                preconditionFailure("no archived round contains '\(needle)'")
            }
            return round.id
        }

        return RetrievalEvalSuite(name: suiteName, cases: [
            RetrievalEvalCase(
                id: "archival/retrospective-date",
                query: "Borealis retrospective March 12 2024",
                relevantIDs: [roundID(containing: "retrospective is scheduled")],
                tags: ["archival", "temporal"]
            ),
            RetrievalEvalCase(
                id: "archival/release-checklist",
                query: "release checklist release-notes doc",
                relevantIDs: [roundID(containing: "release checklist")],
                tags: ["archival"]
            ),
            RetrievalEvalCase(
                id: "archival/reviewer",
                query: "who reviews the release notes",
                relevantIDs: [roundID(containing: "Priya Raman")],
                tags: ["archival"]
            ),
            RetrievalEvalCase(
                id: "archival/key-expansion-entity",
                // "Dana Okafor" is a capitalized entity candidate the key
                // line lifts out of the round, so this query exercises the
                // K = V + facts expansion rather than the round body alone.
                query: "Dana Okafor Borealis",
                relevantIDs: [roundID(containing: "my name is Dana Okafor")],
                tags: ["archival", "key-expansion"]
            ),
            // Abstention: the archive holds nothing about this, and the
            // correct behavior is to surface nothing relevant. Included so
            // the retriever is measured on declining to answer, not only on
            // answering.
            RetrievalEvalCase(
                id: "archival/abstention-unknown-topic",
                query: "quarterly tax filing deadline for the Luxembourg entity",
                relevantIDs: [],
                tags: ["archival", "abstention"]
            ),
        ])
    }
}

// MARK: - Token-budget adherence

/// Budget scenarios rendered as ``GoldenTranscript``s and asserted with
/// ``EvalPredicate``s, through the existing ``EvalRunner``.
///
/// Measured under the *shipping* ``MemoryBudget/default`` (96 / 160 / 192
/// tokens, ~448 total against a 4096-token window), not the loosened recall
/// budget, and with a one-token-per-character counter so every assertion is
/// exact rather than heuristic.
enum MemoryBudgetEvalCases {
    /// Suite name.
    static let suiteName = "compound-memory-budget"

    /// One token per character. Makes a sub-budget assertion arithmetic
    /// instead of an estimate.
    struct CharCounter: TokenCounting {
        let contextSize = 4096
        func count(_ text: String) async -> Int { text.count }
    }

    /// Cost the assembler charges a source against its sub-budget.
    ///
    /// Delegates to the assembler's own ``MemoryContextAssembler/costText(of:)``
    /// rather than re-deriving it. An eval that computes cost its own way
    /// measures its own arithmetic, and would keep passing through exactly
    /// the change that matters: the assembler starting to charge something
    /// different.
    static func cost(_ source: RetrievedSource) -> Int {
        MemoryContextAssembler.costText(of: source).count
    }

    private static func assembler(
        _ world: MemoryEvalWorld,
        budget: MemoryBudget
    ) -> MemoryContextAssembler {
        MemoryContextAssembler(
            baseInstructions: "You are a memory-aware assistant.",
            conversation: world.conversation,
            memory: world.memory,
            archive: world.archive,
            coreBlockFactTag: "core",
            retriever: EmptyRetriever(),
            retrievalLimit: 0,
            budget: budget,
            keepRecent: world.messages.count - MemoryEvalFixtures.archivedMessageCount,
            counter: CharCounter(),
            clock: { MemoryEvalFixtures.now }
        )
    }

    private static func assemble(
        _ world: MemoryEvalWorld,
        budget: MemoryBudget,
        query: String
    ) async throws -> AssembledContext {
        try await assembler(world, budget: budget).assemble(
            userPrompt: query,
            runContext: RunContext(
                metadata: [MemorySessionConfiguration.defaultThreadIDMetadataKey: world.threadID]
            )
        )
    }

    /// Cost the assembler charges the transcript block, measured the way
    /// the assembler measures it.
    static func transcriptCost(_ context: AssembledContext) async -> Int {
        await CharCounter().count(
            MemoryContextAssembler.transcriptText(
                summary: context.transcript?.summary ?? "",
                messages: context.transcript?.messages ?? []
            )
        )
    }

    /// The suite.
    static func suite(_ world: MemoryEvalWorld) -> EvalSuite {
        EvalSuite(name: suiteName, cases: scenarios(world).map {
            EvalCase(id: $0.id, prompt: $0.id, predicates: $0.predicates, tags: $0.tags)
        })
    }

    /// Target that runs the scenarios.
    static func target(_ world: MemoryEvalWorld) -> MemoryBudgetEvalTarget {
        MemoryBudgetEvalTarget(scenarios(world))
    }

    /// One budget scenario.
    struct Scenario: Sendable {
        let id: String
        let tags: Set<String>
        let predicates: [any EvalPredicate]
        let run: @Sendable () async throws -> String
    }

    static func scenarios(_ world: MemoryEvalWorld) -> [Scenario] {
        [
            Scenario(
                id: "budget/default-share-holds",
                tags: ["budget"],
                predicates: [
                    // The core block is capped on its *body* against
                    // `coreBlockTokens`, while every other tier is fitted on
                    // title-plus-body (`MemoryContextAssembler.costText`).
                    // The eval measures each tier the way the assembler
                    // charges it, and then measures the whole share
                    // title-inclusive, so the asymmetry is recorded rather
                    // than papered over: the fixed 32-character core title
                    // is real prompt weight and it lands in
                    // `memory-within-share`.
                    GoldenPredicate.field("core-body-within-budget", true),
                    GoldenPredicate.field("facts-within-budget", true),
                    GoldenPredicate.field("archival-within-budget", true),
                    GoldenPredicate.field("transcript-within-budget", true),
                    // The whole memory share, titles included, must stay
                    // inside the ~448 tokens the design argues for. Zep
                    // injects ~1.6k and Mem0 ~6.7k; at 4096 total either
                    // would starve the task the user actually asked about.
                    GoldenPredicate.field("memory-within-share", true),
                ]
            ) {
                let budget = MemoryBudget.default
                let context = try await assemble(world, budget: budget, query: "what is my name and where do I live")
                var t = GoldenTranscript()
                let split = SourceSplit(context.sources)
                t.put("core-body-within-budget", split.coreBodyCost <= budget.coreBlockTokens)
                t.put("facts-within-budget", split.factCost <= budget.factTokens)
                t.put("archival-within-budget", split.archivalCost <= budget.archivalTokens)
                t.put("transcript-within-budget", await transcriptCost(context) <= budget.transcriptTokens)
                t.put("memory-within-share", split.total <= budget.memoryTokens)
                return t.rendered
            },

            Scenario(
                id: "budget/core-block-survives-starvation",
                tags: ["budget", "core-block"],
                predicates: [
                    // The core block is the pinned, evict-last source. Under
                    // a fact budget of one token it must be the thing that
                    // survives, because it is the highest value per token
                    // available: zero retrieval cost, zero read-path model
                    // calls, and the identity the assistant needs to be
                    // coherent at all.
                    GoldenPredicate.field("core-present", true),
                    GoldenPredicate.field("core-score-is-nil", true),
                    GoldenPredicate.field("facts-present", false),
                    GoldenPredicate.field("core-lines-are-whole", true),
                ]
            ) {
                let budget = MemoryBudget(
                    coreBlockTokens: 96,
                    factTokens: 1,
                    archivalTokens: 1,
                    transcriptTokens: 700,
                    maxFacts: 4,
                    maxArchivalRounds: 4
                )
                let context = try await assemble(world, budget: budget, query: "what is my name")
                let split = SourceSplit(context.sources)
                var t = GoldenTranscript()
                t.put("core-present", split.core != nil)
                t.put("core-score-is-nil", split.core?.score == nil)
                t.put("facts-present", !split.facts.isEmpty)
                // A half-rendered fact is worse than a missing one: the
                // model cannot tell a truncated claim from a complete one.
                let lines = (split.core?.content).map { $0.split(separator: "\n", omittingEmptySubsequences: true) } ?? []
                t.put("core-lines-are-whole", lines.allSatisfy { $0.contains(":") })
                return t.rendered
            },

            Scenario(
                id: "budget/facts-evicted-before-core-block",
                tags: ["budget", "core-block"],
                predicates: [
                    // Eviction order is the whole argument for pinning the
                    // core block with `score: nil`. Squeeze the fact budget
                    // and facts must go first; the core block must not.
                    GoldenPredicate.field("core-present-loose", true),
                    GoldenPredicate.field("core-present-tight", true),
                    GoldenPredicate.field("facts-shrank", true),
                ]
            ) {
                let loose = MemoryBudget(
                    coreBlockTokens: 400,
                    factTokens: 1600,
                    archivalTokens: 1,
                    transcriptTokens: 700,
                    maxFacts: 4,
                    maxArchivalRounds: 0
                )
                let tight = MemoryBudget(
                    coreBlockTokens: 400,
                    factTokens: 40,
                    archivalTokens: 1,
                    transcriptTokens: 700,
                    maxFacts: 4,
                    maxArchivalRounds: 0
                )
                let query = "what do I know about Borealis and my desk phone"
                let looseSplit = SourceSplit(try await assemble(world, budget: loose, query: query).sources)
                let tightSplit = SourceSplit(try await assemble(world, budget: tight, query: query).sources)
                var t = GoldenTranscript()
                t.put("core-present-loose", looseSplit.core != nil)
                t.put("core-present-tight", tightSplit.core != nil)
                t.put("facts-shrank", tightSplit.facts.count < looseSplit.facts.count)
                return t.rendered
            },

            Scenario(
                id: "budget/transcript-trimmed-not-starving-recall",
                tags: ["budget", "transcript"],
                predicates: [
                    // `TokenBudgetedAssembler` evicts sources and never the
                    // transcript, so an untrimmed transcript would be
                    // charged to the budget, be untrimmable, and starve
                    // retrieval to nothing while logging only that the
                    // prompt was too big. The assembler trims its own.
                    GoldenPredicate.field("transcript-within-budget", true),
                    GoldenPredicate.field("transcript-trimmed", true),
                    GoldenPredicate.field("sources-survived", true),
                ]
            ) {
                let budget = MemoryBudget(
                    coreBlockTokens: 400,
                    factTokens: 400,
                    archivalTokens: 400,
                    transcriptTokens: 120,
                    maxFacts: 4,
                    maxArchivalRounds: 2
                )
                let context = try await assemble(world, budget: budget, query: "what is my name")
                let recent = context.transcript?.messages ?? []
                var t = GoldenTranscript()
                t.put("transcript-within-budget", await transcriptCost(context) <= budget.transcriptTokens)
                t.put(
                    "transcript-trimmed",
                    recent.count < world.messages.count - MemoryEvalFixtures.archivedMessageCount
                )
                t.put("sources-survived", !context.sources.isEmpty)
                return t.rendered
            },
        ]
    }

    /// Splits an assembled source list into its memory tiers.
    ///
    /// The core block is identified by its pinned `nil` score — the same
    /// signal ``TokenBudgetedAssembler`` uses to evict it last — rather than
    /// by position, so a reordering regression shows up as a failed case
    /// instead of being silently absorbed.
    struct SourceSplit {
        let core: RetrievedSource?
        let facts: [RetrievedSource]
        let archival: [RetrievedSource]

        init(_ sources: [RetrievedSource]) {
            core = sources.first { $0.score == nil }
            let scored = sources.filter { $0.score != nil }
            facts = scored.filter { !$0.title.hasPrefix("thread ") }
            archival = scored.filter { $0.title.hasPrefix("thread ") }
        }

        /// Body-only cost of the core block — what
        /// ``MemoryBudget/coreBlockTokens`` actually caps.
        var coreBodyCost: Int { core?.content.count ?? 0 }
        /// Title-inclusive cost, charged to the whole-share total.
        var coreCost: Int { core.map(MemoryBudgetEvalCases.cost) ?? 0 }
        var factCost: Int { facts.reduce(0) { $0 + MemoryBudgetEvalCases.cost($1) } }
        var archivalCost: Int { archival.reduce(0) { $0 + MemoryBudgetEvalCases.cost($1) } }
        var total: Int { coreCost + factCost + archivalCost }
    }
}

/// ``EvalTarget`` that dispatches a prompt to the budget scenario of the
/// same name.
struct MemoryBudgetEvalTarget: EvalTarget {
    private let table: [String: @Sendable () async throws -> String]

    init(_ scenarios: [MemoryBudgetEvalCases.Scenario]) {
        table = Dictionary(scenarios.map { ($0.id, $0.run) }, uniquingKeysWith: { first, _ in first })
    }

    func respond(to prompt: String, auth _: AuthContext, metadata _: [String: String]) async throws -> String {
        guard let scenario = table[prompt] else { throw EvalError.unknownPrompt(prompt) }
        return try await scenario()
    }
}
