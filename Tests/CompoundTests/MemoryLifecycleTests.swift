import Foundation
import Testing
@testable import Compound

// MARK: - Fixtures

/// Mutable clock so a test can advance time between turns without ever
/// reading the system clock. Every timestamp the write path writes comes
/// from here, which is what makes these assertions exact rather than
/// approximate.
private final class LifecycleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ start: Date) { self.instant = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        instant = instant.addingTimeInterval(seconds)
        lock.unlock()
    }

    var read: @Sendable () -> Date {
        { [self] in self.now }
    }
}

/// Extractor whose output the test dictates outright, so the lifecycle is
/// exercised independently of the rule table's behavior.
private struct LifecycleExtractor: FactExtracting {
    let name: String
    let build: @Sendable (MemoryTurn, ExtractionContext) async throws -> [FactCandidate]

    init(name: String = "lifecycle.fake", build: @escaping @Sendable (MemoryTurn, ExtractionContext) async throws -> [FactCandidate]) {
        self.name = name
        self.build = build
    }

    func extract(from turn: MemoryTurn, context: ExtractionContext) async throws -> [FactCandidate] {
        try await build(turn, context)
    }
}

private struct LifecycleExtractorFailure: Error {}

private enum LifecycleFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func turn(
        threadID: String = "t1",
        user: String,
        assistant: String = "Noted."
    ) -> MemoryTurn {
        MemoryTurn(
            threadID: threadID,
            userMessage: .user(user),
            assistantMessage: .assistant(assistant)
        )
    }

    static func candidate(
        from turn: MemoryTurn,
        predicate: String,
        text: String,
        now: Date,
        subject: String = "user",
        confidence: Double = 0.9,
        importance: Int = 7,
        tags: Set<String> = []
    ) -> FactCandidate {
        FactCandidate(
            threadID: turn.threadID,
            subject: subject,
            predicate: predicate,
            text: text,
            origin: .userStated,
            confidence: confidence,
            importance: importance,
            tags: tags,
            sourceMessageIDs: [turn.userMessage.id],
            validFrom: now,
            extractor: "lifecycle.fake"
        )
    }

    /// Extracts one candidate whose text is the literal tail of the user
    /// message after `marker`, so the verbatim invariant holds by
    /// construction.
    static func tailExtractor(predicate: String, marker: String) -> LifecycleExtractor {
        LifecycleExtractor { turn, context in
            let content = turn.userMessage.content
            guard let range = content.range(of: marker) else { return [] }
            var tail = String(content[range.upperBound...])
            if tail.hasSuffix(".") { tail.removeLast() }
            guard !tail.isEmpty else { return [] }
            return [candidate(from: turn, predicate: predicate, text: tail, now: context.now)]
        }
    }

    static func context(runID: UUID = UUID(), tracer: any Tracer = NullTracer()) -> RunContext {
        RunContext(runID: runID, tracer: tracer)
    }

    /// A transcript of `pairs` user/assistant exchanges, oldest first.
    static func transcript(pairs: Int) -> [ConversationMessage] {
        (0..<pairs).flatMap { i in
            [ConversationMessage.user("question \(i)"), ConversationMessage.assistant("answer \(i)")]
        }
    }
}

/// Deterministic stand-in for a sentence embedder, hash-projected onto a
/// fixed-dimension vector. Never touches `NLEmbedding`, which is absent on
/// CommandLineTools hosts.
private struct LifecycleHashEmbedder: EmbeddingProvider {
    let dimension = 16

    func embed(_ text: String) async throws -> [Double] {
        var vector = [Double](repeating: 0, count: dimension)
        for token in BM25Retriever.defaultTokenize(text) {
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in token.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            vector[Int(hash % UInt64(dimension))] += 1
        }
        if vector.allSatisfy({ $0 == 0 }) { vector[0] = 1 }
        return vector
    }
}

