import Foundation
@testable import Compound

// Deterministic fixture world for the memory eval suite.
//
// Determinism rules for anything added to this file:
//   * No clock readings. Every date is derived from `epoch`.
//   * No fresh UUIDs. Message ids are derived from a fixed index.
//   * No `NLEmbedding`, no `SystemLanguageModel`, no network, no
//     filesystem. `NLEmbedding` in particular is unavailable on
//     CommandLineTools CI hosts, which would make the committed baseline a
//     function of which machine regenerated it.
//   * Nothing random, and no dictionary iteration order reaching a result.
//
// A fixture that varies between runs turns Evals/memory-baseline.json into
// noise and the gate into a coin flip.

// MARK: - Embedding

/// Deterministic stand-in for a sentence embedder: a hashed bag of tokens
/// projected onto a small fixed-dimension vector.
///
/// This is not pretending to be a good embedder, and it does not need to
/// be. ForgetEval found that swapping the embedder moved the cross-lingual
/// alias score not at all (0/16 to 0/16 lexical, 8/16 to 7/16 vector): the
/// control-plane correctness this suite measures — did the superseded fact
/// stay out, did the purge reach both indexes — does not depend on
/// embedding quality. What it does depend on is the number being the same
/// tomorrow.
struct MemoryEvalHashEmbedder: EmbeddingProvider {
    /// Identity recorded in ``MemoryEvalReport/Provenance/embedder``.
    static let identity = "fixture.hash-bag.v1(dim=32)"

    let dimension = 32

    func embed(_ text: String) async throws -> [Double] {
        var vector = [Double](repeating: 0, count: dimension)
        for token in BM25Retriever.defaultTokenize(text) {
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in token.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            vector[Int(hash % UInt64(dimension))] += 1
        }
        // A zero vector is skipped by DenseRetriever; pin a floor so every
        // chunk is genuinely indexed and an absence assertion means the
        // content was removed rather than never admitted.
        if vector.allSatisfy({ $0 == 0 }) { vector[0] = 1 }
        return vector
    }
}

// MARK: - Flaky index

/// Wraps a ``MutableTextIndex`` and throws on its first `remove`, then
/// behaves normally.
///
/// Exists to stage the one archival failure mode that actually loses user
/// data: a purge that reaches the lexical index and not the vector one.
/// ForgetEval measured the two as complementary rather than redundant
/// (32/39 vs 12/39 on prefix collision, 21/38 vs 0/38 on cross-lingual
/// aliases), so content deleted from only one index is still reachable
/// through the other. The fixture fails the removal once, lets the store
/// record a pending removal, and then drives the retry — so the suite is
/// asserting that the recovery path works, not merely that the happy path
/// does.
actor MemoryEvalFlakyIndex: MutableTextIndex {
    nonisolated let indexName: String
    private let base: any MutableTextIndex
    private var failuresRemaining: Int
    private(set) var removeAttempts = 0

    init(_ base: any MutableTextIndex, failures: Int = 1) {
        self.base = base
        self.indexName = base.indexName
        self.failuresRemaining = failures
    }

    func upsert(_ chunks: [DocumentChunk]) async throws {
        try await base.upsert(chunks)
    }

    @discardableResult
    func remove(ids: [String]) async throws -> Int {
        removeAttempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw MemoryEvalIndexFailure()
        }
        return try await base.remove(ids: ids)
    }

    func contains(id: String) async -> Bool {
        await base.contains(id: id)
    }
}

/// Injected failure for ``MemoryEvalFlakyIndex``.
struct MemoryEvalIndexFailure: Error, CustomStringConvertible {
    var description: String { "injected index failure" }
}

// MARK: - Retriever facades

/// Exposes a ``MemoryContextAssembler``'s recalled sources as a
/// ``Retriever``.
///
/// Deliberately runs the *real* read path rather than a reimplementation of
/// it: policy, redaction, salience scoring, sub-budget fitting, and the
/// single `.retrievedSources` redaction pass all execute exactly as they do
/// in production, and the eval grades whatever that produced. A hand-rolled
/// "query the store and rank it" façade would measure a second
/// implementation that no user ever runs.
///
/// Only ``AssembledContext/sources`` is graded. The transcript is
/// deliberately excluded: it is the working window, and a case that could
/// be satisfied by the last eight messages would measure nothing about
/// memory.
struct MemoryRecallRetriever: Retriever {
    let assembler: MemoryContextAssembler
    let threadID: String

