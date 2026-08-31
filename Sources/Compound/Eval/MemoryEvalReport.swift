import Foundation

/// Summarizes a ``MemoryEvalRunner`` pass: the per-case verdict, the
/// confounds the run was produced under, and what the write path cost.
///
/// Shaped like ``RetrievalEvalReport`` — `suiteName`, `runID`,
/// `started`/`finished`, `environment`, ISO 8601 dates and
/// integer-nanosecond durations in the JSON encoding — so memory baselines
/// live beside retrieval and generation baselines in CI and diff the same
/// way.
///
/// Aggregates are computed, not stored, so a decoded report can never
/// disagree with its own case rows.
///
/// ## Why provenance is a first-class field
///
/// MemDelta reports a memory system's headline `+11pp` gain reversing to
/// `-1.2pp` when nothing changed but the embedder. A memory number is a
/// measurement of a *stack*, not of a component, so a baseline that does
/// not record which embedder, extractor, reconciler, and prompt version
/// produced it silently invalidates itself the first time any of them
/// moves. ``Provenance`` makes that record mandatory: it is a required
/// argument to ``MemoryEvalRunner/run(_:against:provenance:writePath:)``,
/// not an optional annotation someone remembers to fill in.
///
/// ## Why write-path cost sits next to accuracy
///
/// Both MemDelta and the small-language-model literature single out
/// write-path cost as the field's blind spot: memory systems are compared
/// on recall and never on what recall cost to maintain. On-device that is
/// the metric that decides shippability, so ``WritePathCost`` is reported
/// in the same artifact as the pass rate. A design that buys two points of
/// accuracy by doubling model calls per turn is then visibly a tradeoff
/// rather than an unqualified win.
public struct MemoryEvalReport: Sendable, Codable, Equatable {
    /// Suite name.
    public let suiteName: String
    /// Identifier for this run, for correlating with logs and traces.
    public let runID: UUID
    /// Wall-clock instant the run started.
    public let started: Date
    /// Wall-clock instant the run finished.
    public let finished: Date
    /// Per-case outcomes in declaration order.
    public let cases: [CaseOutcome]
    /// Snapshot of the machine the run executed on, if recorded. Reuses
    /// ``EvalReport/Environment`` so every report kind records the host the
    /// same way.
    public let environment: EvalReport.Environment?
    /// The stack this run measured.
    public let provenance: Provenance
    /// What populating the memory under test cost.
    public let writePath: WritePathCost

    // MARK: - Provenance

    /// The confounds a memory number is only interpretable against.
    ///
    /// Every field is a caller-supplied identity string rather than
    /// something the harness sniffs, because the harness cannot see through
    /// a `any EmbeddingProvider` existential to a meaningful name and a
    /// wrong-but-automatic label is worse than an explicit one.
    public struct Provenance: Sendable, Codable, Equatable {
        /// Identity of the embedding provider behind any dense index.
        public let embedder: String
        /// ``FactExtracting/name`` of the extractor that wrote the facts.
        public let extractor: String
        /// ``FactReconciling/name`` of the reconciler that routed them.
        public let reconciler: String
        /// Version tag for the prompt set in play, if any model-backed hook
        /// was enabled. `"none"` for a fully deterministic configuration.
        public let promptVersion: String
        /// On-device model availability at run time, in
        /// ``EvalReport/Environment/modelAvailability`` form.
        public let modelAvailability: String

        /// Creates a provenance record.
        public init(
            embedder: String,
            extractor: String,
            reconciler: String,
            promptVersion: String,
            modelAvailability: String
        ) {
            self.embedder = embedder
            self.extractor = extractor
            self.reconciler = reconciler
            self.promptVersion = promptVersion
            self.modelAvailability = modelAvailability
        }
    }

    // MARK: - Write-path cost

    /// What it cost to get the memory under test into its measured state.
    public struct WritePathCost: Sendable, Codable, Equatable {
        /// Model calls issued by the write path. Zero is the correct answer
        /// for a fully deterministic configuration, and a non-zero value in
        /// a baseline that claims determinism is a bug.
        public let modelCalls: Int
        /// Approximate prompt tokens spent by those calls.
        public let promptTokens: Int
        /// Wall-clock nanoseconds attributed to consolidation.
        public let wallClockNanoseconds: Int64

        /// Nothing was spent.
        public static let zero = WritePathCost(modelCalls: 0, promptTokens: 0, wallClockNanoseconds: 0)

