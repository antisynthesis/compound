import Foundation

/// Packages the memory layer's background work as a
/// ``BackgroundCompoundActivity``.
///
/// ## Why the whole write path lives here
///
/// Consolidation, forgetting, and index repair are all proportional to the
/// *store*, not to the turn that triggered them, so none of them can run on
/// a user-visible path without making every turn slower as the store grows.
/// They are also all deferrable: a fact recalled one pass late is a
/// freshness gap, while a turn that stalls waiting to remember is a
/// regression. So they run here, on the platform's own scheduler, through
/// the activity type that already owns cancellation and deferral parity on
/// iOS and macOS.
///
/// ## Every step is idempotent, because the body restarts from the top
///
/// ``BackgroundCompoundActivity`` maps a throw, a cancellation, and a
/// scheduler deferral all to ``BackgroundActivityCompletion/deferred``, and
/// the scheduler then re-runs the body from its first line — not from where
/// it stopped. That makes idempotence a correctness requirement rather than
/// a nicety, and each step is built for it:
///
/// - Pending-removal retry re-issues deletes that are already recorded as
///   intended; a delete that already landed is a no-op.
/// - ``MemoryConsolidator/drain(runID:)`` pops from a queue, so a turn is
///   consumed at most once, and the pipeline it runs writes all-or-nothing
///   per turn.
/// - ``ForgettingSweep`` only ever invalidates, is a pure function of the
///   store plus the injected `now`, and re-invalidating an already-retired
///   record returns zero.
/// - ``ArchivalStore/rehydrate()`` upserts postings by id.
///
/// Nothing here purges. Destructive deletion is compliance-shaped, exact
/// match only, and user-initiated; a scheduled job must never be able to
/// arrive at it on its own.
public enum MemoryMaintenance {
    /// Builds the maintenance activity.
    ///
    /// The body runs four steps in a fixed order, each emitting one
    /// ``MemoryTrace``-formatted `.info` line, plus one
    /// `memory.consolidated` event per drained turn:
    ///
    /// 1. Retry archival removals that did not reach every index. This runs
    ///    **first** because a failed removal means content the user asked to
    ///    forget is still retrievable through one index — the most urgent
    ///    thing outstanding, and the one thing here that is a correctness
    ///    debt rather than a maintenance chore.
    /// 2. Drain the consolidation queue.
    /// 3. Sweep the forgetting policy.
    /// 4. Re-index the archive from its journal.
    ///
    /// - Parameters:
    ///   - identifier: Reverse-DNS scheduler identifier. On iOS-family
    ///     platforms it must appear in `BGTaskSchedulerPermittedIdentifiers`.
    ///   - consolidator: Queue to drain.
    ///   - store: Fact store to sweep.
    ///   - archive: Archive to repair and re-index, when one is configured.
    ///   - threadID: Restrict the sweep to one thread; `nil` sweeps all.
    ///   - forgetting: TTL, decay, and eviction rules.
    ///   - tracer: Trace sink for the per-step summary lines.
    ///   - rehydratesArchive: Whether step 4 is considered at all. Default
    ///     `true`, which is correct after a cold launch — ``BM25Retriever``
    ///     and ``DenseRetriever`` are in-memory actors that do not survive
    ///     a process restart while the journal does. Even when `true` the
    ///     pass first asks ``ArchivalStore/indexesArePopulated()`` and
    ///     skips the re-index on warm indexes, so this flag is only needed
    ///     to suppress the probe itself.
    ///   - clock: Injected clock. The sweep's every comparison is against
    ///     one instant read here, so a pass is internally consistent.
    public static func activity(
        identifier: String,
        consolidator: MemoryConsolidator,
        store: any MemoryStore,
        archive: (any ArchivalStore)? = nil,
        threadID: String? = nil,
        forgetting: ForgettingPolicy = .default,
        tracer: any Tracer = NullTracer(),
        rehydratesArchive: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> BackgroundCompoundActivity {
        BackgroundCompoundActivity(identifier: identifier) {
            try await run(
                consolidator: consolidator,
                store: store,
                archive: archive,
                threadID: threadID,
                forgetting: forgetting,
                tracer: tracer,
                rehydratesArchive: rehydratesArchive,
                clock: clock
            )
        }
    }

    /// The activity body, exposed so an application that drives its own
    /// scheduler (or a test) can run one pass directly.
    ///
    /// - Returns: The run id the pass traced under, so a caller can pull
    ///   its events back out of a tracer.
    @discardableResult
    public static func run(
        consolidator: MemoryConsolidator,
        store: any MemoryStore,
        archive: (any ArchivalStore)? = nil,
        threadID: String? = nil,
        forgetting: ForgettingPolicy = .default,
        tracer: any Tracer = NullTracer(),
        rehydratesArchive: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> UUID {
        let runID = UUID()

        func info(_ event: String, _ pairs: [(String, String)]) async {
            await tracer.record(.info(
                runID: runID,
                category: MemoryTrace.category,
                message: MemoryTrace.message(event: event, pairs)
            ))
        }

        // 1. Retry removals that did not reach every index.
        if let archive {
            let pending = try await archive.pendingRemovalIDs()
            if !pending.isEmpty {
                // `archive(_:)` retries the pending queue as its first
                // action; an empty batch is otherwise a no-op, so this is
                // the cheapest way to ask for a retry without also asking
                // for a throw when an index is still refusing.
                try await archive.archive([])
                let remaining = try await archive.pendingRemovalIDs()
                await info("pending_removals", [
                    ("pending", String(pending.count)),
                    ("cleared", String(pending.count - remaining.count)),
                    ("remaining", String(remaining.count))
                ])
            } else {
                await info("pending_removals", [("pending", "0")])
            }
        }
        try Task.checkCancellation()

        // 2. Drain the consolidation queue.
        let summaries = await consolidator.drain(runID: runID)
        await info("maintenance_drain", [
            ("turns", String(summaries.count)),
            ("added", String(summaries.reduce(0) { $0 + $1.added })),
            ("archived", String(summaries.reduce(0) { $0 + $1.archived })),
            ("model_calls", String(summaries.reduce(0) { $0 + $1.modelCalls }))
        ])
        try Task.checkCancellation()

        // 3. Forgetting sweep. Invalidates only — never purges.
        let outcome = try await ForgettingSweep(policy: forgetting)
            .sweep(store: store, threadID: threadID, now: clock())
        await info("sweep", [
            ("expired", String(outcome.expired.count)),
            ("evicted", String(outcome.evicted.count)),
            ("decayed", String(outcome.decayed.count))
        ])
        try Task.checkCancellation()

        // 4. Re-index the archive from its journal, but only when the
        //    indexes are actually cold. `rehydrate()` is idempotent, so a
        //    redundant pass is only wasted work — but on a dense index
        //    that work is re-embedding every archived round, which is the
        //    most expensive thing this activity can do.
        if rehydratesArchive, let archive {
            let count = try await archive.count()
            if count > 0, try await !archive.indexesArePopulated() {
                try await archive.rehydrate()
                await info("rehydrate", [("rounds", String(count))])
            } else {
                await info("rehydrate", [("rounds", "0"), ("skipped", count > 0 ? "warm" : "empty")])
            }
        }
        return runID
    }
}