/// Index that can be told to start refusing writes, so the partial-removal
/// path and its retry can be driven deterministically.
private actor LifecycleFlakyIndex: MutableTextIndex {
    nonisolated let indexName: String
    private var indexed: Set<String> = []
    private var failing = false

    init(indexName: String = "flaky") { self.indexName = indexName }

    func setFailing(_ value: Bool) { failing = value }

    func upsert(_ chunks: [DocumentChunk]) throws {
        if failing { throw LifecycleExtractorFailure() }
        indexed.formUnion(chunks.map(\.id))
    }

    @discardableResult
    func remove(ids: [String]) throws -> Int {
        if failing { throw LifecycleExtractorFailure() }
        var removed = 0
        for id in ids where indexed.remove(id) != nil { removed += 1 }
        return removed
    }

    func contains(id: String) -> Bool { indexed.contains(id) }
}

/// Fails the test if anything on the write path reaches the destructive
/// purge API. Compliance deletion and contradiction handling must never
/// share a code path.
private actor PurgeTripwireStore: MemoryStore {
    private let inner: InMemoryFactStore
    private(set) var purgeCalls = 0

    init(_ inner: InMemoryFactStore = InMemoryFactStore()) { self.inner = inner }

    func upsert(_ facts: [Fact]) async throws { try await inner.upsert(facts) }
    func fact(id: String) async throws -> Fact? { try await inner.fact(id: id) }
    func query(_ query: MemoryQuery) async throws -> [Fact] { try await inner.query(query) }
    func similar(to text: String, slot: FactSlot?, threadID: String?, limit: Int, now: Date) async throws -> [ScoredFact] {
        try await inner.similar(to: text, slot: slot, threadID: threadID, limit: limit, now: now)
    }
    func touch(ids: [String], at instant: Date) async throws { try await inner.touch(ids: ids, at: instant) }
    @discardableResult
    func invalidate(ids: [String], validUntil: Date?, at instant: Date, reason: InvalidationReason) async throws -> Int {
        try await inner.invalidate(ids: ids, validUntil: validUntil, at: instant, reason: reason)
    }
    @discardableResult
    func purge(ids: [String]) async throws -> Int {
        purgeCalls += 1
        return try await inner.purge(ids: ids)
    }
    @discardableResult
    func purge(matching predicate: PurgePredicate) async throws -> [String] {
        purgeCalls += 1
        return try await inner.purge(matching: predicate)
    }
    func allIDs() async throws -> [String] { try await inner.allIDs() }
    func removeAll() async throws { try await inner.removeAll() }
}

// MARK: - Queue behavior

@Suite("MemoryConsolidatorQueue")
struct MemoryConsolidatorQueueTests {
    @Test("turnCompleted enqueues and does not consolidate")
    func enqueueOnly() async throws {
        let store = InMemoryFactStore()
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleFixtures.tailExtractor(predicate: "location", marker: "I live in "),
            clock: clock.read
        )
        let runContext = LifecycleFixtures.context()
        for i in 0..<5 {
            await consolidator.turnCompleted(
                LifecycleFixtures.turn(user: "I live in city\(i)."),
                runContext: runContext
            )
        }
        #expect(await consolidator.queuedCount == 5)
        #expect(await consolidator.droppedCount == 0)
        #expect(try await store.allIDs().isEmpty, "the critical path must not write")
    }

    @Test("queue overflow drops the oldest turn and counts it")
    func overflowDropsOldest() async throws {
        let store = InMemoryFactStore()
        let tracer = InMemoryTracer()
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            // Each turn lands in its own slot, so all three survivors are
            // stored and the assertion measures the queue rather than the
            // reconciler's contradiction handling.
            extractor: LifecycleExtractor { turn, context in
                let content = turn.userMessage.content
                guard let range = content.range(of: "I live in ") else { return [] }
                var tail = String(content[range.upperBound...])
                if tail.hasSuffix(".") { tail.removeLast() }
                return [LifecycleFixtures.candidate(
                    from: turn,
                    predicate: "location",
                    text: tail,
                    now: context.now,
                    subject: tail
                )]
            },
            tracer: tracer,
            queueCapacity: 3,
            clock: LifecycleClock(LifecycleFixtures.epoch).read
        )
        let runContext = LifecycleFixtures.context()
        for i in 0..<5 {
            await consolidator.turnCompleted(
                LifecycleFixtures.turn(user: "I live in city\(i)."),
                runContext: runContext
            )
        }
        #expect(await consolidator.queuedCount == 3)
        #expect(await consolidator.droppedCount == 2)

        let summaries = await consolidator.drain(runID: UUID())
        #expect(summaries.count == 3)
        // The three that survived are the newest three: a memory layer
        // that sheds load should shed the stalest state, not the freshest.
        let facts = try await store.query(MemoryQuery(now: LifecycleFixtures.epoch, threadID: "t1", limit: 100))
        #expect(Set(facts.map(\.text)) == ["city2", "city3", "city4"])

        let overflowLines = await tracer.snapshot().compactMap { event -> String? in
            if case .info(_, let category, let message) = event, category == MemoryTrace.category { return message }
            return nil
        }
        #expect(overflowLines.contains { $0.hasPrefix("event=queue_overflow ") })
    }

    @Test("drain processes FIFO, empties the queue, and a second drain is a no-op")
    func drainIsFIFOAndIdempotent() async throws {
        let store = InMemoryFactStore()
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleFixtures.tailExtractor(predicate: "location", marker: "I live in "),
            clock: clock.read
        )
        let runContext = LifecycleFixtures.context()
        for i in 0..<3 {
            await consolidator.turnCompleted(
                LifecycleFixtures.turn(user: "I live in city\(i)."),
                runContext: runContext
            )
        }
        let first = await consolidator.drain(runID: UUID())
        #expect(first.count == 3)
        #expect(await consolidator.queuedCount == 0)
        let idsAfterFirst = try await store.allIDs()

        let second = await consolidator.drain(runID: UUID())
        #expect(second.isEmpty)
        #expect(try await store.allIDs() == idsAfterFirst)
    }
}