    func retrieve(query: String, limit: Int) async throws -> [RetrievedSource] {
        let context = try await assembler.assemble(
            userPrompt: query,
            runContext: RunContext(
                metadata: [MemorySessionConfiguration.defaultThreadIDMetadataKey: threadID]
            )
        )
        return Array(context.sources.prefix(limit))
    }
}

// MARK: - Fixture world

/// The corpus, the stores, and the two retrievers under comparison.
///
/// Built once per test through ``MemoryEvalFixtures/make()``. Every store is
/// in-memory, so a world is cheap and nothing leaks between tests.
struct MemoryEvalWorld: Sendable {
    /// Thread every fixture message and fact belongs to.
    let threadID: String
    /// The transcript, oldest first.
    let messages: [ConversationMessage]
    /// Conversation store holding ``messages``.
    let conversation: InMemoryConversationStore
    /// Tier 1.
    let memory: InMemoryFactStore
    /// Tier 2.
    let archive: IndexedArchivalStore
    /// Rounds actually archived, in ordinal order.
    let rounds: [ArchivedRound]
    /// Lexical index behind ``archive``.
    let archiveLexical: BM25Retriever
    /// Vector index behind ``archive``.
    let archiveVector: DenseRetriever
    /// Memory-on retriever: the full read path.
    let memoryRetriever: any Retriever
    /// Memory-off control: hybrid retrieval over the raw transcript.
    let controlRetriever: any Retriever
    /// Archive-only retriever, for the ``RetrievalEvalRunner`` pass.
    let archivalRetriever: ArchivalRetriever
}

/// Builds the deterministic corpus the memory eval suite runs against.
enum MemoryEvalFixtures {

    // MARK: - Clock

    /// Fixed instant every fixture date derives from. Nothing here reads
    /// the wall clock.
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// One hour, the spacing between fixture turns.
    static let turnSpacing: TimeInterval = 3600

    /// "Now" for every query in the suite. Sits after the last turn so the
    /// whole corpus is in the past and recency ordering is stable.
    static var now: Date { epoch.addingTimeInterval(turnSpacing * 100) }

    /// Thread every fixture belongs to.
    static let threadID = "eval-thread"

    /// Extractor identity recorded in the report's provenance. The corpus
    /// is seeded directly rather than run through
    /// ``DeterministicFactExtractor``, because the suite grades the *read*
    /// path against a known store state; extraction has its own suite.
    static let extractorIdentity = "fixture.seeded.v1"

    /// Reconciler identity recorded in the report's provenance.
    static let reconcilerIdentity = DeterministicReconciler().name

    /// Provenance stamped on every report this fixture produces.
    static var provenance: MemoryEvalReport.Provenance {
        MemoryEvalReport.Provenance(
            embedder: MemoryEvalHashEmbedder.identity,
            extractor: extractorIdentity,
            reconciler: reconcilerIdentity,
            // No model-backed hook is enabled anywhere in this suite, so
            // there is no prompt in play to version.
            promptVersion: "none",
            modelAvailability: EvalReport.Environment.current().modelAvailability
        )
    }

    /// Budget used by the recall retriever.
    ///
    /// Deliberately loosened relative to ``MemoryBudget/default``: this
    /// suite measures *what is recallable*, and a 448-token production share
    /// would make every case a budget-eviction test in disguise. Budget
    /// adherence is measured separately, under the real defaults, by the
    /// token-budget ``EvalSuite`` in MemoryEvalSuite.swift.
    static let recallBudget = MemoryBudget(
        coreBlockTokens: 400,
        factTokens: 1600,
        archivalTokens: 2000,
        transcriptTokens: 700,
        maxFacts: 4,
        maxArchivalRounds: 4
    )

    /// Cutoff every case in the suite is graded at.
    ///
    /// Chosen so both memory tiers are actually representable inside it:
    /// the pinned core block plus ``MemoryBudget/maxFacts`` facts plus
    /// ``MemoryBudget/maxArchivalRounds`` rounds is nine sources, so an
    /// archival hit can never be crowded out of the graded window by tier-1
    /// facts alone. A `k` below that would silently turn every archival case
    /// into a test of fact ranking.
    static let k = 10

    // MARK: - Messages

