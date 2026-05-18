import Foundation

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
    /// Returns `table[prompt]` if present, otherwise an empty string.
    public func respond(to prompt: String, auth _: AuthContext, metadata _: [String: String]) async throws -> String {
        table[prompt] ?? ""
    }
}

/// Executes an ``EvalSuite`` against an ``EvalTarget`` with bounded
/// concurrency and produces an ``EvalReport``.
public struct EvalRunner: Sendable {
    /// Maximum cases evaluated in parallel.
    public let concurrency: Int
    /// Tracer attached to each case's ``RunContext``.
    public let tracer: any Tracer

    /// Creates a runner.
    public init(concurrency: Int = 4, tracer: any Tracer = NullTracer()) {
        precondition(concurrency >= 1, "concurrency must be at least 1")
        self.concurrency = concurrency
        self.tracer = tracer
    }

    /// Runs every case in `suite` against `target`. Cases run in
    /// parallel up to ``concurrency``; the report preserves declaration
    /// order for stability.
    public func run(_ suite: EvalSuite, against target: any EvalTarget) async -> EvalReport {
        let started = Date()
        var outcomes: [EvalReport.CaseOutcome] = []
        outcomes.reserveCapacity(suite.cases.count)

        let cases = suite.cases
        var index = 0
        while index < cases.count {
            let upper = min(index + concurrency, cases.count)
            let batch = Array(cases[index..<upper])
            await withTaskGroup(of: EvalReport.CaseOutcome.self) { group in
                for c in batch {
                    group.addTask {
                        await Self.runOne(c, target: target, tracer: tracer)
                    }
                }
                for await result in group { outcomes.append(result) }
            }
            index = upper
        }
        // Preserve declared case order so reports are stable.
        let idToOutcome = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.caseID, $0) })
        outcomes = cases.compactMap { idToOutcome[$0.id] }
        return EvalReport(
            suiteName: suite.name,
            started: started,
            finished: Date(),
            cases: outcomes
        )
    }

    private static func runOne(
        _ c: EvalCase,
        target: any EvalTarget,
        tracer: any Tracer
    ) async -> EvalReport.CaseOutcome {
        let runID = UUID()
        let runContext = RunContext(runID: runID, auth: c.auth, tracer: tracer, metadata: c.metadata)
        let started = ContinuousClock.now
        do {
            let output = try await target.respond(to: c.prompt, auth: c.auth, metadata: c.metadata)
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
                result: .completed(output: output, checks: checks, elapsed: elapsed)
            )
        } catch {
            let elapsed = ContinuousClock.now - started
            return EvalReport.CaseOutcome(
                caseID: c.id,
                prompt: c.prompt,
                result: .errored(reason: String(describing: error), elapsed: elapsed)
            )
        }
    }
}
