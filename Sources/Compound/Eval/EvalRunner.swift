import Foundation

/// Typed errors thrown by the eval harness itself (as opposed to errors
/// thrown by the target under evaluation, which are captured per-case in
/// the report).
public enum EvalError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Two cases in the suite share the same ``EvalCase/id``. Reports are
    /// keyed by case id, so duplicates would silently shadow each other.
    case duplicateCaseID(String)
    /// A ``StubEvalTarget`` was asked for a prompt not present in its
    /// lookup table.
    case unknownPrompt(String)

    public var description: String {
        switch self {
        case .duplicateCaseID(let id):
            return "duplicate eval case id '\(id)'"
        case .unknownPrompt(let prompt):
            return "stub target has no entry for prompt '\(prompt)'"
        }
    }
}

/// Thing under evaluation: anything that takes a prompt and produces an
/// output string. Typically a ``CompoundSession``, but factored as a
/// protocol so tests, dry-runs, and CI replay against recorded outputs
/// all work.
public protocol EvalTarget: Sendable {
    /// Runs the target against `prompt` and returns the final output.
    func respond(to prompt: String, auth: AuthContext, metadata: [String: String]) async throws -> String
}

extension CompoundSession: EvalTarget {
    /// Bridges ``CompoundSession`` into ``EvalTarget`` by extracting
    /// ``LoopOutcome/output``.
    public func respond(to prompt: String, auth: AuthContext, metadata: [String: String]) async throws -> String {
        let outcome: LoopOutcome = try await respond(
            to: prompt,
            auth: auth,
            progress: NullProgressReporter(),
            metadata: metadata
        )
        return outcome.output
    }
}

/// Fake target backed by a prompt→output lookup table. Useful for
/// deterministic eval runs in tests.
public struct StubEvalTarget: EvalTarget {
    private let table: [String: String]
    /// Creates a stub over `table`.
    public init(_ table: [String: String]) { self.table = table }
    /// Returns `table[prompt]` if present; throws
    /// ``EvalError/unknownPrompt(_:)`` otherwise. A missing entry is a
    /// harness bug, not a model behavior — returning a silent default
    /// would let negative predicates (e.g. ``DoesNotContainPredicate``)
    /// pass vacuously.
    public func respond(to prompt: String, auth _: AuthContext, metadata _: [String: String]) async throws -> String {
        guard let output = table[prompt] else {
            throw EvalError.unknownPrompt(prompt)
        }
        return output
    }
}

/// Executes an ``EvalSuite`` against an ``EvalTarget`` with bounded
/// concurrency and produces an ``EvalReport``.
public struct EvalRunner: Sendable {
    /// Maximum cases evaluated in parallel.
    public let concurrency: Int
    /// Per-case wall-clock timeout. When set, a case whose target does not
    /// respond within this duration is cancelled and recorded as
    /// ``EvalReport/CaseOutcome/Result/timedOut(elapsed:)`` — a hung
    /// on-device run cannot hang the whole suite. `nil` disables the
    /// timeout.
    public let caseTimeout: Duration?
    /// Tracer attached to each case's ``RunContext``.
    public let tracer: any Tracer

    /// Creates a runner.
    public init(
        concurrency: Int = 4,
        caseTimeout: Duration? = nil,
        tracer: any Tracer = NullTracer()
    ) {
        precondition(concurrency >= 1, "concurrency must be at least 1")
        self.concurrency = concurrency
        self.caseTimeout = caseTimeout
        self.tracer = tracer
    }

    /// Runs every case in `suite` against `target`. Cases run in parallel
    /// with a sliding window of width ``concurrency`` — a new case is
    /// admitted as soon as any in-flight case finishes, so one slow case
    /// no longer stalls a whole batch. The report preserves declaration
    /// order for stability.
    ///
    /// - Throws: ``EvalError/duplicateCaseID(_:)`` if two cases share an
    ///   id, or `CancellationError` if the calling task is cancelled
    ///   between case admissions. Per-case failures never throw — they are
    ///   captured in the report.
    public func run(_ suite: EvalSuite, against target: any EvalTarget) async throws -> EvalReport {
        var seen = Set<String>()
        for c in suite.cases where !seen.insert(c.id).inserted {
            throw EvalError.duplicateCaseID(c.id)
        }

        let started = Date()
        let cases = suite.cases
        let timeout = caseTimeout
        let tracer = tracer
        var outcomes: [EvalReport.CaseOutcome] = []
        outcomes.reserveCapacity(cases.count)

        try await withThrowingTaskGroup(of: EvalReport.CaseOutcome.self) { group in
            var next = 0
            // Seed the window.
            while next < min(concurrency, cases.count) {
                let c = cases[next]
                next += 1
                group.addTask { await Self.runOne(c, target: target, tracer: tracer, timeout: timeout) }
            }
            // Admit one new case per completion.
            while let outcome = try await group.next() {
                outcomes.append(outcome)
                try Task.checkCancellation()
                if next < cases.count {
                    let c = cases[next]
                    next += 1
                    group.addTask { await Self.runOne(c, target: target, tracer: tracer, timeout: timeout) }
                }
            }
        }

        // Preserve declared case order so reports are stable. Duplicate ids
        // were rejected above; `uniquingKeysWith` is defense in depth so a
        // future regression degrades to first-wins instead of trapping.
        let idToOutcome = Dictionary(outcomes.map { ($0.caseID, $0) }, uniquingKeysWith: { first, _ in first })
        return EvalReport(
            suiteName: suite.name,
            started: started,
            finished: Date(),
            cases: cases.compactMap { idToOutcome[$0.id] },
            environment: .current()
        )
    }

    private static func runOne(
        _ c: EvalCase,
        target: any EvalTarget,
        tracer: any Tracer,
        timeout: Duration?
    ) async -> EvalReport.CaseOutcome {
        let runID = UUID()
        let runContext = RunContext(runID: runID, auth: c.auth, tracer: tracer, metadata: c.metadata)
        let started = ContinuousClock.now
        do {
            let output: String
            if let timeout {
                output = try await withDeadline(timeout) {
                    try await target.respond(to: c.prompt, auth: c.auth, metadata: c.metadata)
                }
            } else {
                output = try await target.respond(to: c.prompt, auth: c.auth, metadata: c.metadata)
            }
            var checks: [EvalReport.CaseOutcome.PredicateOutcome] = []
            for predicate in c.predicates {
                do {
                    let check = try await predicate.evaluate(output: output, runContext: runContext)
                    checks.append(.init(name: predicate.name, check: check))
                } catch {
                    checks.append(.init(name: predicate.name, check: .fail("predicate threw: \(error)")))
                }
            }
            let elapsed = ContinuousClock.now - started
            return EvalReport.CaseOutcome(
                caseID: c.id,
                prompt: c.prompt,
                runID: runID,
                result: .completed(output: output, checks: checks, elapsed: elapsed)
            )
        } catch is DeadlineExceededError {
            let elapsed = ContinuousClock.now - started
            return EvalReport.CaseOutcome(
                caseID: c.id,
                prompt: c.prompt,
                runID: runID,
                result: .timedOut(elapsed: elapsed)
            )
        } catch {
            let elapsed = ContinuousClock.now - started
            return EvalReport.CaseOutcome(
                caseID: c.id,
                prompt: c.prompt,
                runID: runID,
                result: .errored(reason: String(describing: error), elapsed: elapsed)
            )
        }
    }
}