    /// Deterministic message id for ordinal `n`. Never `UUID()` — a fresh
    /// UUID would reach the archival chunk id through the round's message
    /// list and make the baseline unstable.
    static func messageID(_ n: Int) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(n >> 8), UInt8(n & 0xFF)))
    }

    /// Index of the first message that stays in the working window. Turns
    /// before it are archived; turns from it on are recent, so their text
    /// reaches the model through the transcript rather than through
    /// `sources` and cannot satisfy a recall case by accident.
    static let archivedMessageCount = 16

    /// The fixture transcript, oldest first.
    ///
    /// Structure matters as much as content. The archived prefix carries
    /// durable project material — the substrate for the archival-recall,
    /// amnesia, purge, and alias families. The recent suffix carries the
    /// contradictions and retractions, so a supersession case is graded on
    /// whether tier 1 forgot, not on whether the raw transcript happens to
    /// be out of retrieval range.
    static let messages: [ConversationMessage] = {
        var out: [ConversationMessage] = []
        func turn(_ user: String, _ assistant: String) {
            let i = out.count
            out.append(ConversationMessage(
                id: messageID(i),
                role: .user,
                content: user,
                createdAt: epoch.addingTimeInterval(turnSpacing * Double(i)),
                metadata: [:]
            ))
            out.append(ConversationMessage(
                id: messageID(i + 1),
                role: .assistant,
                content: assistant,
                createdAt: epoch.addingTimeInterval(turnSpacing * Double(i + 1)),
                metadata: [:]
            ))
        }

        // --- archived prefix (turns 1-8) ---
        turn(
            "my name is Dana Okafor and I lead the Borealis project",
            "noted, Dana Okafor leads Borealis."
        )
        turn(
            "the Borealis retrospective is scheduled for March 12, 2024",
            "the Borealis retrospective is on March 12, 2024."
        )
        turn(
            "Project Kestrel migration was cancelled after the vendor review",
            "understood, Project Kestrel migration was cancelled."
        )
        turn(
            "billing account acct-77219 covers the Borealis compute spend",
            "acct-77219 is the Borealis billing account."
        )
        turn(
            "the retired sandbox ran on acct-772 before we consolidated",
            "acct-772 was the retired sandbox account."
        )
        turn(
            "die Kestrel-Migration wurde nach der Lieferantenpruefung abgesagt",
            "verstanden, die Kestrel-Migration wurde abgesagt."
        )
        turn(
            "the Borealis release checklist lives in the release-notes doc",
            "the release checklist is in the release-notes doc."
        )
        turn(
            "Priya Raman reviews every Borealis release note",
            "Priya Raman is the reviewer for Borealis release notes."
        )

        // --- recent suffix (turns 9-14), never archived ---
        turn("I live in Berlin", "noted, you live in Berlin.")
        turn("actually I moved to Lisbon last month", "updated, you live in Lisbon.")
        turn("my job title is staff engineer", "noted, staff engineer.")
        turn("I was promoted to principal engineer", "congratulations, principal engineer.")
        turn("my desk phone is 555-0100", "noted, desk phone 555-0100.")
        turn("my new desk phone is 555-0181", "updated, desk phone 555-0181.")
        return out
    }()

    // MARK: - Facts

    private static func fact(
        subject: String,
        predicate: String,
        text: String,
        tags: Set<String> = [],
        importance: Int = 5,
        confidence: Double = 0.9,
        origin: MemoryOrigin = .userStated,
        validFromTurn: Int,
        validUntilTurn: Int? = nil,
        invalidated: Bool = false,
        expiresAtTurn: Int? = nil,
        supersedes: String? = nil,
        messageIndexes: [Int] = []
    ) -> Fact {
        let validFrom = epoch.addingTimeInterval(turnSpacing * Double(validFromTurn))
        return Fact(
            threadID: threadID,
            subject: subject,
            predicate: predicate,
            text: text,
            origin: origin,
            confidence: confidence,
            importance: importance,
            tags: tags,
            provenance: FactProvenance(
                threadID: threadID,
                messageIDs: messageIndexes.map(messageID),
                extractor: extractorIdentity
            ),
            validFrom: validFrom,
            validUntil: validUntilTurn.map { epoch.addingTimeInterval(turnSpacing * Double($0)) },
            recordedAt: validFrom,
            invalidatedAt: invalidated
                ? epoch.addingTimeInterval(turnSpacing * Double(validUntilTurn ?? validFromTurn))
                : nil,
            expiresAt: expiresAtTurn.map { epoch.addingTimeInterval(turnSpacing * Double($0)) },
            supersedes: supersedes,
            lastAccessedAt: validFrom,
            accessCount: 0
        )
    }

    /// Convenience: the id a fixture fact will be stored under.
    static func factID(subject: String, predicate: String, text: String) -> String {
        FactID.derive(threadID: threadID, subject: subject, predicate: predicate, text: text)
    }

    /// Every fact the fixture store is seeded with, live and retired.
    ///
    /// Retired records are seeded in their retired state rather than being
    /// deleted, because that is what supersession actually leaves behind: a
    /// bi-temporal record that an `asOf` query can still reach and a live
    /// query must not. A fixture that simply omitted them would make the
    /// forgetting families pass vacuously.
    static let facts: [Fact] = {
        let staffEngineerID = factID(subject: "user", predicate: "title", text: "staff engineer")

        return [
            // core identity — pinned into the core memory block
            fact(
                subject: "user", predicate: "name", text: "Dana Okafor",
                tags: ["core"], importance: 9, validFromTurn: 0, messageIndexes: [0]
            ),

            // supersession: Berlin retired in favor of Lisbon
            fact(
                subject: "user", predicate: "location", text: "Berlin",
                tags: ["core"], importance: 7,
                validFromTurn: 16, validUntilTurn: 18, invalidated: true,
                messageIndexes: [16]
            ),
            fact(
                subject: "user", predicate: "location", text: "Lisbon",
                tags: ["core"], importance: 7, validFromTurn: 18,
                supersedes: factID(subject: "user", predicate: "location", text: "Berlin"),
                messageIndexes: [18]
            ),

            // drift: a three-link chain, only the last live
            fact(
                subject: "user", predicate: "title", text: "junior engineer",
                importance: 6, validFromTurn: 2, validUntilTurn: 20, invalidated: true
            ),
            fact(
                subject: "user", predicate: "title", text: "staff engineer",
                importance: 6, validFromTurn: 20, validUntilTurn: 22, invalidated: true,
                supersedes: factID(subject: "user", predicate: "title", text: "junior engineer"),
                messageIndexes: [20]
            ),
            fact(
                subject: "user", predicate: "title", text: "principal engineer",
                importance: 6, validFromTurn: 22,
                supersedes: staffEngineerID,
                messageIndexes: [22]
            ),

            // contradiction-update: the corrected phone number wins
            fact(
                subject: "user", predicate: "desk phone", text: "555-0100",
                importance: 5, validFromTurn: 24, validUntilTurn: 26, invalidated: true,
                messageIndexes: [24]
            ),
            fact(
                subject: "user", predicate: "desk phone", text: "555-0181",
                importance: 5, validFromTurn: 26,
                supersedes: factID(subject: "user", predicate: "desk phone", text: "555-0100"),
                messageIndexes: [26]
            ),

            // decay: an expired ephemeral fact next to a live sibling
            fact(
                subject: "standup", predicate: "link", text: "meet.example/standup-daily",
                tags: ["ephemeral"], importance: 3,
                validFromTurn: 4, expiresAtTurn: 30
            ),
            fact(
                subject: "review", predicate: "link", text: "meet.example/review-weekly",
                importance: 4, validFromTurn: 4
            ),

            // amnesia: Kestrel is forgotten wholesale, Borealis survives
            fact(
                subject: "project kestrel", predicate: "status",
                text: "Project Kestrel migration was cancelled",
                importance: 6, validFromTurn: 4, messageIndexes: [4]
            ),
            fact(
                subject: "project borealis", predicate: "reviewer",
                text: "Priya Raman reviews every Borealis release note",
                importance: 6, validFromTurn: 14, messageIndexes: [14]
            ),
            fact(
                subject: "project borealis", predicate: "retrospective",
                text: "the Borealis retrospective is scheduled for March 12, 2024",
                importance: 6, validFromTurn: 2, messageIndexes: [2]
            ),

            // purge: a billing identifier, and a prefix-colliding sibling
            fact(
                subject: "acct-77219", predicate: "purpose",
                text: "billing account acct-77219 covers the Borealis compute spend",
                importance: 5, validFromTurn: 6, messageIndexes: [6]
            ),
            fact(
                subject: "acct-772", predicate: "purpose",
                text: "the retired sandbox ran on acct-772 before we consolidated",
                importance: 4, validFromTurn: 8, messageIndexes: [8]
            ),

            // constraint kept in the core block, and never touched by any
            // forgetting operation — the "something survived" control
            fact(
                subject: "user", predicate: "constraint", text: "allergic to shellfish",
                tags: ["core"], importance: 8, validFromTurn: 0
            ),
        ]
    }()

    // MARK: - World construction

    /// Text a raw transcript message is indexed under by the control.
    static func controlText(_ message: ConversationMessage) -> String {
        "\(message.role.rawValue): \(message.content)"
    }

    /// Builds the fixture world: stores populated, archive indexed, and the
    /// forgetting operations already applied.
    ///
    /// The forgetting operations run *here*, in setup, rather than inside a
    /// case. A case must be a pure read, otherwise its verdict would depend
    /// on the order the runner's concurrency window happened to admit it in.
    static func make() async throws -> MemoryEvalWorld {
        let conversation = InMemoryConversationStore()
        for message in messages { await conversation.append(message) }

        let memory = InMemoryFactStore()
        try await memory.upsert(facts)

        // --- tier 2: rounds built from the archived prefix only ---
        let lexical = BM25Retriever()
        let vector = DenseRetriever(provider: MemoryEvalHashEmbedder())
        let flakyVector = MemoryEvalFlakyIndex(DenseIndex(vector))
        let reader = HybridRetriever(retrievers: [lexical, vector], perRetrieverLimit: 20)
        let archive = IndexedArchivalStore(
            indexes: [BM25Index(lexical), flakyVector],
            reader: reader,
            journal: InMemoryArchivalJournal()
        )

        let built = RoundBuilder.rounds(
            from: Array(messages.prefix(archivedMessageCount)),
            threadID: threadID
        )
        try await archive.archive(built.rounds)

        // --- forgetting operations, in the order a real system runs them ---

        // 1. Purge: the billing identifier, through the flaky index — the
        //    first removal the store attempts, so the injected failure lands
        //    here. The vector side refuses, the store records a pending
        //    removal and throws `partialRemoval`, and the retry at the head
        //    of the next mutating call clears it. Asserting absence *after*
        //    that retry is the point: a purge that only works when nothing
        //    goes wrong is not a compliance mechanism.
        _ = try await memory.purge(matching: PurgePredicate(subjectEquals: "acct-77219"))
        let billingRounds = built.rounds
            .filter { $0.displayText.contains("acct-77219") }
            .map(\.id)
        do {
            try await archive.remove(chunkIDs: billingRounds)
        } catch let error as MemoryError {
            guard case .partialRemoval = error else { throw error }
            // Expected: the injected failure. Drive the retry.
            try await archive.archive([])
        }

        // 2. Amnesia: forget Project Kestrel end to end. Tier 1 by exact
        //    subject match — never similarity, never prefix — and tier 2 by
        //    chunk id, because a fact that is gone from the store while its
        //    verbatim round is still indexed has not been forgotten at all.
        _ = try await memory.purge(matching: PurgePredicate(subjectEquals: "project kestrel"))
        let kestrelRounds = built.rounds
            .filter { $0.displayText.localizedCaseInsensitiveContains("Project Kestrel") }
            .map(\.id)
        try await archive.remove(chunkIDs: kestrelRounds)

        let rounds = built.rounds.filter { round in
            !kestrelRounds.contains(round.id) && !billingRounds.contains(round.id)
        }

        // --- retrievers ---
        let assembler = MemoryContextAssembler(
            baseInstructions: "You are a memory-aware assistant.",
            conversation: conversation,
            memory: memory,
            archive: archive,
            coreBlockFactTag: "core",
            retriever: EmptyRetriever(),
            retrievalLimit: 0,
            budget: recallBudget,
            keepRecent: messages.count - archivedMessageCount,
            clock: { now }
        )

        let controlLexical = BM25Retriever()
        let controlVector = DenseRetriever(provider: MemoryEvalHashEmbedder())
        let controlChunks = messages.enumerated().map { index, message in
            DocumentChunk(
                documentID: "control|\(threadID)",
                ordinal: index,
                content: controlText(message)
            )
        }
        await controlLexical.index(controlChunks)
        try await controlVector.index(controlChunks)

        return MemoryEvalWorld(
            threadID: threadID,
            messages: messages,
            conversation: conversation,
            memory: memory,
            archive: archive,
            rounds: rounds,
            archiveLexical: lexical,
            archiveVector: vector,
            memoryRetriever: MemoryRecallRetriever(assembler: assembler, threadID: threadID),
            // The control is the honest alternative to shipping a memory
            // layer at all: hybrid retrieval straight over the raw
            // transcript, with no facts, no supersession, and no forgetting.
            // MemDelta found exactly this baseline beating an agent's
            // self-managed memory (47% vs 42%), so the suite compares
            // against it every run rather than assuming the memory layer
            // helps.
            controlRetriever: HybridRetriever(
                retrievers: [controlLexical, controlVector],
                perRetrieverLimit: 20
            ),
            archivalRetriever: ArchivalRetriever(store: archive, threadID: threadID)
        )
    }
}
