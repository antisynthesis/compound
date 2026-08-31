import Foundation
import Testing
@testable import Compound

/// Deterministic stand-in for a sentence embedder: a hashed bag-of-tokens
/// projected onto a small fixed-dimension vector. Never touches
/// `NLEmbedding`, which is unavailable on CommandLineTools CI hosts and
/// would make these assertions machine-dependent.
private struct ArchivalHashEmbedder: EmbeddingProvider {
    let dimension = 24

    func embed(_ text: String) async throws -> [Double] {
        var vector = [Double](repeating: 0, count: dimension)
        for token in BM25Retriever.defaultTokenize(text) {
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in token.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            vector[Int(hash % UInt64(dimension))] += 1
        }
        // A zero vector would be skipped by DenseRetriever; pin a floor so
        // every chunk is genuinely indexed.
        if vector.allSatisfy({ $0 == 0 }) { vector[0] = 1 }
        return vector
    }
}

/// Records every write it is asked to perform, and can be told to start
/// failing so the fan-out path can be exercised.
private actor ArchivalSpyIndex: MutableTextIndex {
    nonisolated let indexName: String
    private(set) var upsertedIDs: [[String]] = []
    private(set) var removedIDs: [[String]] = []
    private var indexed: Set<String> = []
    private var failing = false

    init(indexName: String) { self.indexName = indexName }

    func setFailing(_ value: Bool) { failing = value }

    func upsert(_ chunks: [DocumentChunk]) throws {
        upsertedIDs.append(chunks.map(\.id))
        if failing { throw ArchivalSpyFailure() }
        indexed.formUnion(chunks.map(\.id))
    }

    @discardableResult
    func remove(ids: [String]) throws -> Int {
        removedIDs.append(ids)
        if failing { throw ArchivalSpyFailure() }
        var removed = 0
        for id in ids where indexed.remove(id) != nil { removed += 1 }
        return removed
    }

    func contains(id: String) -> Bool { indexed.contains(id) }
}

private struct ArchivalSpyFailure: Error {}

/// Lock-guarded collector for the store's inconsistency hook, which fires
/// off the store's own task.
private final class InconsistencyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(message)
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

