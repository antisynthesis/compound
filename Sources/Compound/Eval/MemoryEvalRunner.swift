import Foundation

/// Runs a ``MemoryEvalSuite`` against any ``Retriever`` and produces a
/// ``MemoryEvalReport``.
///
/// Retriever-agnostic on purpose. The memory read path, a bare
/// ``BM25Retriever`` over the raw transcript, an ``ArchivalRetriever``, and a
/// ``HybridRetriever`` fusing several of those all satisfy ``Retriever``, so
/// the *same* suite measures each and the reports are directly comparable —
/// which is what makes ``MemoryEvalReport/delta(from:)`` meaningful rather
/// than a comparison of two differently-shaped experiments.
///
/// Mirrors ``RetrievalEvalRunner``: duplicate case ids are rejected up
/// front, cases run in a sliding concurrency window, declaration order is
/// restored in the report, and a retriever that throws fails only its own
/// case.
public struct MemoryEvalRunner: Sendable {
    /// Maximum cases evaluated in parallel.
    public let concurrency: Int

    /// Creates a runner.
    ///
    /// - Precondition: `concurrency >= 1`.
    public init(concurrency: Int = 4) {
        precondition(concurrency >= 1, "concurrency must be at least 1")
        self.concurrency = concurrency
    }

    /// Runs every case in `suite` against `retriever`.
    ///
    /// Each case asks the retriever for its own `k` results, builds the
    /// top-`k` blob, and grades it with ``MemoryEvalBlob/grade(_:sources:)``.
    /// No model is consulted at any point.
    ///
    /// `provenance` is required rather than defaulted: a memory number is a
    /// measurement of a whole stack, and a report that cannot say which
    /// stack it measured is not evidence of anything. `writePath` defaults
    /// to ``MemoryEvalReport/WritePathCost/zero``, which is the honest value
    /// for a deterministic configuration and the value
    /// ``MemoryEvalReport/WritePathCost/measure(tracer:charsPerToken:)``
    /// returns for one.
    ///
    /// - Throws: ``EvalError/duplicateCaseID(_:)`` if two cases share an id,
    ///   or `CancellationError` if the calling task is cancelled between
    ///   case admissions. Per-case retriever failures never throw — they are
    ///   captured in the report.
    public func run(
        _ suite: MemoryEvalSuite,
        against retriever: any Retriever,
        provenance: MemoryEvalReport.Provenance,
        writePath: MemoryEvalReport.WritePathCost = .zero
    ) async throws -> MemoryEvalReport {
        var seen = Set<String>()
        for c in suite.cases where !seen.insert(c.id).inserted {
            throw EvalError.duplicateCaseID(c.id)
        }

        let started = Date()
        let cases = suite.cases
        var outcomes: [MemoryEvalReport.CaseOutcome] = []
        outcomes.reserveCapacity(cases.count)

        try await withThrowingTaskGroup(of: MemoryEvalReport.CaseOutcome.self) { group in
            var next = 0
            while next < min(concurrency, cases.count) {
                let c = cases[next]
                next += 1
                group.addTask { await Self.runOne(c, retriever: retriever) }
            }
            while let outcome = try await group.next() {
                outcomes.append(outcome)
                try Task.checkCancellation()
                if next < cases.count {
                    let c = cases[next]
                    next += 1
                    group.addTask { await Self.runOne(c, retriever: retriever) }
                }
            }
        }

        // Restore declaration order. Duplicate ids were rejected above;
        // `uniquingKeysWith` degrades a future regression to first-wins
        // instead of trapping.
        let byID = Dictionary(outcomes.map { ($0.caseID, $0) }, uniquingKeysWith: { first, _ in first })
        return MemoryEvalReport(
            suiteName: suite.name,
            runID: UUID(),
            started: started,
            finished: Date(),
            cases: cases.compactMap { byID[$0.id] },
            environment: .current(),
            provenance: provenance,
            writePath: writePath
        )
    }

    private static func runOne(
        _ c: MemoryEvalCase,
        retriever: any Retriever
    ) async -> MemoryEvalReport.CaseOutcome {
        let started = ContinuousClock.now
        do {
            let sources = try await retriever.retrieve(query: c.query, limit: c.k)
            let verdict = MemoryEvalBlob.grade(c, sources: sources)
            return MemoryEvalReport.CaseOutcome(
                caseID: c.id,
                query: c.query,
                tags: c.tags.sorted(),
                passed: verdict.passed,
                missing: verdict.missing,
                forbidden: verdict.forbidden,
                retrievedIDs: sources.map(\.id),
                elapsed: ContinuousClock.now - started
            )
        } catch {
            // A thrown retriever is not a recall failure and must not be
            // filed as one: every required term is recorded as missing so
            // the row still grades as failed, and `error` says why.
            return MemoryEvalReport.CaseOutcome(
                caseID: c.id,
                query: c.query,
                tags: c.tags.sorted(),
                passed: false,
                missing: c.mustContain.sorted(),
                forbidden: [],
                retrievedIDs: [],
                error: String(describing: error),
                elapsed: ContinuousClock.now - started
            )
        }
    }
}
