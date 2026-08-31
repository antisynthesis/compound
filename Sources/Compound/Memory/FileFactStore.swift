import Foundation

/// Durable, file-backed ``MemoryStore``.
///
/// Holds the same in-memory structures as ``InMemoryFactStore`` and
/// mirrors them to a single JSON snapshot after every mutation. The
/// envelope is `{ "schemaVersion": Int, "facts": [Fact] }`.
///
/// **Writes are atomic.** Every rewrite goes through
/// `Data.write(to:options: [.atomic])`, which on Darwin writes a
/// temporary file and renames it into place, so a crash mid-write leaves
/// either the previous complete snapshot or the new one — never a
/// half-written file. Facts are sorted by id and JSON keys are sorted
/// before encoding, so an unchanged store always produces byte-identical
/// output and the file diffs cleanly in a repository or a sync log.
///
/// **A corrupt file fails loudly.** Unlike ``JSONLConversationStore``,
/// which skips undecodable lines to stay recoverable from partial
/// appends, this store throws ``MemoryError/corruptStore(path:detail:)``
/// on any decode failure. The asymmetry is deliberate: a dropped
/// conversation line is a cosmetic gap in a transcript the user can
/// still read, whereas silently discarding a user's memory presents a
/// confidently wrong picture of what the system knows about them.
/// Failing loudly lets an application restore from backup or ask; a
/// silent reset cannot be noticed at all.
///
/// On iOS and visionOS the snapshot is written with
/// `.completeUntilFirstUserAuthentication` data protection. Memory is
/// user data and belongs behind the device passcode; that class is the
/// strongest one compatible with a background maintenance task, which
/// may run before the device is unlocked.
public actor FileFactStore: MemoryStore {
    /// Snapshot file this store owns.
    public let fileURL: URL
    /// Envelope version this build reads and writes.
    public static let schemaVersion = 1

    private var table: FactTable
    private let tokenizer: @Sendable (String) -> [String]
    private let scorer: SalienceScorer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// On-disk envelope.
    struct Snapshot: Codable {
        var schemaVersion: Int
        var facts: [Fact]
    }

    /// Opens (or creates) the store at `fileURL`.
    ///
    /// An absent file is created holding an empty envelope, so a fresh
    /// install and a deliberately emptied store are indistinguishable to
    /// every later call. An existing file is decoded eagerly: a store
    /// that cannot be read must fail at construction, not on the first
    /// query several turns into a session.
    ///
    /// - Throws: ``MemoryError/corruptStore(path:detail:)`` if the file
    ///   exists but does not decode;
    ///   ``MemoryError/schemaVersionUnsupported(found:supported:)`` if it
    ///   carries a version this build does not know.
    public init(
        fileURL: URL,
        tokenizer: @escaping @Sendable (String) -> [String] = BM25Retriever.defaultTokenize,
        scorer: SalienceScorer = SalienceScorer()
    ) throws {
        self.fileURL = fileURL
        self.tokenizer = tokenizer
        self.scorer = scorer
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw MemoryError.corruptStore(path: fileURL.path, detail: "unreadable: \(error)")
            }
            if data.isEmpty {
                // A zero-byte file is the one partial-write shape an
                // atomic rename can still leave behind (creation without
                // content, e.g. from `touch`). Treat it as empty rather
                // than corrupt so a fresh file created by tooling works.
                self.table = FactTable()
            } else {
                let snapshot: Snapshot
                do {
                    snapshot = try decoder.decode(Snapshot.self, from: data)
                } catch {
                    throw MemoryError.corruptStore(path: fileURL.path, detail: "\(error)")
                }
                guard snapshot.schemaVersion == FileFactStore.schemaVersion else {
                    throw MemoryError.schemaVersionUnsupported(
                        found: snapshot.schemaVersion,
                        supported: FileFactStore.schemaVersion
                    )
                }
                self.table = FactTable(facts: snapshot.facts)
            }
        } else {
            self.table = FactTable()
            try FileFactStore.write(
                FactTable(), to: fileURL, encoder: encoder
            )
        }
    }

    /// Number of stored records, live and retired.
    public var count: Int { table.count }

    /// Inserts or replaces `facts`, then rewrites the snapshot.
    public func upsert(_ facts: [Fact]) async throws {
        for fact in facts { table.insert(fact) }
        try persist()
    }

    /// Returns the record with `id`, or `nil`.
    public func fact(id: String) async throws -> Fact? { table.fact(id: id) }

    /// Runs a filtered, ordered, limited read. See ``MemoryQuery``.
    public func query(_ query: MemoryQuery) async throws -> [Fact] {
        table.query(query, scorer: scorer)
    }

    /// Ranks live facts by weighted-Jaccard lexical similarity.
    public func similar(to text: String, slot: FactSlot?, threadID: String?, limit: Int, now: Date) async throws -> [ScoredFact] {
        table.similar(to: text, slot: slot, threadID: threadID, limit: limit, now: now, tokenizer: tokenizer)
    }

    /// Bumps access metadata and rewrites the snapshot — but only when
    /// something actually changed, so a touch of unknown ids costs no
    /// disk write.
    public func touch(ids: [String], at instant: Date) async throws {
        let changed = table.touch(ids: ids, at: instant)
        if !changed.isEmpty { try persist() }
    }

    /// Retires records; returns how many actually changed.
    @discardableResult
    public func invalidate(ids: [String], validUntil: Date?, at instant: Date, reason: InvalidationReason) async throws -> Int {
        let changed = table.invalidate(ids: ids, validUntil: validUntil, at: instant)
        if changed > 0 { try persist() }
        return changed
    }

    /// Destructively removes records by id.
    @discardableResult
    public func purge(ids: [String]) async throws -> Int {
        let removed = table.purge(ids: ids)
        if removed > 0 { try persist() }
        return removed
    }

    /// Destructively removes every record matching `predicate`.
    @discardableResult
    public func purge(matching predicate: PurgePredicate) async throws -> [String] {
        let removed = table.purge(matching: predicate)
        if !removed.isEmpty { try persist() }
        return removed
    }

    /// Every stored id, sorted ascending.
    public func allIDs() async throws -> [String] { table.allIDs }

    /// Destructively removes everything and rewrites the snapshot.
    public func removeAll() async throws {
        table.removeAll()
        try persist()
    }

    /// Rewrites the snapshot unconditionally.
    ///
    /// Mutations already persist as they happen, so this is a barrier
    /// for callers that want an explicit "it is on disk now" point —
    /// before backgrounding, before a backup, or in a test that is about
    /// to open a second instance on the same URL.
    public func flush() async throws {
        try persist()
    }

    private func persist() throws {
        try FileFactStore.write(table, to: fileURL, encoder: encoder)
    }

    private static func write(_ table: FactTable, to url: URL, encoder: JSONEncoder) throws {
        // Sorting by id (rather than trusting dictionary order) is what
        // makes an unchanged store re-encode to identical bytes.
        let snapshot = Snapshot(
            schemaVersion: FileFactStore.schemaVersion,
            facts: table.allIDs.compactMap { table.fact(id: $0) }
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])
        #if os(iOS) || os(visionOS)
        // Best-effort: an atomic write replaces the inode, so the class
        // is reapplied after every rewrite rather than set once at
        // creation.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