@Suite("ArchivalStore")
struct ArchivalStoreTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static func message(
        _ role: ConversationMessage.Role,
        _ content: String,
        offset: TimeInterval
    ) -> ConversationMessage {
        ConversationMessage(
            id: UUID(),
            role: role,
            content: content,
            createdAt: epoch.addingTimeInterval(offset),
            metadata: [:]
        )
    }

    private static func rounds(_ threadID: String = "t1") -> [ArchivedRound] {
        RoundBuilder.rounds(
            from: [
                message(.user, "when does the platform launch", offset: 0),
                message(.assistant, "the Platform Team shipped it on March 3, 2024.", offset: 1),
                message(.user, "who reviews the release notes", offset: 2),
                message(.assistant, "docs owns them", offset: 3),
            ],
            threadID: threadID
        ).rounds
    }

    // MARK: - Archive and retrieve

    @Test("archive then retrieve serves display text with provenance in the title")
    func archiveThenRetrieveServesDisplayText() async throws {
        let bm25 = BM25Retriever()
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25)],
            reader: bm25,
            journal: InMemoryArchivalJournal()
        )
        let rounds = Self.rounds()
        try await store.archive(rounds)

        let hits = try await store.retrieve(query: "platform launch", limit: 5, threadID: nil)
        #expect(hits.count >= 1)
        let hit = try #require(hits.first { $0.round.ordinal == 0 })
        #expect(hit.round.displayText.hasPrefix("user: when does the platform launch"))

        let source = hit.retrievedSource
        #expect(source.id == hit.round.id)
        #expect(source.content == hit.round.displayText)
        // The index text carries the key line; the served content must not.
        #expect(source.content != hit.round.indexText)
        #expect(source.title.hasPrefix("thread t1 round 0 ["))
        #expect(source.score != nil)
    }

    @Test("archived rounds keep provenance back to the original message ids")
    func provenanceBackToMessageIDs() async throws {
        let messages = [
            Self.message(.user, "first question", offset: 0),
            Self.message(.assistant, "first answer", offset: 1),
        ]
        let built = RoundBuilder.rounds(from: messages, threadID: "t1")
        let bm25 = BM25Retriever()
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25)],
            reader: bm25,
            journal: InMemoryArchivalJournal()
        )
        try await store.archive(built.rounds)

        let hits = try await store.retrieve(query: "first question", limit: 3, threadID: nil)
        let hit = try #require(hits.first)
        #expect(hit.round.messageIDs == messages.map(\.id))
        let looked = try await store.round(chunkID: hit.round.id)
        #expect(looked?.messageIDs == messages.map(\.id))
    }

    @Test("a query matching only a key-line term retrieves the round, and the key line is not served")
    func keyExpansionRetrievesWithoutLeaking() async throws {
        let bm25 = BM25Retriever()
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25)],
            reader: bm25,
            journal: InMemoryArchivalJournal()
        )
        let dated = RoundBuilder.rounds(
            from: [Self.message(.user, "we shipped it on March 3, 2024.", offset: 0)],
            threadID: "t1"
        ).rounds
        let undated = RoundBuilder.rounds(
            from: [Self.message(.user, "nothing to report here", offset: 10)],
            threadID: "t1",
            ordinals: [:],
            nextOrdinal: 1
        ).rounds
        try await store.archive(dated + undated)

        // "03" is a token of the derived ISO day and of nothing else: the
        // round says "March 3, 2024", which tokenizes to march/3/2024. So a
        // query for "03" can only be answered through the key line.
        #expect(!BM25Retriever.defaultTokenize(dated[0].displayText).contains("03"))
        #expect(BM25Retriever.defaultTokenize(dated[0].indexText).contains("03"))

        let hits = try await store.retrieve(query: "03", limit: 5, threadID: nil)
        #expect(hits.count == 1)
        #expect(hits[0].round.id == dated[0].id)
        // ...and the key that earned the hit is not part of what the model
        // is shown.
        #expect(!hits[0].retrievedSource.content.contains("2024-03-03"))
        #expect(hits[0].retrievedSource.content == dated[0].displayText)
    }

    @Test("re-archiving the same round does not duplicate postings or move statistics")
    func reArchivingIsIdempotent() async throws {
        let bm25 = BM25Retriever()
        let journal = InMemoryArchivalJournal()
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25)],
            reader: bm25,
            journal: journal
        )
        let rounds = Self.rounds()
        try await store.archive(rounds)
        let countAfterFirst = await bm25.count
        let averageAfterFirst = await bm25.averageDocumentLength
        let frequencyAfterFirst = await bm25.documentFrequency(of: "platform")

        try await store.archive(rounds)
        try await store.archive(rounds + rounds)

        #expect(await bm25.count == countAfterFirst)
        #expect(await bm25.averageDocumentLength == averageAfterFirst)
        #expect(await bm25.documentFrequency(of: "platform") == frequencyAfterFirst)
        #expect(try await store.count() == rounds.count)
    }

    @Test("removal restores index statistics exactly")
    func removalRestoresStatistics() async throws {
        let bm25 = BM25Retriever()
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25)],
            reader: bm25,
            journal: InMemoryArchivalJournal()
        )
        let baseRounds = Self.rounds()
        try await store.archive(baseRounds)
        let baselineCount = await bm25.count
        let baselineAverage = await bm25.averageDocumentLength
        let baselineFrequency = await bm25.documentFrequency(of: "platform")

        let extra = RoundBuilder.rounds(
            from: [Self.message(.user, "the platform is also fast", offset: 20)],
            threadID: "t1",
            ordinals: [:],
            nextOrdinal: 99
        ).rounds
        try await store.archive(extra)
        #expect(await bm25.documentFrequency(of: "platform") == baselineFrequency + 1)

        try await store.remove(chunkIDs: extra.map(\.id))
        #expect(await bm25.count == baselineCount)
        #expect(await bm25.averageDocumentLength == baselineAverage)
        #expect(await bm25.documentFrequency(of: "platform") == baselineFrequency)
    }

    // MARK: - Removal fan-out

    @Test("one removal reaches every index")
    func removalFansOut() async throws {
        let left = ArchivalSpyIndex(indexName: "left")
        let right = ArchivalSpyIndex(indexName: "right")
        let store = IndexedArchivalStore(
            indexes: [left, right],
            reader: EmptyRetriever(),
            journal: InMemoryArchivalJournal()
        )
        let rounds = Self.rounds()
        try await store.archive(rounds)
        try await store.remove(chunkIDs: [rounds[0].id])

        #expect(await left.removedIDs == [[rounds[0].id]])
        #expect(await right.removedIDs == [[rounds[0].id]])
        #expect(await left.contains(id: rounds[0].id) == false)
        #expect(await right.contains(id: rounds[0].id) == false)
    }

    @Test("after removal neither the lexical nor the dense index still holds the posting")
    func removalClearsBothRealIndexes() async throws {
        let bm25 = BM25Retriever()
        let dense = DenseRetriever(provider: ArchivalHashEmbedder())
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25), DenseIndex(dense)],
            reader: HybridRetriever(retrievers: [bm25, dense]),
            journal: InMemoryArchivalJournal()
        )
        let rounds = Self.rounds()
        try await store.archive(rounds)
        #expect(await bm25.contains(id: rounds[0].id))
        #expect(await dense.contains(id: rounds[0].id))

        let before = try await store.retrieve(query: "platform launch", limit: 5, threadID: nil)
        #expect(before.contains { $0.round.id == rounds[0].id })

        try await store.remove(chunkIDs: [rounds[0].id])
        #expect(await bm25.contains(id: rounds[0].id) == false)
        #expect(await dense.contains(id: rounds[0].id) == false)
        let after = try await store.retrieve(query: "platform launch", limit: 5, threadID: nil)
        #expect(!after.contains { $0.round.id == rounds[0].id })
    }

    @Test("a failing index throws partialRemoval, queues the id, and is retried on the next archive")
    func partialRemovalIsQueuedAndRetried() async throws {
        let bm25 = BM25Retriever()
        let spy = ArchivalSpyIndex(indexName: "spy")
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25), spy],
            reader: bm25,
            journal: InMemoryArchivalJournal()
        )
        let rounds = Self.rounds()
        try await store.archive(rounds)
        await spy.setFailing(true)

        var thrown: MemoryError?
        do {
            try await store.remove(chunkIDs: [rounds[0].id])
        } catch let error as MemoryError {
            thrown = error
        }
        #expect(thrown == .partialRemoval(chunkIDs: [rounds[0].id], failedIndexes: ["spy"]))
        // The index that took the delete really took it...
        #expect(await bm25.contains(id: rounds[0].id) == false)
        // ...and the one that refused is on the retry list.
        #expect(try await store.pendingRemovalIDs() == [rounds[0].id])
        #expect(await spy.contains(id: rounds[0].id))

        await spy.setFailing(false)
        let later = RoundBuilder.rounds(
            from: [Self.message(.user, "a later turn", offset: 30)],
            threadID: "t1",
            ordinals: [:],
            nextOrdinal: 50
        ).rounds
        try await store.archive(later)

        #expect(try await store.pendingRemovalIDs().isEmpty)
        #expect(await spy.contains(id: rounds[0].id) == false)
    }

    @Test("a removal the journal recorded is dropped even when an index refuses")
    func partialRemovalStillDropsTheRound() async throws {
        let spy = ArchivalSpyIndex(indexName: "spy")
        let store = IndexedArchivalStore(
            indexes: [spy],
            reader: EmptyRetriever(),
            journal: InMemoryArchivalJournal()
        )
        let rounds = Self.rounds()
        try await store.archive(rounds)
        await spy.setFailing(true)
        _ = try? await store.remove(chunkIDs: [rounds[0].id])
        #expect(try await store.round(chunkID: rounds[0].id) == nil)
        #expect(try await store.count() == rounds.count - 1)
    }

    @Test("removeThread removes that thread and leaves the others alone")
    func removeThreadIsScoped() async throws {
        let bm25 = BM25Retriever()
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25)],
            reader: bm25,
            journal: InMemoryArchivalJournal()
        )
        let a = Self.rounds("thread-a")
        let b = RoundBuilder.rounds(
            from: [Self.message(.user, "a different conversation entirely", offset: 40)],
            threadID: "thread-b"
        ).rounds
        try await store.archive(a + b)

        let removed = try await store.removeThread("thread-a")
        #expect(Set(removed) == Set(a.map(\.id)))
        #expect(try await store.count() == b.count)
        for id in a.map(\.id) {
            #expect(await bm25.contains(id: id) == false)
        }
        #expect(await bm25.contains(id: b[0].id))
    }

    // MARK: - Rehydration and torn state

    @Test("rehydrate restores retrievability over fresh retrievers and is idempotent")
    func rehydrateIsIdempotent() async throws {
        let journal = InMemoryArchivalJournal()
        let warm = BM25Retriever()
        let writer = IndexedArchivalStore(
            indexes: [BM25Index(warm)],
            reader: warm,
            journal: journal
        )
        let rounds = Self.rounds()
        try await writer.archive(rounds)

        // A fresh process: the journal survived, the in-memory index did not.
        let cold = BM25Retriever()
        let reloaded = IndexedArchivalStore(
            indexes: [BM25Index(cold)],
            reader: cold,
            journal: journal
        )
        #expect(try await reloaded.retrieve(query: "platform launch", limit: 5, threadID: nil).isEmpty)

        try await reloaded.rehydrate()
        let afterFirst = try await reloaded.retrieve(query: "platform launch", limit: 5, threadID: nil)
        #expect(!afterFirst.isEmpty)
        let countAfterFirst = await cold.count
        let averageAfterFirst = await cold.averageDocumentLength

        try await reloaded.rehydrate()
        #expect(await cold.count == countAfterFirst)
        #expect(await cold.averageDocumentLength == averageAfterFirst)
        let afterSecond = try await reloaded.retrieve(query: "platform launch", limit: 5, threadID: nil)
        #expect(afterSecond.map(\.round.id) == afterFirst.map(\.round.id))
    }

    @Test("a posting with no journal entry is skipped and reported, not fatal")
    func tornStateIsSkipped() async throws {
        let log = InconsistencyLog()
        let bm25 = BM25Retriever()
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25)],
            reader: bm25,
            journal: InMemoryArchivalJournal(),
            onInconsistency: { log.record($0) }
        )
        let rounds = Self.rounds()
        try await store.archive(rounds)
        // Something else wrote a posting the journal never heard about.
        await bm25.index(DocumentChunk(
            documentID: RoundBuilder.documentID(threadID: "t1"),
            ordinal: 999,
            content: "user: orphaned platform posting"
        ))

        let hits = try await store.retrieve(query: "platform", limit: 10, threadID: nil)
        #expect(hits.allSatisfy { round in rounds.contains { $0.id == round.round.id } })
        #expect(log.messages.contains { $0.contains("no journal entry") })
    }

    @Test("thread scoping filters hits from other threads")
    func retrievalIsThreadScoped() async throws {
        let bm25 = BM25Retriever()
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25)],
            reader: bm25,
            journal: InMemoryArchivalJournal()
        )
        let a = RoundBuilder.rounds(
            from: [Self.message(.user, "the platform ships on friday", offset: 0)],
            threadID: "thread-a"
        ).rounds
        let b = RoundBuilder.rounds(
            from: [Self.message(.user, "the platform ships on monday", offset: 1)],
            threadID: "thread-b"
        ).rounds
        try await store.archive(a + b)

        let scoped = try await store.retrieve(query: "platform ships", limit: 5, threadID: "thread-b")
        #expect(scoped.count == 1)
        #expect(scoped[0].round.threadID == "thread-b")

        let facade = ArchivalRetriever(store: store, threadID: "thread-a")
        let sources = try await facade.retrieve(query: "platform ships", limit: 5)
        #expect(sources.count == 1)
        #expect(sources[0].title.hasPrefix("thread thread-a"))
    }

    // MARK: - Determinism and durability

    @Test("the same corpus and query return the same ordered ids across 20 runs")
    func retrievalIsDeterministic() async throws {
        let bm25 = BM25Retriever()
        let dense = DenseRetriever(provider: ArchivalHashEmbedder())
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25), DenseIndex(dense)],
            reader: HybridRetriever(retrievers: [bm25, dense]),
            journal: InMemoryArchivalJournal()
        )
        try await store.archive(Self.rounds())
        let first = try await store.retrieve(query: "platform release notes", limit: 5, threadID: nil)
            .map(\.round.id)
        #expect(!first.isEmpty)
        for _ in 0..<20 {
            let again = try await store.retrieve(query: "platform release notes", limit: 5, threadID: nil)
                .map(\.round.id)
            #expect(again == first)
        }
    }

    @Test("file journal round-trips through a fresh instance")
    func fileJournalRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("archival-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let bm25 = BM25Retriever()
        let store = IndexedArchivalStore(
            indexes: [BM25Index(bm25)],
            reader: bm25,
            journal: FileArchivalJournal(fileURL: url)
        )
        let rounds = Self.rounds()
        try await store.archive(rounds)

        let reloaded = try await FileArchivalJournal(fileURL: url).load()
        #expect(reloaded.schemaVersion == ArchivalSnapshot.currentSchemaVersion)
        #expect(Set(reloaded.rounds.map(\.id)) == Set(rounds.map(\.id)))
        #expect(reloaded.rounds.first?.displayText == rounds.first?.displayText)
        #expect(reloaded.nextOrdinal["t1"] == rounds.count)
        let ledger = reloaded.ledger(threadID: "t1")
        #expect(ledger.nextOrdinal == rounds.count)
        #expect(ledger.ordinals.count == rounds.count)
    }

    @Test("a missing journal file loads as empty, a corrupt one throws")
    func fileJournalFailsLoudlyOnCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archival-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("absent.json")
        #expect(try await FileArchivalJournal(fileURL: missing).load() == .empty)

        let corrupt = directory.appendingPathComponent("corrupt.json")
        try Data("{ not json at all".utf8).write(to: corrupt)
        let journal = FileArchivalJournal(fileURL: corrupt)
        await #expect(throws: MemoryError.self) { try await journal.load() }
    }

    @Test("a journal from a newer schema is rejected rather than silently misread")
    func fileJournalRejectsUnknownSchema() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("archival-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var snapshot = ArchivalSnapshot()
        snapshot.schemaVersion = ArchivalSnapshot.currentSchemaVersion + 1
        try encoder.encode(snapshot).write(to: url)

        let journal = FileArchivalJournal(fileURL: url)
        var thrown: MemoryError?
        do {
            _ = try await journal.load()
        } catch let error as MemoryError {
            thrown = error
        }
        #expect(thrown == .schemaVersionUnsupported(
            found: ArchivalSnapshot.currentSchemaVersion + 1,
            supported: ArchivalSnapshot.currentSchemaVersion
        ))
    }

    @Test("the ordinal ledger survives a restart so re-archiving stays idempotent")
    func ledgerSurvivesRestart() async throws {
        let journal = InMemoryArchivalJournal()
        let messages = [
            Self.message(.user, "first", offset: 0),
            Self.message(.assistant, "answer", offset: 1),
            Self.message(.user, "second", offset: 2),
        ]
        let warm = BM25Retriever()
        let writer = IndexedArchivalStore(indexes: [BM25Index(warm)], reader: warm, journal: journal)
        let built = RoundBuilder.rounds(from: messages, threadID: "t1")
        try await writer.archive(built.rounds)

        let cold = BM25Retriever()
        let reloaded = IndexedArchivalStore(indexes: [BM25Index(cold)], reader: cold, journal: journal)
        let ledger = try await reloaded.ledger(threadID: "t1")
        let rebuilt = RoundBuilder.rounds(
            from: messages,
            threadID: "t1",
            ordinals: ledger.ordinals,
            nextOrdinal: ledger.nextOrdinal
        )
        #expect(rebuilt.rounds == built.rounds)
        try await reloaded.archive(rebuilt.rounds)
        #expect(try await reloaded.count() == built.rounds.count)
    }
}
