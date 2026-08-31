import Foundation

/// Aggregates ``TraceEvent`` values into rollup statistics suitable for
/// a dashboard or a periodic export. Does not replace per-event tracing
/// — pair with ``OSLogTracer`` or ``SignpostTracer`` via
/// ``CompositeTracer`` when you want both.
public actor MetricsCollectingTracer: Tracer {
    /// Current aggregated counters and latency stats.
    public private(set) var snapshot: MetricsSnapshot

    /// Creates a tracer with an empty snapshot.
    public init() {
        self.snapshot = MetricsSnapshot()
    }

    /// Folds `event` into ``snapshot``.
    public func record(_ event: TraceEvent) async {
        switch event {
        case .runStarted:
            snapshot.runsStarted += 1
        case .runEnded(_, let ok, let usage):
            snapshot.runsEnded += 1
            if ok { snapshot.runsSucceeded += 1 } else { snapshot.runsFailed += 1 }
            snapshot.totalTurns += usage.turns
            snapshot.totalToolCalls += usage.toolCalls
            snapshot.totalRepairAttempts += usage.repairAttempts
            snapshot.totalOutputTokens += usage.outputTokens

        case .modelInvocationCompleted(_, _, _, let elapsed):
            snapshot.modelInvocations += 1
            snapshot.modelLatency.record(elapsed)
        case .modelInvocationFailed:
            snapshot.modelFailures += 1

        case .toolInvocationCompleted(_, let name, let elapsed, let ok):
            snapshot.toolInvocations += 1
            if !ok { snapshot.toolFailures += 1 }
            var stat = snapshot.perTool[name] ?? .init()
            stat.count += 1
            stat.latency.record(elapsed)
            if !ok { stat.failures += 1 }
            snapshot.perTool[name] = stat
        case .toolPolicyDenied:
            snapshot.toolPolicyDenied += 1
        case .toolArgumentRejected:
            snapshot.toolArgumentRejections += 1
        case .toolOutputRejected:
            snapshot.toolOutputRejections += 1

        case .verifierEvaluated(_, let name, _, let verdict, let elapsed):
            var stat = snapshot.perVerifier[name] ?? .init()
            stat.count += 1
            stat.latency.record(elapsed)
            switch verdict {
            case .pass: stat.passes += 1
            case .repair: stat.repairs += 1
            case .reject: stat.rejects += 1
            case .escalate: stat.escalations += 1
            }
            snapshot.perVerifier[name] = stat

        case .repairScheduled:
            snapshot.repairsScheduled += 1
        case .budgetExhausted(_, let kind):
            snapshot.budgetExhausted[kind, default: 0] += 1
        case .escalation:
            snapshot.escalations += 1

        case .modelInvocationStarted, .toolInvocationRequested, .bestOfNSampled,
             .breakerTransitioned, .degradationApplied, .routingEscalated,
             .retrievalRound, .retrievalLoopEnded, .info, .unknown:
            break
        }
    }

    /// Resets the snapshot back to zero.
    public func reset() {
        snapshot = MetricsSnapshot()
    }

    /// Returns the current snapshot.
    public func current() -> MetricsSnapshot { snapshot }
}

/// Aggregated counters and latency stats produced by
/// ``MetricsCollectingTracer``. All fields are mutable by design so
/// callers can fold additional sources or persist snapshots across runs.
public struct MetricsSnapshot: Sendable {
    /// Number of `runStarted` events seen.
    public var runsStarted: Int = 0
    /// Number of `runEnded` events seen.
    public var runsEnded: Int = 0
    /// Number of runs that ended with `success=true`.
    public var runsSucceeded: Int = 0
    /// Number of runs that ended with `success=false`.
    public var runsFailed: Int = 0
    /// Cumulative model turns across all runs.
    public var totalTurns: Int = 0
    /// Cumulative tool calls across all runs.
    public var totalToolCalls: Int = 0
    /// Cumulative repair attempts across all runs.
    public var totalRepairAttempts: Int = 0
    /// Cumulative approximate output tokens across all runs.
    public var totalOutputTokens: Int = 0

    /// Number of completed model invocations.
    public var modelInvocations: Int = 0
    /// Number of failed model invocations.
    public var modelFailures: Int = 0
    /// Latency distribution for model invocations.
    public var modelLatency = LatencyStats()

    /// Number of completed tool invocations.
    public var toolInvocations: Int = 0
    /// Number of failed tool invocations.
    public var toolFailures: Int = 0
    /// Number of tool invocations denied by ``Policy``.
    public var toolPolicyDenied: Int = 0
    /// Number of tool invocations whose arguments were rejected by an
    /// argument verifier chain (the tool never executed).
    public var toolArgumentRejections: Int = 0
    /// Number of tool invocations whose output was rejected by an output
    /// verifier chain and withheld from the model.
    public var toolOutputRejections: Int = 0
    /// Per-tool breakdown keyed by tool name.
    public var perTool: [String: ToolStats] = [:]

    /// Per-verifier breakdown keyed by verifier name.
    public var perVerifier: [String: VerifierStats] = [:]

