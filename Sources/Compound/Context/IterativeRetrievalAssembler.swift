import Foundation

// Single-shot RAG asks once and hopes the top-k covers the question. That
// works for lookup questions and fails for compound ones: "what is the
// battery life and what does the warranty cover?" retrieves five chunks
// about batteries, because the battery vocabulary dominates the query.
//
// Agentic retrieval closes that gap by making retrieval a *loop* the
// controller owns — retrieve, assess, reformulate, re-retrieve — instead of
// a single call. The loop is bounded on every axis that can run away: a
// round count, a per-round k, an overall wall-clock deadline, and a
// no-progress check that stops as soon as reformulation stops producing new
// queries.

/// ``ContextAssembler`` that retrieves iteratively, then delegates the
/// actual assembly to an inner assembler built over the evidence it
/// gathered.
///
/// ## The loop
///
/// 1. Round 1 retrieves ``perRoundTopK`` sources for the user's query.
/// 2. A ``SufficiencyAssessing`` conformer judges *everything accumulated
///    so far* against the **original** query — never against the
///    reformulated one, since the information need does not change between
///    rounds.
/// 3. If the verdict is insufficient, a ``QueryReformulating`` conformer
///    turns the missing aspects into the next query and the loop repeats.
///
/// The loop stops on the first of: a sufficient verdict, ``maxRounds``, the
/// ``deadline``, a reformulator that declines (or repeats a query already
/// issued), or a failure after round 1. ``StopReason`` records which, and
/// ``gatherEvidence(for:runContext:)`` exposes the whole trajectory so
/// callers can test and observe the loop without parsing trace strings.
///
/// ## Composition, not reimplementation
///
/// This type does no redaction, no policy gating beyond a pre-flight check,
/// no framing, and no token budgeting. It gathers evidence and hands it to
/// ``makeInner`` — a factory that receives a ``StaticRetriever`` over the
/// accumulated sources and returns the assembler that does the real work:
///
/// ```swift
/// let assembler = IterativeRetrievalAssembler(retriever: hybrid) { evidence in
///     TokenBudgetedAssembler(
///         wrapping: DefaultContextAssembler(
///             baseInstructions: "Answer only from the sources.",
///             retriever: evidence,
///             retrievalLimit: 20,
///             redactors: [try! CommonRedactors.email()]
///         ),
///         maxPromptTokens: 2_000
///     )
/// }
/// ```
///
/// Everything the inner assembler does still happens, to the accumulated
/// evidence: redaction of source bodies, the policy gate, the prompt frame's
/// fencing, budget eviction. A factory rather than a plain
/// `any ContextAssembler` because the sources have to reach the inner
/// assembler *through* its retriever — appending them to the context it
/// returns would route them around exactly the redaction pass they need.
///
/// The inner assembler's own retrieval limit still applies. Set it at least
/// as large as the evidence you want admitted (``maxAccumulatedSources``,
/// or `maxRounds × perRoundTopK` when uncapped); a smaller limit silently
/// truncates the accumulated list.
///
/// ## Ordering
///
/// Accumulated sources are ordered by **interleaved rank**: every round's
/// top hit first, then every round's second hit, and so on, with ties broken
/// by round order. Scores from different queries are not comparable — BM25
/// scores in particular are query-relative — so ordering the union by raw
/// score would let round 1's numerically larger scores bury exactly the
/// evidence the later rounds were run to find. Rank is comparable across
/// rounds; score is not.
///
/// A source found in several rounds keeps its best (lowest) rank and its
/// highest score. That retained score is metadata for downstream consumers,
/// not the ordering key here — note that ``TokenBudgetedAssembler`` *does*
/// evict by score, so wrapping one re-imposes cross-query score comparison
/// on the tail of the list.
public struct IterativeRetrievalAssembler: ContextAssembler {
    /// Why the retrieval loop stopped.
    public enum StopReason: String, Sendable, Equatable, Codable {
        /// The assessor judged the accumulated evidence sufficient.
        case sufficient
        /// ``maxRounds`` rounds ran without a sufficient verdict.
        case maxRounds
        /// The overall ``deadline`` elapsed. Evidence gathered by completed
        /// rounds is kept.
        case deadline
        /// The reformulator returned no new query — nothing was missing it
        /// could ask about, or it reproduced a query already issued.
        case noReformulation
        /// A retrieval after round 1 threw. Earlier rounds' evidence is
        /// kept; a round-1 failure throws instead.
        case retrievalFailed
        /// The assessor threw. The round's sources are kept, unjudged.
        case assessmentFailed
        /// The reformulator threw.
        case reformulationFailed
    }

