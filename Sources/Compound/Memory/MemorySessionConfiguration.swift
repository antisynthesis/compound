import Foundation

/// Sink for completed user/assistant exchanges.
///
/// ## Contract: return promptly, do not consolidate inline
///
/// ``turnCompleted(_:runContext:)`` is called by ``CompoundSession`` on
/// the critical path, immediately after a successful run. Implementations
/// **must** enqueue and return — extraction, reconciliation, and
/// archiving are background work and must not be performed here. A
/// conformer that consolidates inline adds its whole write path to the
/// latency of every user turn, which is the exact cost this design exists
/// to avoid: memory is justified here as a cost mechanism, and a write
/// path on the critical path spends the savings before they are earned.
///
/// `MemoryConsolidator` honors this contract: its `turnCompleted` is an
/// O(1) bounded-queue append, and the pipeline runs from an explicit
/// `drain` call driven by ``BackgroundCompoundActivity``. The freshness
/// gap that creates — a fact stated this turn may not be recallable until
/// the next maintenance pass — is an accepted, documented property of the
/// design, not an oversight.
public protocol MemoryTurnObserving: Sendable {
    /// Records that `turn` completed. Must return promptly.
    func turnCompleted(_ turn: MemoryTurn, runContext: RunContext) async
}

/// Observer that discards every turn. The default when a session wants
/// conversation recording without a write path wired up yet.
public struct NullMemoryTurnObserver: MemoryTurnObserving {
    /// Creates an instance.
    public init() {}
    /// Does nothing.
    public func turnCompleted(_: MemoryTurn, runContext _: RunContext) async {}
}

/// The memory surface a ``CompoundSession`` opts into.
///
/// Absent (``CompoundSession/Configuration/memory`` is `nil`) the session
/// behaves exactly as it did before this type existed: nothing is
/// appended, no observer is called, and no store is touched.
///
/// Threads are scoped through `RunContext.metadata` rather than through
/// ``ConversationStore``, which is a deliberate three-method whole-history
/// protocol whose conformers (in-tree and in applications) would all break
/// if a thread id were added to it.
public struct MemorySessionConfiguration: Sendable {
    /// Metadata key carrying the thread id, by convention.
    public static let defaultThreadIDMetadataKey = "compound.thread"
    /// Thread id used when the metadata key is absent.
    public static let defaultThreadID = "default"

    /// Store the session appends user and assistant turns to. The same
    /// store the read-path assembler reads history from.
    public var conversation: any ConversationStore
    /// Metadata key the thread id is read from.
    public var threadIDMetadataKey: String
    /// Whether the session appends turns to ``conversation`` itself.
    /// Set `false` when the application owns transcript writes; the
    /// observer is still notified, so consolidation keeps working.
    public var recordsTurns: Bool
    /// Write-path sink for completed turns.
    public var observer: (any MemoryTurnObserving)?
    /// Clock used to stamp appended messages. Injected so a test or an
    /// eval can produce byte-identical transcripts.
    public var clock: @Sendable () -> Date

    /// Creates a memory surface.
    public init(
        conversation: any ConversationStore,
        threadIDMetadataKey: String = MemorySessionConfiguration.defaultThreadIDMetadataKey,
        recordsTurns: Bool = true,
        observer: (any MemoryTurnObserving)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.conversation = conversation
        self.threadIDMetadataKey = threadIDMetadataKey
        self.recordsTurns = recordsTurns
        self.observer = observer
        self.clock = clock
    }

    /// Resolves the thread id for a run from its metadata.
    public func threadID(in metadata: [String: String]) -> String {
        MemorySessionConfiguration.threadID(in: metadata, key: threadIDMetadataKey)
    }

    /// Resolves the thread id for a run from its metadata under an
    /// explicit key. Shared by the session and the read-path assembler so
    /// the two can never disagree about which thread a run belongs to.
    public static func threadID(in metadata: [String: String], key: String) -> String {
        metadata[key] ?? defaultThreadID
    }
}