// MARK: - Write-path guards

@Suite("MemoryConsolidatorGuards")
struct MemoryConsolidatorGuardTests {
    @Test("a candidate that is not a verbatim span is rejected, counted, and traced")
    func verbatimGuardRejects() async throws {
        let store = InMemoryFactStore()
        let tracer = InMemoryTracer()
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        // The extractor authors text that never appeared in the turn — the
        // exact failure mode a model-backed writer produces, and the one a
        // clean decode cannot rule out.
        let extractor = LifecycleExtractor { turn, context in
            [LifecycleFixtures.candidate(
                from: turn,
                predicate: "name",
                text: "Marvin the Paranoid Android",
                now: context.now
            )]
        }
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: extractor,
            tracer: tracer,
            clock: clock.read
        )
        let summary = await consolidator.consolidate(
            LifecycleFixtures.turn(user: "My name is Ada."),
            runID: UUID()
        )
        #expect(summary.extracted == 1)
        #expect(summary.rejected == 1)
        #expect(summary.added == 0)
        #expect(try await store.allIDs().isEmpty)

        let lines = await tracer.snapshot().compactMap { event -> String? in
            if case .info(_, let category, let message) = event, category == MemoryTrace.category { return message }
            return nil
        }
        #expect(lines.contains { $0.contains("event=rejected") && $0.contains("reason=nonVerbatimSpan") })
    }

    @Test("a candidate carrying a secret is rejected outright, never stored redacted")
    func writePathRedactionRejects() async throws {
        let store = InMemoryFactStore()
        let tracer = InMemoryTracer()
        let redactor = try CommonRedactors.awsAccessKey()
        let secret = "AKIAABCDEFGHIJKLMNOP"
        let userText = "My key is \(secret)."
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            // The extractor is handed no redactors of its own here, so the
            // rejection under test is the consolidator's own write-path
            // guard rather than the extractor's copy of it.
            extractor: LifecycleExtractor { turn, context in
                [LifecycleFixtures.candidate(from: turn, predicate: "key", text: secret, now: context.now)]
            },
            redactors: [redactor],
            tracer: tracer,
            clock: LifecycleClock(LifecycleFixtures.epoch).read
        )
        let summary = await consolidator.consolidate(
            LifecycleFixtures.turn(user: userText),
            runID: UUID()
        )
        #expect(summary.rejected == 1)
        #expect(summary.added == 0)

        let all = try await store.query(MemoryQuery(
            now: LifecycleFixtures.epoch,
            includeInvalidated: true,
            limit: 100
        ))
        #expect(all.isEmpty, "nothing may be stored — not the secret, and not a redacted stand-in for it")
        let placeholder = redactor.redact(secret)
        #expect(!all.contains { $0.text.contains(placeholder) })

        let lines = await tracer.snapshot().compactMap { event -> String? in
            if case .info(_, let category, let message) = event, category == MemoryTrace.category { return message }
            return nil
        }
        #expect(lines.contains { $0.contains("event=rejected") && $0.contains("reason=redactionFired") })
    }

    @Test("consolidation never reaches the destructive purge path")
    func neverPurges() async throws {
        let store = PurgeTripwireStore()
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleFixtures.tailExtractor(predicate: "location", marker: "I live in "),
            clock: clock.read
        )
        _ = await consolidator.consolidate(LifecycleFixtures.turn(user: "I live in Berlin."), runID: UUID())
        clock.advance(by: 3600)
        _ = await consolidator.consolidate(LifecycleFixtures.turn(user: "I live in Osaka."), runID: UUID())
        #expect(await store.purgeCalls == 0)
    }
}