    /// One completed round of the loop.
    public struct Round: Sendable, Equatable {
        /// 1-based round number.
        public let index: Int
        /// Query this round issued (redacted, if ``queryRedactors`` fired).
        public let query: String
        /// Sources the round retrieved, in retriever order.
        public let retrieved: [RetrievedSource]
        /// Identifiers this round contributed that earlier rounds had not.
        /// Empty means the round found nothing new — the usual signal that
        /// reformulation is going in circles.
        public let newSourceIDs: [String]
        /// The round's verdict, or `nil` when assessment failed.
        public let verdict: SufficiencyVerdict?

        /// Creates a round record.
        public init(
            index: Int,
            query: String,
            retrieved: [RetrievedSource],
            newSourceIDs: [String],
            verdict: SufficiencyVerdict?
        ) {
            self.index = index
            self.query = query
            self.retrieved = retrieved
            self.newSourceIDs = newSourceIDs
            self.verdict = verdict
        }
    }

    /// The loop's output: the evidence and how it was reached.
    public struct Evidence: Sendable {
        /// Deduped, rank-interleaved sources.
        public let sources: [RetrievedSource]
        /// Completed rounds, in order.
        public let rounds: [Round]
        /// Why the loop stopped.
        public let stopReason: StopReason

        /// Creates an evidence record.
        public init(sources: [RetrievedSource], rounds: [Round], stopReason: StopReason) {
            self.sources = sources
            self.rounds = rounds
            self.stopReason = stopReason
        }

        /// Queries issued, in round order.
        public var queries: [String] { rounds.map(\.query) }
    }

    /// Retriever driven each round. Any conformer works, including a
    /// ``HybridRetriever`` with a ``Reranker`` attached.
    public let retriever: any Retriever
    /// Judges whether the accumulated evidence answers the query.
    public let assessor: any SufficiencyAssessing
    /// Produces the next query from the missing aspects.
    public let reformulator: any QueryReformulating
    /// Builds the assembler that performs final assembly over the gathered
    /// evidence. Receives a ``StaticRetriever`` holding it.
    public let makeInner: @Sendable (any Retriever) -> any ContextAssembler
    /// Hard cap on retrieval rounds.
    public let maxRounds: Int
    /// Sources requested per round.
    public let perRoundTopK: Int
    /// Wall-clock cap on the whole loop, or `nil` for no cap. On expiry the
    /// loop stops and assembly proceeds with whatever completed rounds
    /// produced — a slow retriever degrades the evidence, it does not fail
    /// the run.
    public let deadline: Duration?
    /// Optional cap on accumulated sources, applied after interleaving.
    /// `nil` (the default) keeps everything the rounds found.
    public let maxAccumulatedSources: Int?
    /// Redactors applied to every query *before it reaches the retriever*.
    ///
    /// The inner assembler still redacts the user prompt and the sources it
    /// admits; this governs only what the retriever itself sees. Mirror the
    /// inner assembler's user-prompt redactors here whenever the retrieval
    /// backend must not observe raw PII — a remote index logs its queries.
    /// Names that fire are merged into
    /// ``AssembledContext/redactionsApplied``.
    public let queryRedactors: [any Redactor]
    /// Pre-flight gate evaluated on the query before the first retrieval.
    ///
    /// The inner assembler runs the real gate, but it runs *after* the loop
    /// — by which point a denied prompt has already hit the retriever
    /// ``maxRounds`` times. Pass the same policy the inner assembler holds
    /// to close that window. Defaults to ``AllowAll``.
    public let policy: any Policy

