import Foundation

/// The `.info(category:)` contract for the memory layer.
///
/// ## Why one grammar, documented in one place
///
/// Exactly one memory event earns a dedicated ``TraceEvent`` case
/// (``TraceEvent/memoryConsolidated(runID:extracted:added:updated:deleted:archived:modelCalls:elapsed:)``),
/// because write-path cost is a structured integer measurement that has to
/// be summed and compared across builds. Everything else the layer reports
/// — candidate rejections, sweep outcomes, pending-removal retries, archive
/// failures — is diagnostic, low-volume, and read by a human or a log
/// scraper rather than aggregated. Those ride the ``TraceEvent/info(runID:category:message:)``
/// case that already exists, which is what keeps the enum from growing a
/// case per memory operation (each of which would cost a case, two switch
/// arms, a visitor method, a default, an accept arm, three OSLog privacy
/// switches, and a pair of coding keys).
///
/// The price of using `.info` is that the message is free-form, so a
/// scraper has no contract. This type is that contract:
///
/// - Category is always ``category`` (`"memory"`).
/// - The message is a space-joined list of `key=value` pairs.
/// - The first pair is always `event=<name>`, naming what happened.
/// - Keys are lowercase snake_case; values never contain a space.
///   ``message(event:_:)`` enforces that with ``value(_:)`` rather than
///   leaving it to each call site, because some values (a thread id) are
///   supplied by the host application. Prose is omitted rather than
///   quoted — a trace line is not a place to smuggle it.
///
/// Values are still user-influenced in principle (a thread id is chosen by
/// the host application), so a ``RedactingTracer`` scrubs them like any
/// other free-form string. That is deliberate: the structured counts live
/// on `memory.consolidated`, where redaction has nothing to remove.
public enum MemoryTrace {
    /// Category every memory `.info` event carries.
    public static let category = "memory"

    /// Renders `pairs` into the documented `key=value key=value` grammar.
    ///
    /// Order is the caller's, not sorted: `event=` leads, and the
    /// remaining pairs read in the order they were produced, which is
    /// what makes two runs of the same pass produce identical lines.
    ///
    /// Every value passes through ``value(_:)``, so the grammar is
    /// enforced here rather than trusted at each call site.
    public static func message(event: String, _ pairs: [(String, String)] = []) -> String {
        ([("event", event)] + pairs)
            .map { "\($0.0)=\(value($0.1))" }
            .joined(separator: " ")
    }

    /// Makes one value safe for the grammar.
    ///
    /// Whitespace runs — including newlines — collapse to a single `_`,
    /// and an empty result becomes `_`. Most values are integers or
    /// enum raw values and pass through untouched, but some are
    /// host-supplied: a thread id comes from `RunContext.metadata` and is
    /// whatever the application put there. Without this, a thread id
    /// containing a space would silently split into two bogus pairs, and
    /// one containing a newline could forge an entire log line.
    public static func value(_ raw: String) -> String {
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "_")
        return collapsed.isEmpty ? "_" : collapsed
    }
}

/// What one consolidation pass did, for one turn.
///
/// `modelCalls` is reported even when it is always zero, because "this
/// configuration issues no model calls" is a claim that should be visible
/// in the data rather than asserted in a doc comment.
public struct ConsolidationSummary: Sendable, Equatable {
    /// Candidates the extractor produced.
    public let extracted: Int
    /// Facts inserted.
    public let added: Int
    /// Facts superseded by a newer record.
    public let updated: Int
    /// Facts retired by a retraction.
    public let deleted: Int
    /// Transcript rounds moved into the archive.
    public let archived: Int
    /// Candidates dropped by the verbatim guard or write-path redaction.
    public let rejected: Int
    /// Model calls actually issued (see ``MemoryModelCallMeter``).
    public let modelCalls: Int
    /// Wall-clock duration of the pass.
    public let elapsed: Duration

    /// Creates a summary.
    public init(
        extracted: Int,
        added: Int,
        updated: Int,
        deleted: Int,
        archived: Int,
        rejected: Int,
        modelCalls: Int,
        elapsed: Duration
    ) {
        self.extracted = extracted
        self.added = added
        self.updated = updated
        self.deleted = deleted
        self.archived = archived
        self.rejected = rejected
        self.modelCalls = modelCalls
        self.elapsed = elapsed
    }

    /// A pass that changed nothing.
    public static let empty = ConsolidationSummary(
        extracted: 0, added: 0, updated: 0, deleted: 0,
        archived: 0, rejected: 0, modelCalls: 0, elapsed: .zero
    )

