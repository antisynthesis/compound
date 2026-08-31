import Foundation

/// Everything ``IndexedArchivalStore`` must survive a process restart
/// with: the archived rounds themselves, the ordinal ledger that keeps
/// re-archiving idempotent, and the removals that have not yet reached
/// every index.
///
/// This is the *side table*, and it is the reason the index-text /
/// display-text split needs no change to ``DocumentChunk``: the indexes
/// hold ``ArchivedRound/indexText``, the snapshot holds the round, and
/// the store re-joins them on the chunk id at read time.
public struct ArchivalSnapshot: Sendable, Equatable, Codable {
    /// On-disk schema version. Bump only with a migration.
    public static let currentSchemaVersion = 1

    /// Schema version of this snapshot.
    public var schemaVersion: Int
    /// Archived rounds, one per chunk id.
    public var rounds: [ArchivedRound]
    /// Round-first-message-id (as a UUID string) → assigned ordinal.
    /// Keyed by string because `UUID` is not a `Codable` dictionary key.
    public var ordinals: [String: Int]
    /// Thread id → next unused ordinal.
    public var nextOrdinal: [String: Int]
    /// Chunk ids whose removal reached some indexes but not all. Retried
    /// at the head of every subsequent mutating call and by
    /// `MemoryMaintenance`.
    public var pendingRemovals: [String]

    /// Creates a snapshot.
    public init(
        schemaVersion: Int = ArchivalSnapshot.currentSchemaVersion,
        rounds: [ArchivedRound] = [],
        ordinals: [String: Int] = [:],
        nextOrdinal: [String: Int] = [:],
        pendingRemovals: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.rounds = rounds
        self.ordinals = ordinals
        self.nextOrdinal = nextOrdinal
        self.pendingRemovals = pendingRemovals
    }

    /// An empty snapshot at the current schema version.
    public static let empty = ArchivalSnapshot()

    /// The ordinal ledger for `threadID`, in the shape
    /// ``RoundBuilder/rounds(from:threadID:ordinals:nextOrdinal:)`` wants.
    ///
    /// Entries whose UUID string does not parse are skipped rather than
    /// trapping: a hand-edited journal must degrade to "this round looks
    /// new", not crash the archive.
    public func ledger(threadID: String) -> (ordinals: [UUID: Int], nextOrdinal: Int) {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(ordinals.count)
        for (key, value) in ordinals {
            guard let uuid = UUID(uuidString: key) else { continue }
            map[uuid] = value
        }
        return (map, nextOrdinal[threadID] ?? 0)
    }
}

/// Durability boundary for ``ArchivalSnapshot``.
///
/// Split from the store for the same reason ``ConversationStore`` is
/// split from the assembler: applications that already have a database
/// should not have to adopt a second file format to use the archive.
public protocol ArchivalJournal: Sendable {
    /// Loads the snapshot, or ``ArchivalSnapshot/empty`` if none exists.
    func load() async throws -> ArchivalSnapshot
    /// Persists `snapshot`, replacing any previous one.
    func save(_ snapshot: ArchivalSnapshot) async throws
}

/// Process-local journal. The right default for tests and for
/// short-lived sessions where the archive need not outlive the process.
public actor InMemoryArchivalJournal: ArchivalJournal {
    private var snapshot: ArchivalSnapshot

    /// Creates a journal holding `snapshot`.
    public init(_ snapshot: ArchivalSnapshot = .empty) {
        self.snapshot = snapshot
    }

    /// Returns the held snapshot.
    public func load() async throws -> ArchivalSnapshot { snapshot }

    /// Replaces the held snapshot.
    public func save(_ snapshot: ArchivalSnapshot) async throws {
        self.snapshot = snapshot
        saveCount += 1
    }

    /// Number of persisted writes, exposed for tests that assert the
    /// store persists exactly when it mutates.
    public private(set) var saveCount: Int = 0
}

/// File-backed journal. Writes a single JSON document atomically.
///
/// Unlike ``JSONLConversationStore``, which skips undecodable lines to
/// stay recoverable from a torn append, a corrupt archival journal throws
/// ``MemoryError/corruptStore(path:detail:)``. The difference is
/// deliberate: a dropped conversation line is a cosmetic gap in history,
/// while a dropped journal entry silently orphans an index posting —
/// content the user believes was forgotten stays retrievable, or content
/// they expect to recall disappears. Failing loudly is the only honest
/// option for user memory.
public actor FileArchivalJournal: ArchivalJournal {
    /// File the journal reads and writes.
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a journal at `fileURL`. The file is not created until the
    /// first ``save(_:)``; ``load()`` on a missing file returns
    /// ``ArchivalSnapshot/empty``.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys so the file diffs cleanly and two runs that produce
        // the same snapshot produce the same bytes.
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Reads and decodes the snapshot.
    ///
    /// - Throws: ``MemoryError/corruptStore(path:detail:)`` if the file
    ///   exists but does not decode, or
    ///   ``MemoryError/schemaVersionUnsupported(found:supported:)`` if it
    ///   was written by a newer schema.
    public func load() async throws -> ArchivalSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw MemoryError.corruptStore(path: fileURL.path, detail: "unreadable: \(error)")
        }
        guard !data.isEmpty else { return .empty }
        let snapshot: ArchivalSnapshot
        do {
            snapshot = try decoder.decode(ArchivalSnapshot.self, from: data)
        } catch {
            throw MemoryError.corruptStore(path: fileURL.path, detail: "\(error)")
        }
        guard snapshot.schemaVersion == ArchivalSnapshot.currentSchemaVersion else {
            throw MemoryError.schemaVersionUnsupported(
                found: snapshot.schemaVersion,
                supported: ArchivalSnapshot.currentSchemaVersion
            )
        }
        return snapshot
    }

    /// Encodes and writes `snapshot` atomically (a temp-file write plus a
    /// rename on Darwin), so a crash mid-write leaves the previous
    /// snapshot intact rather than a truncated one.
    public func save(_ snapshot: ArchivalSnapshot) async throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
        #if os(iOS) || os(visionOS)
        // Archived rounds are verbatim user conversation. Protect them at
        // rest; `completeUntilFirstUserAuthentication` is the strongest
        // class compatible with background maintenance passes that run
        // before the device is unlocked.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}
