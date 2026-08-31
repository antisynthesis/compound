import Foundation
import os

/// `os_signpost`-backed tracer that surfaces a Compound run in
/// Instruments. Pairs well with ``OSLogTracer`` (which emits the textual
/// record) and is essential for profiling latency breakdown across the
/// six layers.
///
/// Paired events are emitted as **intervals**, not points: a run, a model
/// turn, and a tool invocation each open with `.begin` and close with
/// `.end` under a signpost ID derived deterministically from the run —
/// and, for turns and tools, from the turn index or tool name. That is
/// what makes Instruments draw a duration bar and compute a latency
/// distribution. The ID must be reproducible because `begin` and `end`
/// arrive as two independent ``TraceEvent`` values with no shared state
/// between them; deriving it from the payload keeps this tracer a
/// stateless `struct`.
///
/// Unpaired events (denials, rejections, escalations, budget exhaustion,
/// info) stay point events under the run's ID, so they land on the run's
/// own Instruments lane.
///
/// Collision note: two invocations of the *same* tool overlapping inside
/// one run share an interval ID and will be paired in emission order.
/// That is the same trade the tool-name key already makes in metrics, and
/// it keeps the tracer allocation- and lock-free on the critical path.
public struct SignpostTracer: Tracer {
    private let signposter: OSSignposter
    private let log: OSLog

    /// Creates a signpost tracer scoped to the supplied OSLog
    /// subsystem/category.
    public init(subsystem: String = "com.antisynthesis.compound", category: String = "run") {
        self.log = OSLog(subsystem: subsystem, category: category)
        self.signposter = OSSignposter(logHandle: log)
    }

    /// Emits a signpost matching the case of `event` — an interval
    /// endpoint for paired cases, a point event otherwise.
    public func record(_ event: TraceEvent) async {
        switch event {
        case .runStarted(let id, _, _, _):
            os_signpost(.begin, log: log, name: "run", signpostID: Self.runID(id),
                        "run=%{public}s", id.uuidString)
        case .runEnded(let id, let ok, let usage):
            os_signpost(.end, log: log, name: "run", signpostID: Self.runID(id),
                        "run=%{public}s ok=%{public}d turns=%{public}ld tools=%{public}ld",
                        id.uuidString, ok ? 1 : 0, usage.turns, usage.toolCalls)

        case .modelInvocationStarted(let id, let turn, let bytes):
            os_signpost(.begin, log: log, name: "model.turn", signpostID: Self.turnID(id, turn: turn),
                        "run=%{public}s turn=%{public}ld bytes=%{public}ld", id.uuidString, turn, bytes)
        case .modelInvocationCompleted(let id, let turn, let bytes, let elapsed):
            os_signpost(.end, log: log, name: "model.turn", signpostID: Self.turnID(id, turn: turn),
                        "run=%{public}s turn=%{public}ld bytes=%{public}ld ms=%{public}ld",
                        id.uuidString, turn, bytes, Self.ms(elapsed))
        case .modelInvocationFailed(let id, let turn, _):
            os_signpost(.end, log: log, name: "model.turn", signpostID: Self.turnID(id, turn: turn),
                        "run=%{public}s turn=%{public}ld failed=1", id.uuidString, turn)

        case .toolInvocationRequested(let id, let tool):
            os_signpost(.begin, log: log, name: "tool", signpostID: Self.toolID(id, tool: tool),
                        "run=%{public}s tool=%{public}s", id.uuidString, tool)
        case .toolInvocationCompleted(let id, let tool, let elapsed, let ok):
            os_signpost(.end, log: log, name: "tool", signpostID: Self.toolID(id, tool: tool),
                        "run=%{public}s tool=%{public}s ok=%{public}d ms=%{public}ld",
                        id.uuidString, tool, ok ? 1 : 0, Self.ms(elapsed))
        case .toolPolicyDenied(let id, let tool, _):
            // A denied call never began, so close the interval the
            // request opened rather than leaving it dangling.
            os_signpost(.end, log: log, name: "tool", signpostID: Self.toolID(id, tool: tool),
                        "run=%{public}s tool=%{public}s denied=1", id.uuidString, tool)
            signposter.emitEvent("tool.denied", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public)")
        case .toolArgumentRejected(let id, let tool, _):
            os_signpost(.end, log: log, name: "tool", signpostID: Self.toolID(id, tool: tool),
                        "run=%{public}s tool=%{public}s argrej=1", id.uuidString, tool)
            signposter.emitEvent("tool.argrej", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public)")
        case .toolOutputRejected(let id, let tool, _):
            signposter.emitEvent("tool.outrej", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public)")

        case .verifierEvaluated(let id, let verifier, _, _, let elapsed):
            signposter.emitEvent("verifier", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) v=\(verifier, privacy: .public) ms=\(Self.ms(elapsed))")
        case .bestOfNSampled(let id, let candidates, _, _, let selectedIndex):
            signposter.emitEvent("sampling", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) n=\(candidates) selected=\(selectedIndex)")
        case .breakerTransitioned(let id, let signal, _, let to, _):
            signposter.emitEvent("health.breaker", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) signal=\(signal.rawValue, privacy: .public) to=\(to.rawValue, privacy: .public)")
        case .degradationApplied(let id, let mode, _):
            signposter.emitEvent("health.degraded", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) mode=\(mode.rawValue, privacy: .public)")
        case .routingEscalated(let id, _, _, let attempt):
            signposter.emitEvent("routing", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) attempt=\(attempt)")
        case .retrievalRound(let id, let round, _, let retrieved, let new, _):
            signposter.emitEvent("retrieval.round", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) round=\(round) retrieved=\(retrieved) new=\(new)")
        case .retrievalLoopEnded(let id, let rounds, let sources, let reason):
            signposter.emitEvent("retrieval.done", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) rounds=\(rounds) sources=\(sources) reason=\(reason, privacy: .public)")
        case .repairScheduled(let id, let attempt, _):
            signposter.emitEvent("repair", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) attempt=\(attempt)")
        case .budgetExhausted(let id, let kind):
            signposter.emitEvent("budget", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) kind=\(kind.rawValue, privacy: .public)")
        case .escalation(let id, _):
            signposter.emitEvent("escalation", id: Self.runID(id), "run=\(id.uuidString, privacy: .public)")
        case .info(let id, let category, _):
            signposter.emitEvent("info", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) cat=\(category, privacy: .public)")
        case .unknown(let id, let label, _):
            signposter.emitEvent("unknown", id: Self.runID(id),
                                 "run=\(id.uuidString, privacy: .public) label=\(label, privacy: .public)")
        }
    }