    /// Creates an iterative assembler.
    ///
    /// - Parameters:
    ///   - retriever: Retriever driven each round.
    ///   - assessor: Sufficiency judge. Defaults to the deterministic
    ///     ``TermCoverageAssessor``.
    ///   - reformulator: Query rewriter. Defaults to the deterministic
    ///     ``MissingAspectReformulator``.
    ///   - maxRounds: Hard round cap. Must be positive. Defaults to 3 —
    ///     enough for a two-aspect question plus one recovery round, and
    ///     small enough that the worst case stays interactive.
    ///   - perRoundTopK: Sources requested per round. Must be positive.
    ///   - deadline: Wall-clock cap on the loop, or `nil`.
    ///   - maxAccumulatedSources: Optional cap on gathered evidence.
    ///   - queryRedactors: Redactors applied to queries before retrieval.
    ///   - policy: Pre-flight gate on the query.
    ///   - makeInner: Factory for the assembler that does final assembly.
    public init(
        retriever: any Retriever,
        assessor: any SufficiencyAssessing = TermCoverageAssessor(),
        reformulator: any QueryReformulating = MissingAspectReformulator(),
        maxRounds: Int = 3,
        perRoundTopK: Int = 5,
        deadline: Duration? = .seconds(30),
        maxAccumulatedSources: Int? = nil,
        queryRedactors: [any Redactor] = [],
        policy: any Policy = AllowAll(),
        makeInner: @escaping @Sendable (any Retriever) -> any ContextAssembler
    ) {
        precondition(maxRounds > 0, "maxRounds must be positive")
        precondition(perRoundTopK > 0, "perRoundTopK must be positive")
        precondition(
            maxAccumulatedSources.map { $0 > 0 } ?? true,
            "maxAccumulatedSources must be positive when set"
        )
        self.retriever = retriever
        self.assessor = assessor
        self.reformulator = reformulator
        self.maxRounds = maxRounds
        self.perRoundTopK = perRoundTopK
        self.deadline = deadline
        self.maxAccumulatedSources = maxAccumulatedSources
        self.queryRedactors = queryRedactors
        self.policy = policy
        self.makeInner = makeInner
    }

    /// Runs the retrieval loop, then delegates assembly to the inner
    /// assembler over the gathered evidence.
    ///
    /// The **original** `userPrompt` reaches the inner assembler, not the
    /// query-redacted form: the inner assembler owns prompt redaction and
    /// double-redacting would attribute the same scrub twice. Any
    /// ``queryRedactors`` that fired are merged into the returned context's
    /// ``AssembledContext/redactionsApplied``.
    ///
    /// - Throws: ``CompoundError/policyDenied(reason:)`` if the pre-flight
    ///   gate denies the query, anything the round-1 retrieval throws, and
    ///   anything the inner assembler throws.
    public func assemble(userPrompt: String, runContext: RunContext) async throws -> AssembledContext {
        var applied: [String] = []
        let query = queryRedactors.isEmpty
            ? userPrompt
            : runRedactors(queryRedactors, on: userPrompt, applied: &applied)

        let evidence = try await gatherEvidence(for: query, runContext: runContext)

        var context = try await makeInner(StaticRetriever(evidence.sources))
            .assemble(userPrompt: userPrompt, runContext: runContext)
        for name in applied where !context.redactionsApplied.contains(name) {
            context.redactionsApplied.append(name)
        }
        return context
    }