        /// Creates a cost record.
        public init(modelCalls: Int, promptTokens: Int, wallClockNanoseconds: Int64) {
            self.modelCalls = modelCalls
            self.promptTokens = promptTokens
            self.wallClockNanoseconds = wallClockNanoseconds
        }

        /// Derives a cost record from the trace a consolidation pass left
        /// behind.
        ///
        /// - `modelCalls` and `wallClockNanoseconds` come from
        ///   ``TraceEvent/memoryConsolidated(runID:extracted:added:updated:deleted:archived:modelCalls:elapsed:)``,
        ///   which carries both as structured integers precisely so they can
        ///   be aggregated rather than scraped out of a log line.
        /// - `promptTokens` is estimated from the `promptBytes` on
        ///   ``TraceEvent/modelInvocationStarted(runID:turn:promptBytes:)``
        ///   divided by `charsPerToken`. It is an estimate and labelled as
        ///   one: the trace surface records bytes, not tokens, and adding a
        ///   token field to a shared event to make one eval prettier is not
        ///   a trade worth making. The default divisor matches
        ///   ``TokenBudgetedAssembler``'s so the two do not disagree.
        ///
        /// A deterministic configuration emits neither event, so this
        /// returns ``zero`` — the same answer a meter would give.
        public static func measure(
            tracer: InMemoryTracer,
            charsPerToken: Int = 4
        ) async -> WritePathCost {
            precondition(charsPerToken > 0, "charsPerToken must be positive")
            var calls = 0
            var bytes = 0
            var nanoseconds: Int64 = 0
            for event in await tracer.snapshot() {
                switch event {
                case .memoryConsolidated(_, _, _, _, _, _, let modelCalls, let elapsed):
                    calls += modelCalls
                    let (seconds, attoseconds) = elapsed.components
                    nanoseconds &+= seconds * 1_000_000_000 &+ attoseconds / 1_000_000_000
                case .modelInvocationStarted(_, _, let promptBytes):
                    bytes += promptBytes
                default:
                    continue
                }
            }
            return WritePathCost(
                modelCalls: calls,
                promptTokens: bytes / charsPerToken,
                wallClockNanoseconds: nanoseconds
            )
        }
    }

    // MARK: - Case outcome

    /// Outcome of one ``MemoryEvalCase``.
    public struct CaseOutcome: Sendable, Codable, Equatable {
        /// Identifier of the originating case.
        public let caseID: String
        /// Query used.
        public let query: String
        /// Case tags, sorted for a stable encoding.
        public let tags: [String]
        /// `true` when every required term was present and no forbidden
        /// term was. Always `false` when ``error`` is set.
        public let passed: Bool
        /// Required terms absent from the blob, sorted.
        public let missing: [String]
        /// Forbidden terms present in the blob, sorted.
        public let forbidden: [String]
        /// Ranked ids the retriever returned, in order. Empty when the
        /// retriever threw.
        public let retrievedIDs: [String]
        /// Description of the retriever's failure, or `nil` on a graded
        /// case.
        ///
        /// Not in the original sketch of this type, and added deliberately:
        /// a thrown retriever and an empty result set both grade as "failed
        /// to contain", and collapsing them would let an outage read as a
        /// recall regression. Recording the reason keeps the two
        /// distinguishable in a committed baseline.
        public let error: String?
        /// Wall-clock time the case took.
        public let elapsed: Duration

        /// Creates a case outcome.
        public init(
            caseID: String,
            query: String,
            tags: [String],
            passed: Bool,
            missing: [String],
            forbidden: [String],
            retrievedIDs: [String],
            error: String? = nil,
            elapsed: Duration
        ) {
            self.caseID = caseID
            self.query = query
            self.tags = tags
            self.passed = passed
            self.missing = missing
            self.forbidden = forbidden
            self.retrievedIDs = retrievedIDs
            self.error = error
            self.elapsed = elapsed
        }

        /// Short human-readable reason this case did not pass; empty when
        /// it did.
        public var failureDetail: String {
            if let error { return "errored: \(error)" }
            if passed { return "" }
            var parts: [String] = []
            if !missing.isEmpty { parts.append("missing [\(missing.joined(separator: ", "))]") }
            if !forbidden.isEmpty { parts.append("forbidden [\(forbidden.joined(separator: ", "))]") }
            return parts.isEmpty ? "failed" : parts.joined(separator: "; ")
        }