    /// Number of repair turns scheduled across all runs.
    public var repairsScheduled: Int = 0
    /// Number of escalations across all runs.
    public var escalations: Int = 0
    /// Count of budget exhaustions broken down by dimension.
    public var budgetExhausted: [BudgetExhaustion: Int] = [:]

    /// Creates a zeroed snapshot.
    public init() {}

    /// Successful runs as a fraction of ended runs (0 when no runs have ended).
    public var successRate: Double {
        runsEnded == 0 ? 0 : Double(runsSucceeded) / Double(runsEnded)
    }
    /// Average turns per ended run.
    public var averageTurnsPerRun: Double {
        runsEnded == 0 ? 0 : Double(totalTurns) / Double(runsEnded)
    }
    /// Average repair attempts per ended run.
    public var averageRepairsPerRun: Double {
        runsEnded == 0 ? 0 : Double(totalRepairAttempts) / Double(runsEnded)
    }

    /// Per-tool aggregated counters and latency.
    public struct ToolStats: Sendable {
        /// Total invocations.
        public var count: Int = 0
        /// Total failed invocations.
        public var failures: Int = 0
        /// Latency distribution.
        public var latency = LatencyStats()
        /// Creates a zeroed `ToolStats`.
        public init() {}
    }

    /// Per-verifier aggregated counters and latency.
    public struct VerifierStats: Sendable {
        /// Total evaluations.
        public var count: Int = 0
        /// Number of `.pass` verdicts.
        public var passes: Int = 0
        /// Number of `.repair` verdicts.
        public var repairs: Int = 0
        /// Number of `.reject` verdicts.
        public var rejects: Int = 0
        /// Number of `.escalate` verdicts.
        public var escalations: Int = 0
        /// Latency distribution.
        public var latency = LatencyStats()
        /// Creates a zeroed `VerifierStats`.
        public init() {}
        /// Passes as a fraction of evaluations.
        public var passRate: Double { count == 0 ? 0 : Double(passes) / Double(count) }
    }
}

/// Tiny running-stat record holding count, sum, min, max, and an
/// approximate `p50`/`p99` via a reservoir-style sample. For production
/// metrics you typically want a real histogram; this is the
/// dependency-free version that's still useful in development and small
/// deployments.
public struct LatencyStats: Sendable {
    /// Number of recorded samples.
    public private(set) var count: Int = 0
    /// Sum of all recorded sample durations in nanoseconds.
    public private(set) var totalNanoseconds: Int64 = 0
    /// Minimum recorded duration in nanoseconds.
    public private(set) var minNanoseconds: Int64 = .max
    /// Maximum recorded duration in nanoseconds.
    public private(set) var maxNanoseconds: Int64 = 0
    // `samples` is held in sorted (ascending) order at all times so that
    // `percentile(_:)` is O(log k) rather than O(k log k) on every read. The
    // sort cost is paid once on `record(_:)` via a binary-search insertion
    // (or remove-then-insert for reservoir replacement). At sampleCap=512
    // the constant-factor cost is trivial; in exchange every `p50ms`/`p99ms`
    // read becomes effectively free.
    private var samples: [Int64] = []
    private let sampleCap: Int

    /// Creates a stats accumulator with the supplied reservoir cap.
    public init(sampleCap: Int = 512) {
        self.sampleCap = sampleCap
    }

    /// Records `duration` and updates min/max/sum/percentile reservoir.
    public mutating func record(_ duration: Duration) {
        let ns = Self.nanoseconds(duration)
        count += 1
        totalNanoseconds += ns
        if ns < minNanoseconds { minNanoseconds = ns }
        if ns > maxNanoseconds { maxNanoseconds = ns }
        if samples.count < sampleCap {
            Self.sortedInsert(&samples, ns)
        } else {
            // Reservoir-style replacement so the sample stays representative.
            let i = Int.random(in: 0..<count)
            if i < sampleCap {
                samples.remove(at: i)
                Self.sortedInsert(&samples, ns)
            }
        }
    }

    /// Arithmetic mean of recorded durations in milliseconds.
    public var averageMilliseconds: Double {
        count == 0 ? 0 : Double(totalNanoseconds) / Double(count) / 1_000_000.0
    }
    /// Minimum recorded duration in milliseconds.
    public var minMilliseconds: Double { count == 0 ? 0 : Double(minNanoseconds) / 1_000_000.0 }
    /// Maximum recorded duration in milliseconds.
    public var maxMilliseconds: Double { count == 0 ? 0 : Double(maxNanoseconds) / 1_000_000.0 }

    /// Approximate percentile (0.0 ... 1.0) of recorded durations, in
    /// milliseconds, computed against the sorted reservoir.
    public func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let idx = min(samples.count - 1, max(0, Int(Double(samples.count - 1) * p)))
        return Double(samples[idx]) / 1_000_000.0
    }
    /// Convenience for `percentile(0.5)`.
    public var p50ms: Double { percentile(0.5) }
    /// Convenience for `percentile(0.99)`.
    public var p99ms: Double { percentile(0.99) }

    private static func sortedInsert(_ arr: inout [Int64], _ value: Int64) {
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if arr[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        arr.insert(value, at: lo)
    }

    private static func nanoseconds(_ d: Duration) -> Int64 {
        let parts = d.components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }
}