    /// Runs the retrieve → assess → reformulate loop and returns the
    /// evidence with the trajectory that produced it.
    ///
    /// Exposed so the loop can be driven and asserted on directly — the
    /// stop reason and per-round queries are behavior worth testing without
    /// going through assembly, and worth showing in a debugging UI.
    ///
    /// - Throws: ``CompoundError/policyDenied(reason:)``, `CancellationError`,
    ///   or whatever round 1's retrieval threw. Failures in later rounds
    ///   stop the loop and are reported through ``StopReason`` and a trace
    ///   event instead: evidence already in hand is worth more than a
    ///   propagated error from a round that was optional to begin with.
    public func gatherEvidence(for query: String, runContext: RunContext) async throws -> Evidence {
        let decision = await policy.evaluate(
            .promptContent(redactedSize: query.utf8.count, classification: nil),
            auth: runContext.auth
        )
        if case .deny(let reason) = decision {
            throw CompoundError.policyDenied(reason: reason)
        }

        let accumulator = Accumulator()
        if let deadline {
            // The timeout handler returns rather than throws: an elapsed
            // deadline degrades the evidence, it does not fail the run. The
            // accumulator survives the cancelled loop task, so the rounds
            // that did complete are still assembled.
            try await withDeadline(
                deadline,
                onTimeout: {
                    await accumulator.stop(.deadline)
                    await trace(
                        runContext,
                        "iterative retrieval deadline of \(deadline) elapsed; assembling with evidence gathered so far"
                    )
                },
                operation: {
                    try await runLoop(query: query, into: accumulator, runContext: runContext)
                }
            )
        } else {
            try await runLoop(query: query, into: accumulator, runContext: runContext)
        }

        let evidence = await accumulator.evidence(limit: maxAccumulatedSources)
        await runContext.tracer.record(
            .retrievalLoopEnded(
                runID: runContext.runID,
                rounds: evidence.rounds.count,
                sources: evidence.sources.count,
                reason: evidence.stopReason.rawValue
            )
        )
        return evidence
    }