        private enum CodingKeys: String, CodingKey {
            case caseID, query, tags, passed, missing, forbidden, retrievedIDs, error
            case elapsedNanoseconds
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            caseID = try c.decode(String.self, forKey: .caseID)
            query = try c.decode(String.self, forKey: .query)
            tags = try c.decode([String].self, forKey: .tags)
            passed = try c.decode(Bool.self, forKey: .passed)
            missing = try c.decode([String].self, forKey: .missing)
            forbidden = try c.decode([String].self, forKey: .forbidden)
            retrievedIDs = try c.decode([String].self, forKey: .retrievedIDs)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            elapsed = Duration.nanoseconds(try c.decode(Int64.self, forKey: .elapsedNanoseconds))
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(caseID, forKey: .caseID)
            try c.encode(query, forKey: .query)
            try c.encode(tags, forKey: .tags)
            try c.encode(passed, forKey: .passed)
            try c.encode(missing, forKey: .missing)
            try c.encode(forbidden, forKey: .forbidden)
            try c.encode(retrievedIDs, forKey: .retrievedIDs)
            try c.encodeIfPresent(error, forKey: .error)
            let (seconds, attoseconds) = elapsed.components
            try c.encode(seconds * 1_000_000_000 &+ attoseconds / 1_000_000_000, forKey: .elapsedNanoseconds)
        }
    }

    // MARK: - Aggregate

    /// Suite-level pass counts.
    public struct Aggregate: Sendable, Codable, Equatable {
        /// Cases considered.
        public let caseCount: Int
        /// Cases that passed.
        public let passedCount: Int
        /// Passing fraction in `[0, 1]`; `0` for an empty slice.
        public let passRate: Double

        /// Creates an aggregate.
        public init(caseCount: Int, passedCount: Int, passRate: Double) {
            self.caseCount = caseCount
            self.passedCount = passedCount
            self.passRate = passRate
        }
    }

    /// Creates a report.
    public init(
        suiteName: String,
        runID: UUID = UUID(),
        started: Date,
        finished: Date,
        cases: [CaseOutcome],
        environment: EvalReport.Environment? = nil,
        provenance: Provenance,
        writePath: WritePathCost = .zero
    ) {
        self.suiteName = suiteName
        self.runID = runID
        self.started = started
        self.finished = finished
        self.cases = cases
        self.environment = environment
        self.provenance = provenance
        self.writePath = writePath
    }

    /// Aggregate over every case.
    public var aggregate: Aggregate { Self.aggregate(of: cases) }

    /// Aggregate over the cases whose tags overlap `tags` — the per-family
    /// breakdown (`["supersession"]`, `["purge"]`, `["obfuscation"]`) that
    /// makes a headline pass rate interpretable.
    public func aggregate(tags: Set<String>) -> Aggregate {
        Self.aggregate(of: cases.filter { !Set($0.tags).isDisjoint(with: tags) })
    }

    private static func aggregate(of cases: [CaseOutcome]) -> Aggregate {
        let passed = cases.filter(\.passed).count
        return Aggregate(
            caseCount: cases.count,
            passedCount: passed,
            passRate: cases.isEmpty ? 0 : Double(passed) / Double(cases.count)
        )
    }

    /// Pass rate over every case.
    public var passRate: Double { aggregate.passRate }

    /// Number of failing cases.
    public var failed: Int { cases.count - aggregate.passedCount }

    /// Wall-clock duration of the run.
    public var elapsed: Duration { .seconds(finished.timeIntervalSince(started)) }

    /// This report's pass rate minus `control`'s.
    ///
    /// The control is a memory-*off* retriever over the same corpus. MemDelta
    /// found an agent's self-managed memory (42%) losing outright to plain
    /// retrieval (47%) on the same questions, which is the failure mode this
    /// number exists to catch: a memory layer that is elaborate, expensive,
    /// and worse than not having one. A non-negative delta is a shipping
    /// precondition, not a nice-to-have, so the suite always reports it.
    ///
    /// - Note: Comparable only when both reports ran the same suite; the
    ///   caller is responsible for that, since a report carries its suite
    ///   name but not its cases' criteria.
    public func delta(from control: MemoryEvalReport) -> Double {
        passRate - control.passRate
    }

    /// This report's pass rate on `tags` minus `control`'s on the same
    /// tags — the per-family form of ``delta(from:)``.
    public func delta(from control: MemoryEvalReport, tags: Set<String>) -> Double {
        aggregate(tags: tags).passRate - control.aggregate(tags: tags).passRate
    }