    // MARK: - Deterministic signpost identifiers

    /// Interval ID for the run itself.
    static func runID(_ runID: UUID) -> OSSignpostID {
        signpostID(hash(runID))
    }

    /// Interval ID for one model turn within a run.
    static func turnID(_ runID: UUID, turn: Int) -> OSSignpostID {
        signpostID(mix(hash(runID), with: UInt64(bitPattern: Int64(turn)) &+ 1))
    }

    /// Interval ID for one tool invocation within a run.
    static func toolID(_ runID: UUID, tool: String) -> OSSignpostID {
        signpostID(mix(hash(runID), with: hash(tool)))
    }

    /// FNV-1a over the UUID's bytes — a stable hash across processes,
    /// unlike `Hashable`, which is seeded per launch.
    private static func hash(_ uuid: UUID) -> UInt64 {
        withUnsafeBytes(of: uuid.uuid) { bytes in
            bytes.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { accumulated, byte in
                (accumulated ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
        }
    }

    /// FNV-1a over a tool name, for the same reason.
    private static func hash(_ text: String) -> UInt64 {
        text.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { accumulated, byte in
            (accumulated ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
    }

    private static func mix(_ lhs: UInt64, with rhs: UInt64) -> UInt64 {
        (lhs ^ (rhs &* 0x9E37_79B9_7F4A_7C15)) &* 0x0000_0100_0000_01B3
    }

    /// Wraps a hash as an `OSSignpostID`, stepping off the two reserved
    /// values so an interval is never silently dropped.
    private static func signpostID(_ value: UInt64) -> OSSignpostID {
        var raw = value
        for _ in 0..<2 {
            let candidate = OSSignpostID(raw)
            if candidate != .invalid && candidate != .exclusive { return candidate }
            raw &+= 1
        }
        return OSSignpostID(raw)
    }

    private static func ms(_ d: Duration) -> Int {
        let parts = d.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// Fans every recorded event out to multiple tracers so callers can pair
/// textual ``OSLogTracer`` records with ``SignpostTracer`` signposts (or
/// any other combination) without subclassing.
///
/// Tracers are invoked concurrently inside a task group so a slow tracer
/// (e.g. a ``JSONLTracer`` doing `fsync`) does not block faster siblings
/// (e.g. an in-process metrics aggregator). ``record(_:)`` returns once
/// every inner tracer has finished. Cross-tracer ordering is therefore
/// non-deterministic; fan out manually if strict order is required.
public struct CompositeTracer: Tracer {
    /// Member tracers, invoked concurrently per event.
    public let tracers: [any Tracer]
    /// Creates a composite over the supplied tracers.
    public init(_ tracers: [any Tracer]) { self.tracers = tracers }
    /// Fans `event` out to every member concurrently.
    public func record(_ event: TraceEvent) async {
        await withTaskGroup(of: Void.self) { group in
            for t in tracers {
                group.addTask { [t, event] in
                    await t.record(event)
                }
            }
            await group.waitForAll()
        }
    }
}