    /// Whether the store and the archive were left untouched.
    public var isNoOp: Bool { added == 0 && updated == 0 && deleted == 0 && archived == 0 }
}

/// When a transcript round becomes archival.
///
/// Two windows, not one. ``keepRecent`` is what the read-path assembler
/// keeps verbatim in the prompt; ``archiveLag`` is extra slack behind it so
/// the boundary does not oscillate as a conversation grows — a message that
/// just fell out of the working window is not archived on the very next
/// turn, which keeps a round from being rebuilt while a user is still
/// mid-thought about it.
public struct ArchivePolicy: Sendable, Equatable, Codable {
    /// Messages the read path keeps in the prompt. Mirrors
    /// ``MemoryContextAssembler``'s `keepRecent`.
    public var keepRecent: Int
    /// Extra messages held back beyond ``keepRecent`` before archiving.
    public var archiveLag: Int
    /// Upper bound on rounds archived by a single pass, so a first run
    /// over a long backlog cannot blow a background time slice.
    public var maxRoundsPerPass: Int

    /// Creates a policy.
    ///
    /// - Precondition: every field is non-negative and
    ///   ``maxRoundsPerPass`` is positive.
    public init(keepRecent: Int = 8, archiveLag: Int = 4, maxRoundsPerPass: Int = 16) {
        precondition(keepRecent >= 0, "keepRecent must be non-negative")
        precondition(archiveLag >= 0, "archiveLag must be non-negative")
        precondition(maxRoundsPerPass > 0, "maxRoundsPerPass must be positive")
        self.keepRecent = keepRecent
        self.archiveLag = archiveLag
        self.maxRoundsPerPass = maxRoundsPerPass
    }

    /// The shipped defaults.
    public static let `default` = ArchivePolicy()
}

/// Counts model calls the write path issued, so a consolidation pass can
/// report its real cost.
///
/// Neither ``ModelFactExtractor`` nor ``ModelMutationHook`` reports its
/// call count — both are closure seams with no trace surface of their own,
/// which is the right shape for them and the wrong shape for measurement.
/// A meter closes the gap without either component learning about tracing:
/// wire ``recordCall()`` into the selector or router closure, hand the same
/// meter to ``MemoryConsolidator``, and
/// ``TraceEvent/memoryConsolidated(runID:extracted:added:updated:deleted:archived:modelCalls:elapsed:)``
/// carries the truth instead of an assumption.
///
/// A deterministic configuration passes no meter at all and reports `0`,
/// which is the same number a meter would report — so the absence of a
/// meter is never mistaken for the absence of calls in a configuration
/// that has one.
///
/// `@unchecked Sendable`: the counter is guarded by `lock` (NSLock), the
/// same idiom ``WorkBox`` uses for state crossing a task boundary.
public final class MemoryModelCallMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    /// Creates a zeroed meter.
    public init() {}

    /// Records one issued model call. Safe to call from any context.
    public func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    /// Calls recorded since the last ``reset()``.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    /// Zeroes the counter.
    public func reset() {
        lock.lock()
        calls = 0
        lock.unlock()
    }
}

/// Mutable tallies shared between a deadline-bounded analysis phase and
/// the caller that outlives it. `@unchecked Sendable`: guarded by NSLock.
private final class ConsolidationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var extracted = 0
    private var nonVerbatim = 0
    private var redactionFired = 0
    private var timedOut = false

    func setExtracted(_ value: Int) {
        lock.lock(); extracted = value; lock.unlock()
    }
    func rejectNonVerbatim() {
        lock.lock(); nonVerbatim += 1; lock.unlock()
    }
    func rejectRedaction() {
        lock.lock(); redactionFired += 1; lock.unlock()
    }
    func markTimedOut() {
        lock.lock(); timedOut = true; lock.unlock()
    }
    var snapshot: (extracted: Int, nonVerbatim: Int, redactionFired: Int, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (extracted, nonVerbatim, redactionFired, timedOut)
    }
}