// MARK: - End to end

@Suite("MemoryConsolidatorPipeline")
struct MemoryConsolidatorPipelineTests {
    @Test("a contradicting second turn supersedes the first at its own validFrom")
    func contradictionSupersedes() async throws {
        let store = InMemoryFactStore()
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleFixtures.tailExtractor(predicate: "location", marker: "I live in "),
            clock: clock.read
        )
        let runContext = LifecycleFixtures.context()
        await consolidator.turnCompleted(LifecycleFixtures.turn(user: "I live in Berlin."), runContext: runContext)
        let firstSummary = await consolidator.drain(runID: UUID())
        #expect(firstSummary.first?.added == 1)

        let secondInstant = LifecycleFixtures.epoch.addingTimeInterval(7200)
        clock.advance(by: 7200)
        await consolidator.turnCompleted(LifecycleFixtures.turn(user: "I live in Osaka."), runContext: runContext)
        let secondSummary = await consolidator.drain(runID: UUID())
        #expect(secondSummary.first?.updated == 1)
        #expect(secondSummary.first?.added == 1)

        let live = try await store.query(MemoryQuery(now: secondInstant, threadID: "t1", limit: 100))
        #expect(live.count == 1)
        #expect(live.first?.text == "Osaka")

        let everything = try await store.query(MemoryQuery(
            now: secondInstant,
            threadID: "t1",
            includeInvalidated: true,
            limit: 100
        ))
        #expect(everything.count == 2)
        let retired = try #require(everything.first { $0.text == "Berlin" })
        // Zep's rule: the outgoing record's validity ends exactly where the
        // incoming one's begins, which is what makes an `asOf` query answer
        // "what did I believe in March" instead of finding a gap.
        #expect(retired.validUntil == secondInstant)
        #expect(retired.invalidatedAt != nil)

