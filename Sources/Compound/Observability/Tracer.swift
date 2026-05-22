import Foundation
import os

/// The place where nothing happens off the books. A sink for structured
/// ``TraceEvent`` values — every model call, every verdict, every
/// decision, written down. Implementations should be non-blocking and
/// idempotent. The control loop emits trace events on the critical path
/// and never awaits a response from the tracer beyond the actor hop.
///
/// # Example
/// ```swift
/// let tracer = InMemoryTracer()
/// let ctx = RunContext(tracer: tracer)
/// ```
public protocol Tracer: Sendable {
    /// Records a single event.
    func record(_ event: TraceEvent) async
}

/// The tracer that remembers nothing. A no-op ``Tracer`` and the default
/// in ``RunContext`` — present so the seam never has to check for nil,
/// silent until you choose to see.
public struct NullTracer: Tracer {
    /// Creates an instance.
    public init() {}
    /// Drops the event.
    public func record(_: TraceEvent) async {}
}

/// The whole run, held in the hand and nowhere else. A bounded
/// in-memory tracer that stores up to ``capacity`` events in FIFO order;
/// the oldest events are dropped once the cap is exceeded. Memory that
/// never touches disk and never leaves the process.
public actor InMemoryTracer: Tracer {
    /// Events captured so far.
    private(set) public var events: [TraceEvent] = []
    /// Maximum number of events retained before FIFO eviction kicks in.
    public let capacity: Int

    /// Creates a tracer with the supplied ring-buffer capacity.
    public init(capacity: Int = 1024) {
        self.capacity = capacity
    }

    /// Appends `event` and trims excess from the front.
    public func record(_ event: TraceEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    /// Returns a copy of the recorded events.
    public func snapshot() -> [TraceEvent] {
        events
    }

    /// Discards all recorded events while keeping capacity.
    public func clear() {
        events.removeAll(keepingCapacity: true)
    }

    /// Returns the events scoped to a single `runID`.
    public func events(for runID: UUID) -> [TraceEvent] {
        events.filter { $0.runID == runID }
    }
}

/// Observability that refuses to leak. An Apple `os.Logger`-backed
/// tracer with configurable privacy markings: you get to see the run
/// without the run carrying your secrets into the log archive. Default
/// ``PrivacyLevel/balanced`` keeps stable identifiers public (run IDs,
/// counts, verifier names) while routing free-form text to `.private`
/// so log archives do not leak embedded secrets or PII.
public struct OSLogTracer: Tracer {
    /// The leash on what the log is allowed to remember. Controls how
    /// strongly `TraceEvent` fields are redacted when emitted to OSLog.
    ///
    /// Reject reasons, repair messages, info text, and similar fields
    /// may carry raw model input — including URLs/paths with embedded
    /// secrets — so the default is ``balanced``: only stable, low-
    /// cardinality identifiers (run IDs, counts, verifier names, success
    /// bools, budget kinds) remain `.public`; free-form text becomes
    /// `.private`.
    public enum PrivacyLevel: Sendable {
        /// Legacy "everything public" behavior. Use only when no field
        /// can contain user input.
        case maximal
        /// Identifiers/counts public; free-form text private.
        case balanced
        /// Even structured identifiers are emitted `.private`.
        case opaque
    }

    private let logger: Logger
    private let privacyLevel: PrivacyLevel
    private let toolNamesArePublic: Bool

    /// Creates an OSLog-backed tracer.
    ///
    /// - Parameters:
    ///   - subsystem: OSLog subsystem identifier.
    ///   - category: OSLog category.
    ///   - privacyLevel: Field-level redaction policy.
    ///   - toolNamesArePublic: When `true` (the default), tool names are
    ///     emitted `.public` under ``PrivacyLevel/balanced``.
    public init(
        subsystem: String = "com.antisynthesis.compound",
        category: String = "run",
        privacyLevel: PrivacyLevel = .balanced,
        toolNamesArePublic: Bool = true
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.privacyLevel = privacyLevel
        self.toolNamesArePublic = toolNamesArePublic
    }

    /// Routes the event to one of three privacy-specific emit paths.
    /// Each path uses literal `OSLogPrivacy` values so the OSLog format
    /// strings constant-fold properly.
    public func record(_ event: TraceEvent) async {
        switch privacyLevel {
        case .maximal:
            emitMaximal(event)
        case .balanced:
            emitBalanced(event)
        case .opaque:
            emitOpaque(event)
        }
    }

    // MARK: - .maximal — preserves the legacy "everything public" behavior.
    private func emitMaximal(_ event: TraceEvent) {
        switch event {
        case .runStarted(let id, let prompt, _, let auth):
            logger.info("run.started run=\(id.uuidString, privacy: .public) auth=\(auth, privacy: .public) bytes=\(prompt.utf8.count, privacy: .public)")
        case .runEnded(let id, let ok, let usage):
            logger.info("run.ended run=\(id.uuidString, privacy: .public) ok=\(ok, privacy: .public) turns=\(usage.turns, privacy: .public) tools=\(usage.toolCalls, privacy: .public) repairs=\(usage.repairAttempts, privacy: .public)")
        case .modelInvocationStarted(let id, let turn, let bytes):
            logger.debug("model.started run=\(id.uuidString, privacy: .public) turn=\(turn, privacy: .public) bytes=\(bytes, privacy: .public)")
        case .modelInvocationCompleted(let id, let turn, let bytes, let elapsed):
            logger.debug("model.completed run=\(id.uuidString, privacy: .public) turn=\(turn, privacy: .public) bytes=\(bytes, privacy: .public) ms=\(Self.ms(elapsed), privacy: .public)")
        case .modelInvocationFailed(let id, let turn, let reason):
            logger.error("model.failed run=\(id.uuidString, privacy: .public) turn=\(turn, privacy: .public) reason=\(reason, privacy: .public)")
        case .toolInvocationRequested(let id, let tool):
            logger.debug("tool.requested run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public)")
        case .toolInvocationCompleted(let id, let tool, let elapsed, let ok):
            logger.debug("tool.completed run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public) ok=\(ok, privacy: .public) ms=\(Self.ms(elapsed), privacy: .public)")
        case .toolPolicyDenied(let id, let tool, let reason):
            logger.notice("tool.denied run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public) reason=\(reason, privacy: .public)")
        case .verifierEvaluated(let id, let v, let cost, let verdict, let elapsed):
            logger.debug("verifier.evaluated run=\(id.uuidString, privacy: .public) v=\(v, privacy: .public) cost=\(cost.rawValue, privacy: .public) verdict=\(Self.label(verdict), privacy: .public) ms=\(Self.ms(elapsed), privacy: .public)")
        case .repairScheduled(let id, let attempt, let diag):
            logger.info("repair.scheduled run=\(id.uuidString, privacy: .public) attempt=\(attempt, privacy: .public) why=\(diag.summary, privacy: .public)")
        case .budgetExhausted(let id, let kind):
            logger.notice("budget.exhausted run=\(id.uuidString, privacy: .public) kind=\(kind.rawValue, privacy: .public)")
        case .escalation(let id, let reason):
            logger.notice("escalation run=\(id.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
        case .info(let id, let category, let message):
            logger.info("info run=\(id.uuidString, privacy: .public) cat=\(category, privacy: .public) msg=\(message, privacy: .public)")
        case .unknown(let id, let label, let payload):
            logger.info("trace.unknown run=\(id.uuidString, privacy: .public) label=\(label, privacy: .public) keys=\(payload.keys.sorted().joined(separator: ","), privacy: .public)")
        }
    }

    // MARK: - .balanced — IDs/counts/labels public; free-form text private.
    // Tool names follow `toolNamesArePublic`; default is true since they
    // are typically ops-level identifiers (e.g. "fetch", "shell").
    private func emitBalanced(_ event: TraceEvent) {
        switch event {
        case .runStarted(let id, let prompt, _, let auth):
            logger.info("run.started run=\(id.uuidString, privacy: .public) auth=\(auth, privacy: .public) bytes=\(prompt.utf8.count, privacy: .public)")
        case .runEnded(let id, let ok, let usage):
            logger.info("run.ended run=\(id.uuidString, privacy: .public) ok=\(ok, privacy: .public) turns=\(usage.turns, privacy: .public) tools=\(usage.toolCalls, privacy: .public) repairs=\(usage.repairAttempts, privacy: .public)")
        case .modelInvocationStarted(let id, let turn, let bytes):
            logger.debug("model.started run=\(id.uuidString, privacy: .public) turn=\(turn, privacy: .public) bytes=\(bytes, privacy: .public)")
        case .modelInvocationCompleted(let id, let turn, let bytes, let elapsed):
            logger.debug("model.completed run=\(id.uuidString, privacy: .public) turn=\(turn, privacy: .public) bytes=\(bytes, privacy: .public) ms=\(Self.ms(elapsed), privacy: .public)")
        case .modelInvocationFailed(let id, let turn, let reason):
            logger.error("model.failed run=\(id.uuidString, privacy: .public) turn=\(turn, privacy: .public) reason=\(reason, privacy: .private)")
        case .toolInvocationRequested(let id, let tool):
            if toolNamesArePublic {
                logger.debug("tool.requested run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public)")
            } else {
                logger.debug("tool.requested run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .private)")
            }
        case .toolInvocationCompleted(let id, let tool, let elapsed, let ok):
            if toolNamesArePublic {
                logger.debug("tool.completed run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public) ok=\(ok, privacy: .public) ms=\(Self.ms(elapsed), privacy: .public)")
            } else {
                logger.debug("tool.completed run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .private) ok=\(ok, privacy: .public) ms=\(Self.ms(elapsed), privacy: .public)")
            }
        case .toolPolicyDenied(let id, let tool, let reason):
            if toolNamesArePublic {
                logger.notice("tool.denied run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public) reason=\(reason, privacy: .private)")
            } else {
                logger.notice("tool.denied run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .private) reason=\(reason, privacy: .private)")
            }
        case .verifierEvaluated(let id, let v, let cost, let verdict, let elapsed):
            logger.debug("verifier.evaluated run=\(id.uuidString, privacy: .public) v=\(v, privacy: .public) cost=\(cost.rawValue, privacy: .public) verdict=\(Self.label(verdict), privacy: .public) ms=\(Self.ms(elapsed), privacy: .public)")
        case .repairScheduled(let id, let attempt, let diag):
            logger.info("repair.scheduled run=\(id.uuidString, privacy: .public) attempt=\(attempt, privacy: .public) why=\(diag.summary, privacy: .private)")
        case .budgetExhausted(let id, let kind):
            logger.notice("budget.exhausted run=\(id.uuidString, privacy: .public) kind=\(kind.rawValue, privacy: .public)")
        case .escalation(let id, let reason):
            logger.notice("escalation run=\(id.uuidString, privacy: .public) reason=\(reason, privacy: .private)")
        case .info(let id, let category, let message):
            logger.info("info run=\(id.uuidString, privacy: .public) cat=\(category, privacy: .public) msg=\(message, privacy: .private)")
        case .unknown(let id, let label, let payload):
            logger.info("trace.unknown run=\(id.uuidString, privacy: .public) label=\(label, privacy: .public) keys=\(payload.keys.sorted().joined(separator: ","), privacy: .private)")
        }
    }

    // MARK: - .opaque — everything (including IDs) emitted as .private.
    private func emitOpaque(_ event: TraceEvent) {
        switch event {
        case .runStarted(let id, let prompt, _, let auth):
            logger.info("run.started run=\(id.uuidString, privacy: .private) auth=\(auth, privacy: .private) bytes=\(prompt.utf8.count, privacy: .private)")
        case .runEnded(let id, let ok, let usage):
            logger.info("run.ended run=\(id.uuidString, privacy: .private) ok=\(ok, privacy: .private) turns=\(usage.turns, privacy: .private) tools=\(usage.toolCalls, privacy: .private) repairs=\(usage.repairAttempts, privacy: .private)")
        case .modelInvocationStarted(let id, let turn, let bytes):
            logger.debug("model.started run=\(id.uuidString, privacy: .private) turn=\(turn, privacy: .private) bytes=\(bytes, privacy: .private)")
        case .modelInvocationCompleted(let id, let turn, let bytes, let elapsed):
            logger.debug("model.completed run=\(id.uuidString, privacy: .private) turn=\(turn, privacy: .private) bytes=\(bytes, privacy: .private) ms=\(Self.ms(elapsed), privacy: .private)")
        case .modelInvocationFailed(let id, let turn, let reason):
            logger.error("model.failed run=\(id.uuidString, privacy: .private) turn=\(turn, privacy: .private) reason=\(reason, privacy: .private)")
        case .toolInvocationRequested(let id, let tool):
            logger.debug("tool.requested run=\(id.uuidString, privacy: .private) tool=\(tool, privacy: .private)")
        case .toolInvocationCompleted(let id, let tool, let elapsed, let ok):
            logger.debug("tool.completed run=\(id.uuidString, privacy: .private) tool=\(tool, privacy: .private) ok=\(ok, privacy: .private) ms=\(Self.ms(elapsed), privacy: .private)")
        case .toolPolicyDenied(let id, let tool, let reason):
            logger.notice("tool.denied run=\(id.uuidString, privacy: .private) tool=\(tool, privacy: .private) reason=\(reason, privacy: .private)")
        case .verifierEvaluated(let id, let v, let cost, let verdict, let elapsed):
            logger.debug("verifier.evaluated run=\(id.uuidString, privacy: .private) v=\(v, privacy: .private) cost=\(cost.rawValue, privacy: .private) verdict=\(Self.label(verdict), privacy: .private) ms=\(Self.ms(elapsed), privacy: .private)")
        case .repairScheduled(let id, let attempt, let diag):
            logger.info("repair.scheduled run=\(id.uuidString, privacy: .private) attempt=\(attempt, privacy: .private) why=\(diag.summary, privacy: .private)")
        case .budgetExhausted(let id, let kind):
            logger.notice("budget.exhausted run=\(id.uuidString, privacy: .private) kind=\(kind.rawValue, privacy: .private)")
        case .escalation(let id, let reason):
            logger.notice("escalation run=\(id.uuidString, privacy: .private) reason=\(reason, privacy: .private)")
        case .info(let id, let category, let message):
            logger.info("info run=\(id.uuidString, privacy: .private) cat=\(category, privacy: .private) msg=\(message, privacy: .private)")
        case .unknown(let id, let label, let payload):
            logger.info("trace.unknown run=\(id.uuidString, privacy: .private) label=\(label, privacy: .private) keys=\(payload.keys.sorted().joined(separator: ","), privacy: .private)")
        }
    }

    private static func ms(_ d: Duration) -> Int {
        let comps = d.components
        return Int(comps.seconds * 1000 + comps.attoseconds / 1_000_000_000_000_000)
    }

    private static func label(_ v: Verdict) -> String {
        switch v {
        case .pass: return "pass"
        case .repair: return "repair"
        case .reject: return "reject"
        case .escalate: return "escalate"
        }
    }
}

/// The run, written down one line at a time, in a format you can read
/// without our help. Appends one JSON object per event to a file. Errors
/// during write are logged at `.error` via `os.Logger` and otherwise
/// swallowed (the ``Tracer`` protocol is non-throwing). A configurable
/// ``FlushPolicy`` controls when the underlying file handle is
/// synchronized to disk — durability is a choice you make, not one we
/// make for you.
///
/// Single-writer requirement: this type owns the file handle for its
/// lifetime. Pointing two instances at the same URL interleaves writes
/// unpredictably — use one tracer per file.
public actor JSONLTracer: Tracer {
    /// The bargain between speed and certainty, struck on your terms: when
    /// the file handle is synchronized to disk.
    public enum FlushPolicy: Sendable, Equatable {
        /// Never call `fsync`; rely on the OS to flush.
        case never
        /// Flush after every event (slowest, most durable).
        case everyEvent
        /// Flush every `N` events.
        case everyN(Int)
    }

    private let url: URL
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private let flushPolicy: FlushPolicy
    private let logger = Logger(subsystem: "com.antisynthesis.compound", category: "jsonltracer")
    private var writesSinceFlush: Int = 0

    /// Opens the file for append (creating it if missing) and seeks to
    /// the end.
    ///
    /// - Throws: Any error from `FileHandle(forWritingTo:)`.
    public init(fileURL: URL, flushPolicy: FlushPolicy = .never) throws {
        self.url = fileURL
        self.flushPolicy = flushPolicy
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: fileURL)
        try self.handle.seekToEnd()
    }

    public func record(_ event: TraceEvent) async {
        let payload = JSONLRecord(from: event)
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            logger.error("jsonl.encode_failed label=\(event.label, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        var line = data
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
        } catch {
            logger.error("jsonl.write_failed label=\(event.label, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        writesSinceFlush += 1
        if shouldFlush() {
            try? handle.synchronize()
            writesSinceFlush = 0
        }
    }

    /// Forces a `fsync` of the underlying handle and resets the
    /// since-flush counter.
    public func flush() {
        try? handle.synchronize()
        writesSinceFlush = 0
    }

    /// Synchronizes and closes the handle. Subsequent writes will fail.
    public func close() throws {
        try? handle.synchronize()
        try handle.close()
    }

    private func shouldFlush() -> Bool {
        switch flushPolicy {
        case .never: return false
        case .everyEvent: return true
        case .everyN(let n): return n > 0 && writesSinceFlush >= n
        }
    }
}

private struct JSONLRecord: Encodable {
    let label: String
    let runID: String
    let timestamp: Date
    let payload: [String: String]

    init(from event: TraceEvent) {
        self.label = event.label
        self.runID = event.runID.uuidString
        self.timestamp = Date()
        self.payload = JSONLRecord.payload(for: event)
    }

    static func payload(for event: TraceEvent) -> [String: String] {
        switch event {
        case .runStarted(_, let p, _, let auth):
            return ["prompt_bytes": String(p.utf8.count), "auth": auth]
        case .runEnded(_, let ok, let usage):
            return ["ok": String(ok), "turns": String(usage.turns), "tools": String(usage.toolCalls), "repairs": String(usage.repairAttempts)]
        case .modelInvocationStarted(_, let turn, let bytes):
            return ["turn": String(turn), "prompt_bytes": String(bytes)]
        case .modelInvocationCompleted(_, let turn, let bytes, let elapsed):
            return ["turn": String(turn), "output_bytes": String(bytes), "elapsed_ms": String(JSONLRecord.ms(elapsed))]
        case .modelInvocationFailed(_, let turn, let reason):
            return ["turn": String(turn), "reason": reason]
        case .toolInvocationRequested(_, let tool):
            return ["tool": tool]
        case .toolInvocationCompleted(_, let tool, let elapsed, let ok):
            return ["tool": tool, "ok": String(ok), "elapsed_ms": String(JSONLRecord.ms(elapsed))]
        case .toolPolicyDenied(_, let tool, let reason):
            return ["tool": tool, "reason": reason]
        case .verifierEvaluated(_, let v, let cost, let verdict, let elapsed):
            return ["verifier": v, "cost": String(cost.rawValue), "verdict": JSONLRecord.verdictLabel(verdict), "elapsed_ms": String(JSONLRecord.ms(elapsed))]
        case .repairScheduled(_, let attempt, let diag):
            return ["attempt": String(attempt), "why": diag.summary]
        case .budgetExhausted(_, let kind):
            return ["kind": kind.rawValue]
        case .escalation(_, let reason):
            return ["reason": reason]
        case .info(_, let category, let message):
            return ["category": category, "message": message]
        case .unknown(_, _, let payload):
            return payload
        }
    }

    static func ms(_ d: Duration) -> Int {
        let comps = d.components
        return Int(comps.seconds * 1000 + comps.attoseconds / 1_000_000_000_000_000)
    }

    static func verdictLabel(_ v: Verdict) -> String {
        switch v {
        case .pass: return "pass"
        case .repair(let d): return "repair:\(d.verifier)"
        case .reject(let d): return "reject:\(d.message)"
        case .escalate(let d): return "escalate:\(d.message)"
        }
    }
}