/// Drains completed turns into the memory layer, off the critical path.
///
/// ## The shape of the write path
///
/// ``turnCompleted(_:runContext:)`` is the only method a
/// ``CompoundSession`` calls, and it does exactly one thing: append to a
/// bounded FIFO and return. Nothing is extracted, nothing is reconciled,
/// nothing is written. The pipeline runs from ``drain(runID:)``, which
/// ``MemoryMaintenance`` invokes from a ``BackgroundCompoundActivity``.
///
/// There is deliberately **no internal pump task**. Nothing else in
/// Compound spawns an unstructured `Task` that outlives its caller, and one
/// here would sit outside the cancellation discipline every other component
/// honors — a background write that keeps running after its activity's slot
/// was reclaimed is exactly the failure the background layer exists to
/// prevent. The cost of that choice is a freshness gap: a fact stated this
/// turn is not recallable until the next drain. That gap is an accepted,
/// documented property, and it is the same trade Mem0 makes with its
/// asynchronous rolling summary.
///
/// ## Failure degrades to "unchanged", never to "corrupted"
///
/// Every stage is written so that giving up leaves the store exactly as it
/// was. Extraction, the guards, and reconciliation are pure with respect to
/// the store — they read it and produce decisions, they never write — so
/// the whole analysis phase runs under ``withDeadline(_:clock:onTimeout:operation:)``
/// with a non-throwing `onTimeout` that yields *no decisions*. A pass that
/// blows its deadline, throws, or is cancelled therefore writes nothing and
/// returns a partial summary rather than a half-applied batch.
///
/// Application is the opposite: once the batch is admitted it runs to
/// completion, outside the deadline. It is a handful of local store writes
/// with no model call in it, and cutting it in half is the one outcome that
/// *would* corrupt memory — a supersession applied without its insert
/// leaves a slot empty that used to hold a fact.
///
/// ## What never happens here
///
/// The consolidator does not run the forgetting sweep. Per-turn cost has to
/// stay bounded and proportional to the turn; sweeping is proportional to
/// the store, so it belongs to ``MemoryMaintenance``. It also never purges:
/// compliance deletion is a separate, destructive, user-initiated code path
/// and shares nothing with contradiction handling.
public actor MemoryConsolidator: MemoryTurnObserving {
    /// Fact store decisions are applied to.
    private let memory: any MemoryStore
    /// Optional tier-2 archive.
    private let archive: (any ArchivalStore)?
    /// Transcript the archive ages out of.
    private let conversation: any ConversationStore
    /// Candidate producer.
    private let extractor: any FactExtracting
    /// Decision maker.
    private let reconciler: any FactReconciling
    /// When a round becomes archival.
    public let archivePolicy: ArchivePolicy
    /// Write-path redactors, applied as a rejection filter.
    private let redactors: [any Redactor]
    /// Trace sink.
    private let tracer: any Tracer
    /// Upper bound on the analysis phase for a single turn.
    public let perTurnDeadline: Duration
    /// Upper bound on candidates considered from one turn.
    public let maxCandidatesPerTurn: Int
    /// Bounded queue depth.
    public let queueCapacity: Int
    /// Optional model-call meter.
    private let modelCallMeter: MemoryModelCallMeter?
    /// Injected clock. Every timestamp a pass writes comes from here.
    private let clock: @Sendable () -> Date

    private var queue: [(turn: MemoryTurn, runID: UUID)] = []
    private var dropped = 0

    /// Creates a consolidator.
    ///
    /// - Parameters:
    ///   - memory: Fact store.
    ///   - archive: Tier-2 archive, or `nil` to keep facts only.
    ///   - conversation: Transcript the archive ages out of.
    ///   - extractor: Candidate producer. The default is fully
    ///     deterministic and issues no model calls.
    ///   - reconciler: Decision maker. Also deterministic by default.
    ///   - archivePolicy: When a round becomes archival.
    ///   - redactors: Applied to candidate text as a **rejection filter**.
    ///   - tracer: Trace sink.
    ///   - perTurnDeadline: Bounds the analysis phase, not application.
    ///   - maxCandidatesPerTurn: Passed to ``ExtractionContext``.
    ///   - queueCapacity: Bounded FIFO depth.
    ///   - modelCallMeter: Counts model calls for the trace event.
    ///   - clock: Injected clock.
    public init(
        memory: any MemoryStore,
        archive: (any ArchivalStore)? = nil,
        conversation: any ConversationStore,
        extractor: any FactExtracting = DeterministicFactExtractor(),
        reconciler: any FactReconciling = DeterministicReconciler(),
        archivePolicy: ArchivePolicy = .default,
        redactors: [any Redactor] = [],
        tracer: any Tracer = NullTracer(),
        perTurnDeadline: Duration = .seconds(20),
        maxCandidatesPerTurn: Int = 8,
        queueCapacity: Int = 32,
        modelCallMeter: MemoryModelCallMeter? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(queueCapacity > 0, "queueCapacity must be positive")
        self.memory = memory
        self.archive = archive
        self.conversation = conversation
        self.extractor = extractor
        self.reconciler = reconciler
        self.archivePolicy = archivePolicy
        self.redactors = redactors
        self.tracer = tracer
        self.perTurnDeadline = perTurnDeadline
        self.maxCandidatesPerTurn = maxCandidatesPerTurn
        self.queueCapacity = queueCapacity
        self.modelCallMeter = modelCallMeter
        self.clock = clock
    }

    // MARK: - Enqueue

    /// Enqueues `turn` and returns. O(1) amortized; no store is touched.
    ///
    /// At capacity the **oldest** entry is dropped, not the newest. A
    /// memory layer exists to know the current state of the world, so when
    /// the queue overflows the right thing to lose is the stalest turn.
    /// The drop is counted (``droppedCount``) and traced, because a queue
    /// that is silently shedding user statements is a bug the operator
    /// needs to see.
    public func turnCompleted(_ turn: MemoryTurn, runContext: RunContext) async {
        queue.append((turn, runContext.runID))
        guard queue.count > queueCapacity else { return }
        let overflow = queue.count - queueCapacity
        queue.removeFirst(overflow)
        dropped += overflow
        await tracer.record(.info(
            runID: runContext.runID,
            category: MemoryTrace.category,
            message: MemoryTrace.message(event: "queue_overflow", [
                ("dropped", String(overflow)),
                ("depth", String(queue.count)),
                ("total_dropped", String(dropped))
            ])
        ))
    }

    /// Turns waiting to be consolidated.
    public var queuedCount: Int { queue.count }
    /// Turns dropped by queue overflow since construction.
    public var droppedCount: Int { dropped }

    // MARK: - Drain

    /// Consolidates every queued turn, oldest first, and empties the queue.
    ///
    /// Each turn is traced under the run that produced it, so
    /// `memory.consolidated` correlates with the conversation turn rather
    /// than with the background pass; `runID` identifies the pass itself
    /// and is used for the drain's own summary line.
    ///
    /// Cancellation stops the drain between turns and returns the summaries
    /// completed so far — it does not throw, and it never abandons a turn
    /// mid-application. Turns still queued stay queued, so the next pass
    /// picks up exactly where this one stopped.
    @discardableResult
    public func drain(runID: UUID) async -> [ConsolidationSummary] {
        var summaries: [ConsolidationSummary] = []
        while let item = queue.first {
            if Task.isCancelled { break }
            let summary = await consolidate(item.turn, runID: item.runID)
            summaries.append(summary)
            if Task.isCancelled {
                // Cancelled mid-pass. The turn stays queued so the next
                // activity run redoes it from the top, which is the only
                // resumption model ``BackgroundCompoundActivity`` offers.
                // Redoing it is safe: the reconciler's duplicate gate
                // rejects a fact that is already stored, and archival
                // rounds are upserted under content-derived ids.
                break
            }
            queue.removeFirst()
        }
        await tracer.record(.info(
            runID: runID,
            category: MemoryTrace.category,
            message: MemoryTrace.message(event: "drain", [
                ("turns", String(summaries.count)),
                ("added", String(summaries.reduce(0) { $0 + $1.added })),
                ("updated", String(summaries.reduce(0) { $0 + $1.updated })),
                ("deleted", String(summaries.reduce(0) { $0 + $1.deleted })),
                ("archived", String(summaries.reduce(0) { $0 + $1.archived })),
                ("remaining", String(queue.count)),
                ("cancelled", String(Task.isCancelled))
            ])
        ))
        return summaries
    }

    // MARK: - One turn

    /// Runs the full pipeline for one turn.
    ///
    /// Never throws. Every failure mode — a throwing extractor, a blown
    /// deadline, a cancelled task, an archive that cannot write — degrades
    /// to a smaller summary with the store left exactly as it was found.
    @discardableResult
    public func consolidate(_ turn: MemoryTurn, runID: UUID) async -> ConsolidationSummary {
        let startedAt = ContinuousClock.now
        let now = clock()
        modelCallMeter?.reset()
        let progress = ConsolidationProgress()

        // Phase 1 — analysis. Reads the store, writes nothing. Bounded by
        // the deadline so a model-backed extractor cannot hold a
        // background slice open; a timeout yields an empty decision list,
        // which is the "leave memory unchanged" outcome.
        var decisions: [MemoryDecision] = []
        do {
            decisions = try await withDeadline(
                perTurnDeadline,
                onTimeout: {
                    progress.markTimedOut()
                    return []
                },
                operation: { [self] in
                    try await analyze(turn, now: now, progress: progress)
                }
            )
        } catch is CancellationError {
            return await finish(progress, applied: .empty, archived: 0, runID: runID, startedAt: startedAt, note: "cancelled")
        } catch {
            await traceInfo(runID: runID, event: "analysis_failed", [
                ("thread", turn.threadID),
                ("error", Self.errorTag(error))
            ])
            return await finish(progress, applied: .empty, archived: 0, runID: runID, startedAt: startedAt, note: "failed")
        }

        let tallies = progress.snapshot
        if tallies.timedOut {
            await traceInfo(runID: runID, event: "analysis_timeout", [
                ("thread", turn.threadID),
                ("deadline_ms", String(Self.milliseconds(perTurnDeadline)))
            ])
        }
        if tallies.nonVerbatim > 0 {
            await traceInfo(runID: runID, event: "rejected", [
                ("reason", MemoryRationale.nonVerbatimSpan.rawValue),
                ("count", String(tallies.nonVerbatim)),
                ("thread", turn.threadID)
            ])
        }
        if tallies.redactionFired > 0 {
            await traceInfo(runID: runID, event: "rejected", [
                ("reason", MemoryRationale.redactionFired.rawValue),
                ("count", String(tallies.redactionFired)),
                ("thread", turn.threadID)
            ])
        }

        // Phase 2 — application. Deliberately outside the deadline: this is
        // the only stage that mutates, and a half-applied batch is the one
        // failure worse than no write at all. A cancellation observed here
        // skips application entirely rather than starting it.
        var applied = ReconciliationOutcome.empty
        if !decisions.isEmpty, !Task.isCancelled {
            do {
                applied = try await Reconciliation.apply(decisions, to: memory, now: now)
            } catch {
                await traceInfo(runID: runID, event: "apply_failed", [
                    ("thread", turn.threadID),
                    ("decisions", String(decisions.count)),
                    ("error", Self.errorTag(error))
                ])
            }
        }

        // Phase 3 — archive. Idempotent by construction: rounds are named
        // by content-derived chunk ids and upserted, so a deferred activity
        // that re-runs this pass from the top changes nothing.
        let archived = Task.isCancelled ? 0 : await archiveBacklog(threadID: turn.threadID, runID: runID)

        return await finish(progress, applied: applied, archived: archived, runID: runID, startedAt: startedAt, note: nil)
    }

    // MARK: - Pipeline stages

    /// Extract → verbatim guard → write-path redaction → reconcile.
    ///
    /// Store-read-only by construction, which is what makes it safe to
    /// abandon at any suspension point.
    private func analyze(
        _ turn: MemoryTurn,
        now: Date,
        progress: ConsolidationProgress
    ) async throws -> [MemoryDecision] {
        let context = ExtractionContext(
            threadID: turn.threadID,
            now: now,
            maxCandidates: maxCandidatesPerTurn,
            redactors: redactors
        )
        let candidates = try await extractor.extract(from: turn, context: context)
        progress.setExtracted(candidates.count)
        guard !candidates.isEmpty else { return [] }

        let evidence = turn.sourceMessages
        var admitted: [FactCandidate] = []
        admitted.reserveCapacity(candidates.count)
        for candidate in candidates {
            // Guard 1: the span must still be a literal substring of a
            // message this candidate *names*. A model may select a span;
            // it may never author one, and a syntactically clean decode is
            // not evidence that the claim was ever said.
            guard candidate.isVerbatim(in: evidence) else {
                progress.rejectNonVerbatim()
                continue
            }
            // Guard 2: if any redactor would change the text, drop the
            // candidate outright rather than store the redacted form. Two
            // independent reasons: a redacted span is no longer a verbatim
            // span, so guard 1's invariant would be void for every later
            // re-check; and a claim that contains a secret should not be
            // persisted in any form, redacted or not.
            guard !redactionWouldFire(on: candidate.text) else {
                progress.rejectRedaction()
                continue
            }
            admitted.append(candidate)
        }
        guard !admitted.isEmpty else { return [] }
        return try await reconciler.reconcile(candidates: admitted, against: memory, now: now)
    }

    /// Whether any configured redactor rewrites `text`.
    private func redactionWouldFire(on text: String) -> Bool {
        for redactor in redactors where redactor.redact(text) != text { return true }
        return false
    }

    /// Moves aged-out transcript rounds into the archive.
    ///
    /// Rounds are rebuilt over the whole aged-out prefix rather than over
    /// a moving slice, and their ordinals come from the archive's own
    /// persisted ledger when it has one. Both choices exist for the same
    /// reason: a round's chunk id must be a function of the transcript
    /// alone, so re-running this pass — which a deferred background
    /// activity does routinely — produces byte-identical rounds instead of
    /// a second copy of the corpus under fresh ids.
    ///
    /// - Returns: How many rounds were newly archived.
    private func archiveBacklog(threadID: String, runID: UUID) async -> Int {
        guard let archive else { return 0 }
        let messages: [ConversationMessage]
        do {
            messages = try await conversation.messages()
        } catch {
            await traceInfo(runID: runID, event: "archive_failed", [
                ("stage", "read_transcript"),
                ("error", Self.errorTag(error))
            ])
            return 0
        }
        let held = archivePolicy.keepRecent + archivePolicy.archiveLag
        guard messages.count > held else { return 0 }
        let aged = Array(messages.prefix(messages.count - held))

        var ordinals: [UUID: Int] = [:]
        var nextOrdinal = 0
        // The ordinal ledger is on the concrete store, not on the
        // `ArchivalStore` protocol — adding it there would force every
        // conformer to implement ordinal bookkeeping it may not have. A
        // conformer without one still gets stable ids, because rebuilding
        // over the whole prefix assigns ordinals by position.
        if let indexed = archive as? IndexedArchivalStore,
           let ledger = try? await indexed.ledger(threadID: threadID) {
            ordinals = ledger.ordinals
            nextOrdinal = ledger.nextOrdinal
        }
        let built = RoundBuilder.rounds(
            from: aged,
            threadID: threadID,
            ordinals: ordinals,
            nextOrdinal: nextOrdinal
        )

        var fresh: [ArchivedRound] = []
        for round in built.rounds {
            // `try?` flattens both "not archived" and "the lookup failed"
            // to nil, which is the safe direction: a failed lookup falls
            // through to an upsert, and an upsert of a round already in the
            // archive changes nothing.
            if (try? await archive.round(chunkID: round.id)) != nil { continue }
            fresh.append(round)
            if fresh.count >= archivePolicy.maxRoundsPerPass { break }
        }
        guard !fresh.isEmpty else { return 0 }
        do {
            try await archive.archive(fresh)
        } catch {
            await traceInfo(runID: runID, event: "archive_failed", [
                ("stage", "index"),
                ("rounds", String(fresh.count)),
                ("error", Self.errorTag(error))
            ])
            return 0
        }
        return fresh.count
    }

    // MARK: - Reporting

    /// Emits the structured event and returns the summary.
    private func finish(
        _ progress: ConsolidationProgress,
        applied: ReconciliationOutcome,
        archived: Int,
        runID: UUID,
        startedAt: ContinuousClock.Instant,
        note: String?
    ) async -> ConsolidationSummary {
        let tallies = progress.snapshot
        let elapsed = ContinuousClock.now - startedAt
        let summary = ConsolidationSummary(
            extracted: tallies.extracted,
            added: applied.added.count,
            updated: applied.superseded.count,
            deleted: applied.deleted.count,
            archived: archived,
            rejected: tallies.nonVerbatim + tallies.redactionFired,
            modelCalls: modelCallMeter?.count ?? 0,
            elapsed: elapsed
        )
        if let note {
            await traceInfo(runID: runID, event: "consolidation_incomplete", [("reason", note)])
        }
        await tracer.record(.memoryConsolidated(
            runID: runID,
            extracted: summary.extracted,
            added: summary.added,
            updated: summary.updated,
            deleted: summary.deleted,
            archived: summary.archived,
            modelCalls: summary.modelCalls,
            elapsed: summary.elapsed
        ))
        return summary
    }

    private func traceInfo(runID: UUID, event: String, _ pairs: [(String, String)]) async {
        await tracer.record(.info(
            runID: runID,
            category: MemoryTrace.category,
            message: MemoryTrace.message(event: event, pairs)
        ))
    }

    /// A short, space-free tag for an error, suitable for the `key=value`
    /// grammar. The full description is deliberately not logged: it can
    /// carry the very content the write path just refused to store.
    static func errorTag(_ error: any Error) -> String {
        String(describing: type(of: error))
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