        // The store still answers for the earlier instant.
        let asOfEarlier = try await store.query(MemoryQuery(
            now: secondInstant,
            threadID: "t1",
            asOf: LifecycleFixtures.epoch.addingTimeInterval(60),
            limit: 100
        ))
        #expect(asOfEarlier.map(\.text) == ["Berlin"])
    }

    @Test("archiving the same backlog twice yields identical rounds and no growth")
    func archivingIsIdempotent() async throws {
        let store = InMemoryFactStore()
        let bm25 = BM25Retriever()
        let dense = DenseRetriever(provider: LifecycleHashEmbedder())
        let journal = InMemoryArchivalJournal()
        let archive = IndexedArchivalStore(
            indexes: [BM25Index(bm25), DenseIndex(dense)],
            reader: bm25,
            journal: journal
        )
        let conversation = InMemoryConversationStore()
        for message in LifecycleFixtures.transcript(pairs: 5) {
            await conversation.append(message)
        }
        let consolidator = MemoryConsolidator(
            memory: store,
            archive: archive,
            conversation: conversation,
            extractor: LifecycleExtractor { _, _ in [] },
            archivePolicy: ArchivePolicy(keepRecent: 2, archiveLag: 2, maxRoundsPerPass: 16),
            clock: LifecycleClock(LifecycleFixtures.epoch).read
        )
        let runContext = LifecycleFixtures.context()
        let turn = LifecycleFixtures.turn(user: "anything")

        await consolidator.turnCompleted(turn, runContext: runContext)
        let first = await consolidator.drain(runID: UUID())
        let archivedFirst = try #require(first.first).archived
        #expect(archivedFirst > 0, "the fixture must actually produce a backlog")
        let countAfterFirst = try await archive.count()
        #expect(countAfterFirst == archivedFirst)

        await consolidator.turnCompleted(turn, runContext: runContext)
        let second = await consolidator.drain(runID: UUID())
        #expect(try #require(second.first).archived == 0, "a re-run must not mint a second copy")
        #expect(try await archive.count() == countAfterFirst)

        // The ids are stable, so an id computed from the transcript alone
        // still resolves after the second pass.
        let expected = RoundBuilder.rounds(
            from: Array(LifecycleFixtures.transcript(pairs: 5).prefix(6)),
            threadID: "t1"
        ).rounds
        for round in expected {
            #expect(try await archive.round(chunkID: round.id) != nil)
        }
    }

    @Test("a consolidation that blows its deadline degrades to a partial summary")
    func deadlineDegradesRatherThanFails() async throws {
        let store = InMemoryFactStore()
        let tracer = InMemoryTracer()
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleExtractor { turn, context in
                try await Task.sleep(for: .seconds(30))
                return [LifecycleFixtures.candidate(from: turn, predicate: "x", text: "y", now: context.now)]
            },
            tracer: tracer,
            perTurnDeadline: .milliseconds(50),
            clock: LifecycleClock(LifecycleFixtures.epoch).read
        )
        let summary = await consolidator.consolidate(
            LifecycleFixtures.turn(user: "hello"),
            runID: UUID()
        )
        #expect(summary.added == 0)
        #expect(summary.isNoOp)
        #expect(try await store.allIDs().isEmpty, "a timed-out pass must leave memory exactly as it was")
        let lines = await tracer.snapshot().compactMap { event -> String? in
            if case .info(_, let category, let message) = event, category == MemoryTrace.category { return message }
            return nil
        }
        #expect(lines.contains { $0.hasPrefix("event=analysis_timeout ") })
    }

    @Test("a throwing extractor leaves memory unchanged and still reports")
    func extractorFailureLeavesMemoryUnchanged() async throws {
        let store = InMemoryFactStore()
        let tracer = InMemoryTracer()
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        let good = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleFixtures.tailExtractor(predicate: "location", marker: "I live in "),
            clock: clock.read
        )
        _ = await good.consolidate(LifecycleFixtures.turn(user: "I live in Berlin."), runID: UUID())
        let before = try await store.allIDs()
        #expect(before.count == 1)

        let broken = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleExtractor { _, _ in throw LifecycleExtractorFailure() },
            tracer: tracer,
            clock: clock.read
        )
        let summary = await broken.consolidate(LifecycleFixtures.turn(user: "I live in Osaka."), runID: UUID())
        #expect(summary.isNoOp)
        #expect(try await store.allIDs() == before, "a failed write path must not disturb what is already stored")

        let lines = await tracer.snapshot().compactMap { event -> String? in
            if case .info(_, let category, let message) = event, category == MemoryTrace.category { return message }
            return nil
        }
        #expect(lines.contains { $0.hasPrefix("event=analysis_failed ") })
    }

    @Test("a throwing archive does not fail the turn or lose the facts")
    func archiveFailureDoesNotFailTheTurn() async throws {
        let store = InMemoryFactStore()
        let flaky = LifecycleFlakyIndex()
        await flaky.setFailing(true)
        let bm25 = BM25Retriever()
        let archive = IndexedArchivalStore(
            indexes: [flaky],
            reader: bm25,
            journal: InMemoryArchivalJournal()
        )
        let conversation = InMemoryConversationStore()
        for message in LifecycleFixtures.transcript(pairs: 5) {
            await conversation.append(message)
        }
        let tracer = InMemoryTracer()
        let consolidator = MemoryConsolidator(
            memory: store,
            archive: archive,
            conversation: conversation,
            extractor: LifecycleFixtures.tailExtractor(predicate: "location", marker: "I live in "),
            archivePolicy: ArchivePolicy(keepRecent: 2, archiveLag: 2),
            tracer: tracer,
            clock: LifecycleClock(LifecycleFixtures.epoch).read
        )
        let summary = await consolidator.consolidate(
            LifecycleFixtures.turn(user: "I live in Berlin."),
            runID: UUID()
        )
        #expect(summary.added == 1, "tier 1 must land even when tier 2 refuses")
        #expect(summary.archived == 0)
        let lines = await tracer.snapshot().compactMap { event -> String? in
            if case .info(_, let category, let message) = event, category == MemoryTrace.category { return message }
            return nil
        }
        #expect(lines.contains { $0.hasPrefix("event=archive_failed ") })
    }

    @Test("the trace carries one memory.consolidated per pass with real counts")
    func tracesStructuredCounts() async throws {
        let store = InMemoryFactStore()
        let tracer = InMemoryTracer()
        let runID = UUID()
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleFixtures.tailExtractor(predicate: "location", marker: "I live in "),
            tracer: tracer,
            clock: LifecycleClock(LifecycleFixtures.epoch).read
        )
        _ = await consolidator.consolidate(LifecycleFixtures.turn(user: "I live in Berlin."), runID: runID)
        let consolidated = await tracer.snapshot().filter { $0.label == "memory.consolidated" }
        #expect(consolidated.count == 1)
        guard case .memoryConsolidated(let id, let extracted, let added, _, _, let archived, let calls, _) = try #require(consolidated.first) else {
            Issue.record("expected .memoryConsolidated")
            return
        }
        #expect(id == runID)
        #expect(extracted == 1)
        #expect(added == 1)
        #expect(archived == 0)
        #expect(calls == 0, "the deterministic configuration issues no model calls")
    }

    @Test("the model-call meter reports what the write path actually spent")
    func modelCallMeterIsReported() async throws {
        let store = InMemoryFactStore()
        let tracer = InMemoryTracer()
        let meter = MemoryModelCallMeter()
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleExtractor { turn, context in
                meter.recordCall()
                meter.recordCall()
                let content = turn.userMessage.content
                return [LifecycleFixtures.candidate(from: turn, predicate: "note", text: content, now: context.now)]
            },
            tracer: tracer,
            modelCallMeter: meter,
            clock: LifecycleClock(LifecycleFixtures.epoch).read
        )
        let summary = await consolidator.consolidate(LifecycleFixtures.turn(user: "remember this"), runID: UUID())
        #expect(summary.modelCalls == 2)
        // The meter is reset per pass, so a second pass reports its own
        // cost rather than a running total.
        let second = await consolidator.consolidate(LifecycleFixtures.turn(user: "remember this"), runID: UUID())
        #expect(second.modelCalls == 2)
    }
}