    /// The loop proper. Writes into `accumulator` as it goes so a deadline
    /// that cancels this task does not take the completed rounds with it.
    private func runLoop(query: String, into accumulator: Accumulator, runContext: RunContext) async throws {
        var current = query
        var issued: Set<String> = []

        for index in 1...maxRounds {
            try Task.checkCancellation()
            issued.insert(Self.normalize(current))

            let retrieved: [RetrievedSource]
            do {
                retrieved = try await retriever.retrieve(query: current, limit: perRoundTopK)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Round 1 is not optional: with no evidence at all there is
                // nothing to assemble, and silently returning a sourceless
                // context would hide the failure behind an ungrounded answer.
                if index == 1 { throw error }
                await trace(runContext, "iterative round \(index) retrieval failed: \(error)")
                await accumulator.stop(.retrievalFailed)
                return
            }

            let newIDs = await accumulator.add(retrieved, round: index)
            let accumulated = await accumulator.sources(limit: maxAccumulatedSources)

            var verdict: SufficiencyVerdict?
            do {
                verdict = try await assessor.assess(query: query, sources: accumulated)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                await trace(runContext, "iterative round \(index) assessment failed: \(error)")
                verdict = nil
            }

            await accumulator.record(
                Round(
                    index: index,
                    query: current,
                    retrieved: retrieved,
                    newSourceIDs: newIDs,
                    verdict: verdict
                )
            )
            await runContext.tracer.record(
                .retrievalRound(
                    runID: runContext.runID,
                    round: index,
                    // Flattened and capped: a retrieved- or user-authored
                    // query must not be able to inject newlines into a log
                    // line, whatever sink the trace lands in.
                    query: Self.summarize(current),
                    retrieved: retrieved.count,
                    newSources: newIDs.count,
                    verdict: Self.label(verdict)
                )
            )

            guard let verdict else {
                await accumulator.stop(.assessmentFailed)
                return
            }
            if verdict.isSufficient {
                await accumulator.stop(.sufficient)
                return
            }
            guard index < maxRounds else {
                await accumulator.stop(.maxRounds)
                return
            }

            let next: String?
            do {
                next = try await reformulator.reformulate(
                    originalQuery: query,
                    previousQuery: current,
                    missingAspects: verdict.missingAspects,
                    sources: accumulated
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                await trace(runContext, "iterative round \(index) reformulation failed: \(error)")
                await accumulator.stop(.reformulationFailed)
                return
            }

            let candidate = next?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A query already issued cannot find anything the accumulator
            // does not already hold, so re-running it spends a round (and,
            // for a model reranker, model calls) to stand still.
            guard !candidate.isEmpty, !issued.contains(Self.normalize(candidate)) else {
                await accumulator.stop(.noReformulation)
                return
            }
            current = candidate
        }
        // Unreachable: the final iteration always stops on `index < maxRounds`.
        await accumulator.stop(.maxRounds)
    }

    private func trace(_ runContext: RunContext, _ message: String) async {
        await runContext.tracer.record(
            .info(runID: runContext.runID, category: "retrieval", message: message)
        )
    }

    /// Loop-detection key. Queries differing only in case or surrounding
    /// whitespace retrieve identically, so they count as the same query.
    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Single-line, length-capped rendering of a query for trace output.
    /// Queries are user text; they do not get to inject newlines into a
    /// log line or pad it to megabytes.
    static func summarize(_ query: String, limit: Int = 120) -> String {
        let flattened = query.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }

    private static func label(_ verdict: SufficiencyVerdict?) -> String {
        guard let verdict else { return "unavailable" }
        if verdict.isSufficient { return "sufficient" }
        let aspects = verdict.missingAspects.prefix(5).joined(separator: ",")
        return "insufficient missing=[\(summarize(aspects, limit: 80))]"
    }

    /// Cross-round evidence store.
    ///
    /// An actor, and written to incrementally, because the deadline path
    /// cancels the loop task: the completed rounds have to live somewhere
    /// the timeout handler can still read them from.
    private actor Accumulator {
        private struct Entry {
            var source: RetrievedSource
            var rank: Int
            var round: Int
            var order: Int
        }

        private var entries: [String: Entry] = [:]
        private var sequence = 0
        private var rounds: [Round] = []
        private var stopReason: StopReason = .maxRounds

        /// Folds `sources` in, returning the ids not previously seen.
        ///
        /// A repeat keeps its best (lowest) rank and its highest score; the
        /// first-seen round and sequence number are retained as tie-breaks
        /// so the merge order stays a function of the trajectory rather
        /// than of dictionary iteration.
        func add(_ sources: [RetrievedSource], round: Int) -> [String] {
            var new: [String] = []
            for (rank, source) in sources.enumerated() {
                if var existing = entries[source.id] {
                    existing.rank = min(existing.rank, rank)
                    existing.source = Self.merge(existing.source, source)
                    entries[source.id] = existing
                } else {
                    entries[source.id] = Entry(source: source, rank: rank, round: round, order: sequence)
                    sequence += 1
                    new.append(source.id)
                }
            }
            return new
        }

        func record(_ round: Round) {
            rounds.append(round)
        }

        func stop(_ reason: StopReason) {
            stopReason = reason
        }

        func sources(limit: Int?) -> [RetrievedSource] {
            let ordered = entries.values
                .sorted { a, b in
                    if a.rank != b.rank { return a.rank < b.rank }
                    if a.round != b.round { return a.round < b.round }
                    return a.order < b.order
                }
                .map(\.source)
            guard let limit else { return ordered }
            return Array(ordered.prefix(limit))
        }

        func evidence(limit: Int?) -> Evidence {
            Evidence(sources: sources(limit: limit), rounds: rounds, stopReason: stopReason)
        }

        /// Keeps the higher score of two sightings of one chunk. A `nil`
        /// score loses to any real score; two `nil`s stay `nil`. Title and
        /// content come from the first sighting — the same chunk id is the
        /// same chunk, and preferring the later copy would make the result
        /// depend on round order for no gain.
        private static func merge(_ existing: RetrievedSource, _ candidate: RetrievedSource) -> RetrievedSource {
            switch (existing.score, candidate.score) {
            case let (old?, new?) where new > old:
                return RetrievedSource(
                    id: existing.id,
                    title: existing.title,
                    content: existing.content,
                    score: new
                )
            case (nil, let new?):
                return RetrievedSource(
                    id: existing.id,
                    title: existing.title,
                    content: existing.content,
                    score: new
                )
            default:
                return existing
            }
        }
    }
}