    /// Returns a copy with every wall-clock- and UUID-derived field
    /// neutralized: ``started`` and ``finished`` collapse to the Unix
    /// epoch, ``runID`` becomes the all-zero UUID, every case's `elapsed`
    /// becomes `.zero`, and ``WritePathCost/wallClockNanoseconds`` becomes
    /// `0`.
    ///
    /// Verdicts, terms, ranked ids, ``environment``, ``provenance``, and the
    /// *deterministic* halves of ``writePath`` (model calls and prompt
    /// tokens) are preserved verbatim. Copies
    /// ``EvalReport/normalizedForBaseline()``'s contract, and extends it to
    /// the one field that type does not have: a wall-clock cost measured in
    /// nanoseconds would otherwise move on every regeneration and drown the
    /// diff that matters. Model calls survive normalization on purpose — a
    /// baseline that starts spending model calls on the write path is
    /// exactly the change a reviewer must see.
    public func normalizedForBaseline() -> MemoryEvalReport {
        MemoryEvalReport(
            suiteName: suiteName,
            runID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            started: Date(timeIntervalSince1970: 0),
            finished: Date(timeIntervalSince1970: 0),
            cases: cases.map {
                CaseOutcome(
                    caseID: $0.caseID,
                    query: $0.query,
                    tags: $0.tags,
                    passed: $0.passed,
                    missing: $0.missing,
                    forbidden: $0.forbidden,
                    retrievedIDs: $0.retrievedIDs,
                    error: $0.error,
                    elapsed: .zero
                )
            },
            environment: environment,
            provenance: provenance,
            writePath: WritePathCost(
                modelCalls: writePath.modelCalls,
                promptTokens: writePath.promptTokens,
                wallClockNanoseconds: 0
            )
        )
    }

    /// Projects this report into an ``EvalReport`` so ``EvalGate`` can gate
    /// it.
    ///
    /// ``EvalGate/compare(baseline:candidate:)`` is typed on ``EvalReport``.
    /// Rather than widen the gate — a shared file, and a generic signature
    /// nothing else needs — a memory report converts. The projection is
    /// lossy by design: it keeps exactly what the gate reads (case id and
    /// pass/fail) plus enough failure text for the gate's regression list to
    /// name what broke.
    ///
    /// Each case becomes a `completed` outcome carrying two named checks,
    /// `must-contain` and `must-not-contain`, so a CI log distinguishes "the
    /// right memory did not surface" from "the forgotten memory came back" —
    /// two very different bugs that a single boolean would flatten.
    public func evalReport() -> EvalReport {
        EvalReport(
            suiteName: suiteName,
            started: started,
            finished: finished,
            cases: cases.map { c in
                let result: EvalReport.CaseOutcome.Result
                if let error = c.error {
                    result = .errored(reason: error, elapsed: c.elapsed)
                } else {
                    result = .completed(
                        output: c.retrievedIDs.joined(separator: ","),
                        checks: [
                            .init(
                                name: "must-contain",
                                check: c.missing.isEmpty
                                    ? .pass
                                    : .fail("missing [\(c.missing.joined(separator: ", "))]")
                            ),
                            .init(
                                name: "must-not-contain",
                                check: c.forbidden.isEmpty
                                    ? .pass
                                    : .fail("forbidden [\(c.forbidden.joined(separator: ", "))]")
                            ),
                        ],
                        elapsed: c.elapsed
                    )
                }
                return EvalReport.CaseOutcome(
                    caseID: c.caseID,
                    prompt: c.query,
                    runID: runID,
                    result: result
                )
            },
            environment: environment
        )
    }

    /// Encodes the report as JSON with ISO 8601 dates and sorted keys, so
    /// stored baselines diff cleanly.
    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a report previously produced by ``jsonData(prettyPrinted:)``.
    public init(jsonData: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(MemoryEvalReport.self, from: jsonData)
    }

    /// Human-readable single-line summary suitable for CI logs. Programs
    /// should inspect ``aggregate`` instead.
    public func summary() -> String {
        let a = aggregate
        let rate = String(format: "%.3f", a.passRate)
        var line = "[\(suiteName)] \(a.passedCount)/\(a.caseCount) passed (\(rate))"
        line += " model-calls=\(writePath.modelCalls)"
        line += " prompt-tokens=\(writePath.promptTokens)"
        let errored = cases.filter { $0.error != nil }.count
        if errored > 0 { line += " errors=\(errored)" }
        return line
    }

    /// Verbose multi-line listing of every case and why it failed. Useful
    /// when investigating a regression locally.
    public func detailedReport() -> String {
        var out = summary() + "\n"
        for c in cases {
            let mark = c.passed ? "ok  " : "FAIL"
            out += "  \(mark) \(c.caseID)"
            if !c.passed { out += " — \(c.failureDetail)" }
            out += "\n"
        }
        return out
    }
}
