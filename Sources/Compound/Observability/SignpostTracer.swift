import Foundation
import os

/// Latency you can see instead of guess at. An `OSSignposter`-backed
/// tracer that surfaces a Compound run in Instruments as proper
/// signposted events. Pairs well with ``OSLogTracer`` (which emits the
/// textual record) and is the instrument you reach for when you need to
/// know exactly where the time went across the six layers.
public struct SignpostTracer: Tracer {
    private let signposter: OSSignposter
    private let log: OSLog

    /// Creates a signpost tracer scoped to the supplied OSLog
    /// subsystem/category.
    public init(subsystem: String = "com.antisynthesis.compound", category: String = "run") {
        self.log = OSLog(subsystem: subsystem, category: category)
        self.signposter = OSSignposter(logHandle: log)
    }

    /// Emits a signpost event matching the case of `event`.
    public func record(_ event: TraceEvent) async {
        switch event {
        case .runStarted(let id, _, _, _):
            signposter.emitEvent("run.started", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public)")
        case .runEnded(let id, let ok, _):
            signposter.emitEvent("run.ended", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) ok=\(ok)")
        case .modelInvocationStarted(let id, let turn, _):
            signposter.emitEvent("model.start", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) turn=\(turn)")
        case .modelInvocationCompleted(let id, let turn, _, let elapsed):
            signposter.emitEvent("model.end", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) turn=\(turn) ms=\(Self.ms(elapsed))")
        case .modelInvocationFailed(let id, let turn, _):
            signposter.emitEvent("model.fail", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) turn=\(turn)")
        case .toolInvocationRequested(let id, let tool):
            signposter.emitEvent("tool.req", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public)")
        case .toolInvocationCompleted(let id, let tool, let elapsed, let ok):
            signposter.emitEvent("tool.end", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public) ok=\(ok) ms=\(Self.ms(elapsed))")
        case .toolPolicyDenied(let id, let tool, _):
            signposter.emitEvent("tool.denied", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public)")
        case .verifierEvaluated(let id, let v, _, _, let elapsed):
            signposter.emitEvent("verifier", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) v=\(v, privacy: .public) ms=\(Self.ms(elapsed))")
        case .repairScheduled(let id, let attempt, _):
            signposter.emitEvent("repair", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) attempt=\(attempt)")
        case .budgetExhausted(let id, let kind):
            signposter.emitEvent("budget", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) kind=\(kind.rawValue, privacy: .public)")
        case .escalation(let id, _):
            signposter.emitEvent("escalation", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public)")
        case .info(let id, let cat, _):
            signposter.emitEvent("info", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) cat=\(cat, privacy: .public)")
        case .unknown(let id, let label, _):
            signposter.emitEvent("unknown", id: signposter.makeSignpostID(), "run=\(id.uuidString, privacy: .public) label=\(label, privacy: .public)")
        }
    }

    private static func ms(_ d: Duration) -> Int {
        let parts = d.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// One event, many witnesses. Fans every recorded event out to multiple
/// tracers so callers can pair textual ``OSLogTracer`` records with
/// ``SignpostTracer`` signposts (or any other combination) without
/// subclassing.
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