// MARK: - Background maintenance

@Suite("MemoryMaintenance")
struct MemoryMaintenanceTests {
    private func makeConsolidator(
        store: any MemoryStore,
        tracer: any Tracer,
        clock: LifecycleClock
    ) -> MemoryConsolidator {
        MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleFixtures.tailExtractor(predicate: "location", marker: "I live in "),
            tracer: tracer,
            clock: clock.read
        )
    }

    @Test("a clean pass finishes and drains the queue")
    func cleanPassFinishes() async throws {
        let store = InMemoryFactStore()
        let tracer = InMemoryTracer()
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        let consolidator = makeConsolidator(store: store, tracer: tracer, clock: clock)
        await consolidator.turnCompleted(
            LifecycleFixtures.turn(user: "I live in Berlin."),
            runContext: LifecycleFixtures.context()
        )
        let activity = MemoryMaintenance.activity(
            identifier: "test.memory.maintenance",
            consolidator: consolidator,
            store: store,
            tracer: tracer,
            clock: clock.read
        )
        #expect(await activity.runToCompletion() == .finished)
        #expect(await consolidator.queuedCount == 0)
        #expect(try await store.allIDs().count == 1)

        let events = await tracer.snapshot()
        let lines = events.compactMap { event -> String? in
            if case .info(_, let category, let message) = event, category == MemoryTrace.category { return message }
            return nil
        }
        #expect(lines.contains { $0.hasPrefix("event=maintenance_drain ") })
        #expect(lines.contains { $0.hasPrefix("event=sweep ") })
    }

    @Test("a failing step defers rather than half-finishing")
    func failingStepDefers() async throws {
        struct BrokenStore: MemoryStore {
            struct Boom: Error {}
            func upsert(_: [Fact]) async throws { throw Boom() }
            func fact(id _: String) async throws -> Fact? { throw Boom() }
            func query(_: MemoryQuery) async throws -> [Fact] { throw Boom() }
            func similar(to _: String, slot _: FactSlot?, threadID _: String?, limit _: Int, now _: Date) async throws -> [ScoredFact] { throw Boom() }
            func touch(ids _: [String], at _: Date) async throws { throw Boom() }
            func invalidate(ids _: [String], validUntil _: Date?, at _: Date, reason _: InvalidationReason) async throws -> Int { throw Boom() }
            func purge(ids _: [String]) async throws -> Int { throw Boom() }
            func purge(matching _: PurgePredicate) async throws -> [String] { throw Boom() }
            func allIDs() async throws -> [String] { throw Boom() }
            func removeAll() async throws { throw Boom() }
        }
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        let consolidator = MemoryConsolidator(
            memory: BrokenStore(),
            conversation: InMemoryConversationStore(),
            extractor: LifecycleExtractor { _, _ in [] },
            clock: clock.read
        )
        let activity = MemoryMaintenance.activity(
            identifier: "test.memory.maintenance.broken",
            consolidator: consolidator,
            store: BrokenStore(),
            clock: clock.read
        )
        // The sweep throws, so the whole pass defers and the scheduler
        // retries it from the top.
        #expect(await activity.runToCompletion() == .deferred)
    }

    @Test("a cancelled pass defers and leaves work a re-run repairs")
    func cancelledPassIsResumable() async throws {
        let store = InMemoryFactStore()
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        let slow = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleExtractor { turn, context in
                try await Task.sleep(for: .seconds(30))
                return [LifecycleFixtures.candidate(from: turn, predicate: "x", text: turn.userMessage.content, now: context.now)]
            },
            perTurnDeadline: .seconds(60),
            clock: clock.read
        )
        await slow.turnCompleted(
            LifecycleFixtures.turn(user: "I live in Berlin."),
            runContext: LifecycleFixtures.context()
        )
        let activity = MemoryMaintenance.activity(
            identifier: "test.memory.maintenance.cancel",
            consolidator: slow,
            store: store,
            clock: clock.read
        )
        let task = Task { await activity.runToCompletion() }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        #expect(await task.value == .deferred)
        #expect(try await store.allIDs().isEmpty, "an aborted pass must not half-write")
        #expect(await slow.queuedCount == 1, "the turn stays queued for the next pass")

        // A re-run with a working extractor repairs the state.
        let repaired = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleFixtures.tailExtractor(predicate: "location", marker: "I live in "),
            clock: clock.read
        )
        await repaired.turnCompleted(
            LifecycleFixtures.turn(user: "I live in Berlin."),
            runContext: LifecycleFixtures.context()
        )
        let retry = MemoryMaintenance.activity(
            identifier: "test.memory.maintenance.cancel",
            consolidator: repaired,
            store: store,
            clock: clock.read
        )
        #expect(await retry.runToCompletion() == .finished)
        #expect(try await store.allIDs().count == 1)
    }

    @Test("a pending archival removal is retried and cleared by the next pass")
    func pendingRemovalIsRetried() async throws {
        let store = InMemoryFactStore()
        let bm25 = BM25Retriever()
        let flaky = LifecycleFlakyIndex()
        let archive = IndexedArchivalStore(
            indexes: [BM25Index(bm25), flaky],
            reader: bm25,
            journal: InMemoryArchivalJournal()
        )
        let round = RoundBuilder.rounds(
            from: [.user("I live in Berlin."), .assistant("Noted.")],
            threadID: "t1"
        ).rounds
        try await archive.archive(round)
        #expect(try await archive.count() == 1)

        // One index refuses the delete: the content survives there, which
        // is precisely the "forgotten everywhere except one index" failure
        // the retry queue exists to close.
        await flaky.setFailing(true)
        await #expect(throws: MemoryError.self) {
            _ = try await archive.remove(chunkIDs: round.map(\.id))
        }
        #expect(try await archive.pendingRemovalIDs() == round.map(\.id))
        #expect(await flaky.contains(id: round[0].id))

        await flaky.setFailing(false)
        let tracer = InMemoryTracer()
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        let consolidator = MemoryConsolidator(
            memory: store,
            archive: archive,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleExtractor { _, _ in [] },
            tracer: tracer,
            clock: clock.read
        )
        let activity = MemoryMaintenance.activity(
            identifier: "test.memory.maintenance.pending",
            consolidator: consolidator,
            store: store,
            archive: archive,
            tracer: tracer,
            clock: clock.read
        )
        #expect(await activity.runToCompletion() == .finished)
        #expect(try await archive.pendingRemovalIDs().isEmpty)
        #expect(!(await flaky.contains(id: round[0].id)), "the retry must actually reach the failed index")

        let lines = await tracer.snapshot().compactMap { event -> String? in
            if case .info(_, let category, let message) = event, category == MemoryTrace.category { return message }
            return nil
        }
        #expect(lines.contains { $0.hasPrefix("event=pending_removals ") && $0.contains("cleared=1") })
    }

    @Test("maintenance never purges")
    func maintenanceNeverPurges() async throws {
        let store = PurgeTripwireStore()
        let clock = LifecycleClock(LifecycleFixtures.epoch)
        let consolidator = MemoryConsolidator(
            memory: store,
            conversation: InMemoryConversationStore(),
            extractor: LifecycleFixtures.tailExtractor(predicate: "location", marker: "I live in "),
            clock: clock.read
        )
        await consolidator.turnCompleted(
            LifecycleFixtures.turn(user: "I live in Berlin."),
            runContext: LifecycleFixtures.context()
        )
        let activity = MemoryMaintenance.activity(
            identifier: "test.memory.maintenance.purge",
            consolidator: consolidator,
            store: store,
            forgetting: ForgettingPolicy(
                defaultTimeToLive: .seconds(1),
                minimumRetainedConfidence: 0,
                maxLiveFactsPerThread: 1
            ),
            clock: { LifecycleFixtures.epoch.addingTimeInterval(86_400) }
        )
        #expect(await activity.runToCompletion() == .finished)
        #expect(await store.purgeCalls == 0, "forgetting invalidates; only a compliance call may purge")
    }

    @Test("the memory info grammar is key=value with a leading event")
    func traceGrammar() {
        let line = MemoryTrace.message(event: "sweep", [("expired", "2"), ("evicted", "0")])
        #expect(line == "event=sweep expired=2 evicted=0")
        #expect(MemoryTrace.message(event: "drain") == "event=drain")
        #expect(MemoryTrace.category == "memory")
    }

    @Test("a host-supplied value cannot break the grammar or forge a line")
    func traceGrammarSanitizesHostValues() {
        // A thread id comes from `RunContext.metadata` and is whatever the
        // application put there. Unsanitized, the first of these would
        // split into three bogus pairs and the second would forge a whole
        // second log line.
        let spaced = MemoryTrace.message(event: "archive_degraded", [("thread", "my thread id")])
        #expect(spaced == "event=archive_degraded thread=my_thread_id")

        let forged = MemoryTrace.message(event: "sweep", [("thread", "a\nevent=purge count=999")])
        #expect(!forged.contains("\n"))
        #expect(forged == "event=sweep thread=a_event=purge_count=999")

        // Every line the grammar produces has exactly one token per pair.
        for line in [spaced, forged, MemoryTrace.message(event: "drain", [("thread", "   ")])] {
            let tokens = line.split(separator: " ")
            #expect(tokens.allSatisfy { $0.contains("=") })
            #expect(tokens.first?.hasPrefix("event=") == true)
        }
        // An all-whitespace value still yields a parseable pair.
        #expect(MemoryTrace.message(event: "drain", [("thread", "   ")]) == "event=drain thread=_")
    }
}
