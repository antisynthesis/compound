import Foundation
import os

/// Sink for structured ``TraceEvent`` values. Implementations should be
/// non-blocking and idempotent. The control loop emits trace events on
/// the critical path and never awaits a response from the tracer beyond
/// the actor hop.
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

/// No-op ``Tracer``; the default in ``RunContext``.
public struct NullTracer: Tracer {
    /// Creates an instance.
    public init() {}
    /// Drops the event.
    public func record(_: TraceEvent) async {}
}

/// Bounded in-memory tracer. Stores up to ``capacity`` events in FIFO
/// order; oldest events are dropped once the cap is exceeded. Every event
/// is stamped at emission, so ``records`` is a timeline and not just a
/// bag of events.
public actor InMemoryTracer: Tracer {
    /// Stamped events captured so far, oldest first.
    private(set) public var records: [TraceRecord] = []
    /// Maximum number of events retained before FIFO eviction kicks in.
    public let capacity: Int

    /// Creates a tracer with the supplied ring-buffer capacity.
    public init(capacity: Int = 1024) {
        self.capacity = capacity
    }

    /// Events captured so far, timestamps stripped.
    public var events: [TraceEvent] { records.map(\.event) }

    /// Stamps and appends `event`, trimming excess from the front.
    public func record(_ event: TraceEvent) {
        records.append(TraceRecord(event: event))
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }

    /// Returns a copy of the recorded events.
    public func snapshot() -> [TraceEvent] {
        events
    }

    /// Returns a copy of the recorded events with their timestamps.
    public func recordSnapshot() -> [TraceRecord] {
        records
    }

    /// Discards all recorded events while keeping capacity.
    public func clear() {
        records.removeAll(keepingCapacity: true)
    }

    /// Returns the events scoped to a single `runID`.
    public func events(for runID: UUID) -> [TraceEvent] {
        records.filter { $0.runID == runID }.map(\.event)
    }

    /// Returns the stamped records scoped to a single `runID`.
    public func records(for runID: UUID) -> [TraceRecord] {
        records.filter { $0.runID == runID }
    }
}

/// Apple `os.Logger`-backed tracer with configurable privacy markings.
/// Default ``PrivacyLevel/balanced`` keeps stable identifiers public
/// (run IDs, counts, verifier names) while routing free-form text to
/// `.private` so log archives do not leak embedded secrets or PII.
public struct OSLogTracer: Tracer {
    /// Controls how strongly `TraceEvent` fields are redacted when
    /// emitted to OSLog.
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
        case .toolArgumentRejected(let id, let tool, let diag):
            logger.notice("tool.argument.rejected run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public) why=\(diag.summary, privacy: .public)")
        case .toolOutputRejected(let id, let tool, let diag):
            logger.notice("tool.output.rejected run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public) why=\(diag.summary, privacy: .public)")
        case .verifierEvaluated(let id, let v, let cost, let verdict, let elapsed):
            logger.debug("verifier.evaluated run=\(id.uuidString, privacy: .public) v=\(v, privacy: .public) cost=\(cost.rawValue, privacy: .public) verdict=\(Self.label(verdict), privacy: .public) ms=\(Self.ms(elapsed), privacy: .public)")
        case .bestOfNSampled(let id, let candidates, _, let agreement, let selectedIndex):
            logger.info("sampling.best_of_n run=\(id.uuidString, privacy: .public) n=\(candidates, privacy: .public) selected=\(selectedIndex, privacy: .public) agreement=\(Self.ratio(agreement), privacy: .public)")
        case .breakerTransitioned(let id, let signal, let from, let to, let failures):
            logger.notice("health.breaker run=\(id.uuidString, privacy: .public) signal=\(signal.rawValue, privacy: .public) from=\(from.rawValue, privacy: .public) to=\(to.rawValue, privacy: .public) failures=\(failures, privacy: .public)")
        case .degradationApplied(let id, let mode, let reason):
            logger.notice("health.degraded run=\(id.uuidString, privacy: .public) mode=\(mode.rawValue, privacy: .public) why=\(reason, privacy: .public)")
        case .routingEscalated(let id, let step, let confidence, let attempt):
            logger.info("routing.escalated run=\(id.uuidString, privacy: .public) step=\(step, privacy: .public) attempt=\(attempt, privacy: .public) confidence=\(Self.ratio(confidence), privacy: .public)")
        case .retrievalRound(let id, let round, let query, let retrieved, let new, let verdict):
            logger.debug("retrieval.round run=\(id.uuidString, privacy: .public) round=\(round, privacy: .public) retrieved=\(retrieved, privacy: .public) new=\(new, privacy: .public) verdict=\(verdict, privacy: .public) query=\(query, privacy: .public)")
        case .retrievalLoopEnded(let id, let rounds, let sources, let reason):
            logger.info("retrieval.loop_ended run=\(id.uuidString, privacy: .public) rounds=\(rounds, privacy: .public) sources=\(sources, privacy: .public) reason=\(reason, privacy: .public)")
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
        case .toolArgumentRejected(let id, let tool, let diag):
            if toolNamesArePublic {
                logger.notice("tool.argument.rejected run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public) why=\(diag.summary, privacy: .private)")
            } else {
                logger.notice("tool.argument.rejected run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .private) why=\(diag.summary, privacy: .private)")
            }
        case .toolOutputRejected(let id, let tool, let diag):
            if toolNamesArePublic {
                logger.notice("tool.output.rejected run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .public) why=\(diag.summary, privacy: .private)")
            } else {
                logger.notice("tool.output.rejected run=\(id.uuidString, privacy: .public) tool=\(tool, privacy: .private) why=\(diag.summary, privacy: .private)")
            }
        case .verifierEvaluated(let id, let v, let cost, let verdict, let elapsed):
            logger.debug("verifier.evaluated run=\(id.uuidString, privacy: .public) v=\(v, privacy: .public) cost=\(cost.rawValue, privacy: .public) verdict=\(Self.label(verdict), privacy: .public) ms=\(Self.ms(elapsed), privacy: .public)")
        case .bestOfNSampled(let id, let candidates, _, let agreement, let selectedIndex):
            logger.info("sampling.best_of_n run=\(id.uuidString, privacy: .public) n=\(candidates, privacy: .public) selected=\(selectedIndex, privacy: .public) agreement=\(Self.ratio(agreement), privacy: .public)")
        case .breakerTransitioned(let id, let signal, let from, let to, let failures):
            logger.notice("health.breaker run=\(id.uuidString, privacy: .public) signal=\(signal.rawValue, privacy: .public) from=\(from.rawValue, privacy: .public) to=\(to.rawValue, privacy: .public) failures=\(failures, privacy: .public)")
        case .degradationApplied(let id, let mode, let reason):
            logger.notice("health.degraded run=\(id.uuidString, privacy: .public) mode=\(mode.rawValue, privacy: .public) why=\(reason, privacy: .private)")
        case .routingEscalated(let id, let step, let confidence, let attempt):
            logger.info("routing.escalated run=\(id.uuidString, privacy: .public) step=\(step, privacy: .private) attempt=\(attempt, privacy: .public) confidence=\(Self.ratio(confidence), privacy: .public)")
        case .retrievalRound(let id, let round, let query, let retrieved, let new, let verdict):
            logger.debug("retrieval.round run=\(id.uuidString, privacy: .public) round=\(round, privacy: .public) retrieved=\(retrieved, privacy: .public) new=\(new, privacy: .public) verdict=\(verdict, privacy: .public) query=\(query, privacy: .private)")
        case .retrievalLoopEnded(let id, let rounds, let sources, let reason):
            logger.info("retrieval.loop_ended run=\(id.uuidString, privacy: .public) rounds=\(rounds, privacy: .public) sources=\(sources, privacy: .public) reason=\(reason, privacy: .public)")
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
        case .toolArgumentRejected(let id, let tool, let diag):
            logger.notice("tool.argument.rejected run=\(id.uuidString, privacy: .private) tool=\(tool, privacy: .private) why=\(diag.summary, privacy: .private)")
        case .toolOutputRejected(let id, let tool, let diag):
            logger.notice("tool.output.rejected run=\(id.uuidString, privacy: .private) tool=\(tool, privacy: .private) why=\(diag.summary, privacy: .private)")
        case .verifierEvaluated(let id, let v, let cost, let verdict, let elapsed):
            logger.debug("verifier.evaluated run=\(id.uuidString, privacy: .private) v=\(v, privacy: .private) cost=\(cost.rawValue, privacy: .private) verdict=\(Self.label(verdict), privacy: .private) ms=\(Self.ms(elapsed), privacy: .private)")
        case .bestOfNSampled(let id, let candidates, _, let agreement, let selectedIndex):
            logger.info("sampling.best_of_n run=\(id.uuidString, privacy: .private) n=\(candidates, privacy: .private) selected=\(selectedIndex, privacy: .private) agreement=\(Self.ratio(agreement), privacy: .private)")
        case .breakerTransitioned(let id, let signal, let from, let to, let failures):
            logger.notice("health.breaker run=\(id.uuidString, privacy: .private) signal=\(signal.rawValue, privacy: .private) from=\(from.rawValue, privacy: .private) to=\(to.rawValue, privacy: .private) failures=\(failures, privacy: .private)")
        case .degradationApplied(let id, let mode, let reason):
            logger.notice("health.degraded run=\(id.uuidString, privacy: .private) mode=\(mode.rawValue, privacy: .private) why=\(reason, privacy: .private)")
        case .routingEscalated(let id, let step, let confidence, let attempt):
            logger.info("routing.escalated run=\(id.uuidString, privacy: .private) step=\(step, privacy: .private) attempt=\(attempt, privacy: .private) confidence=\(Self.ratio(confidence), privacy: .private)")
        case .retrievalRound(let id, let round, let query, let retrieved, let new, let verdict):
            logger.debug("retrieval.round run=\(id.uuidString, privacy: .private) round=\(round, privacy: .private) retrieved=\(retrieved, privacy: .private) new=\(new, privacy: .private) verdict=\(verdict, privacy: .private) query=\(query, privacy: .private)")
        case .retrievalLoopEnded(let id, let rounds, let sources, let reason):
            logger.info("retrieval.loop_ended run=\(id.uuidString, privacy: .private) rounds=\(rounds, privacy: .private) sources=\(sources, privacy: .private) reason=\(reason, privacy: .private)")
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

    /// Renders an optional ratio for a log line; `nil` (an undefined
    /// signal) is spelled out rather than fabricated as a number.
    private static func ratio(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "n/a"
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

/// Appends one JSON object per ``TraceRecord`` to a file — the full
/// event, losslessly, plus the wall-clock instant it was recorded — so
/// the file reads back through ``TraceReader`` into the same values that
/// went in. Errors during write are logged at `.error` via `os.Logger`
/// and otherwise swallowed (the ``Tracer`` protocol is non-throwing). A
/// configurable ``FlushPolicy`` controls when the underlying file handle
/// is synchronized to disk.
///
/// The file is size-bounded: once a write would push the current file
/// past ``maxFileBytes`` it is rotated to `<file>.1` (shifting older
/// generations up and discarding the oldest beyond ``maxFiles``), so a
/// long-lived on-device trace occupies at most `maxFileBytes * maxFiles`.
///
/// Single-writer requirement: this type owns the file handle for its
/// lifetime. Pointing two instances at the same URL interleaves writes
/// and rotations unpredictably — use one tracer per file.
///
/// # Example
/// ```swift
/// let tracer = try JSONLTracer(fileURL: url, flushPolicy: .everyN(16))
/// await tracer.record(.info(runID: id, category: "app", message: "ready"))
/// try await tracer.close()
/// let batch = try TraceReader.readRotated(baseURL: url)
/// ```
public actor JSONLTracer: Tracer {
    /// When the file handle is synchronized to disk.
    public enum FlushPolicy: Sendable, Equatable {
        /// Never call `fsync`; rely on the OS to flush.
        case never
        /// Flush after every event (slowest, most durable).
        case everyEvent
        /// Flush every `N` events.
        case everyN(Int)
    }

    /// Default rotation threshold: 8 MiB per file.
    public static let defaultMaxFileBytes = 8 * 1024 * 1024
    /// Default number of retained generations, current file included.
    public static let defaultMaxFiles = 4

    private let url: URL
    private var handle: FileHandle?
    private let encoder: JSONEncoder
    private let flushPolicy: FlushPolicy
    private let logger = Logger(subsystem: "com.antisynthesis.compound", category: "jsonltracer")
    private var writesSinceFlush: Int = 0
    private var bytesWritten: Int = 0

    /// Rotation threshold in bytes for the current file.
    public let maxFileBytes: Int
    /// Retained generations, current file included. `1` disables archives
    /// (the file is truncated instead).
    public let maxFiles: Int

    /// Opens the file for append (creating it if missing) and seeks to
    /// the end.
    ///
    /// - Parameters:
    ///   - fileURL: File to append to; also the base name for rotated
    ///     generations (`fileURL` + `.1`, `.2`, …).
    ///   - flushPolicy: When to `fsync`.
    ///   - maxFileBytes: Rotate once a write would exceed this size.
    ///     Precondition-checked positive.
    ///   - maxFiles: Generations to retain, current file included.
    ///     Precondition-checked at least 1.
    /// - Throws: Any error from `FileHandle(forWritingTo:)`.
    public init(
        fileURL: URL,
        flushPolicy: FlushPolicy = .never,
        maxFileBytes: Int = JSONLTracer.defaultMaxFileBytes,
        maxFiles: Int = JSONLTracer.defaultMaxFiles
    ) throws {
        precondition(maxFileBytes > 0, "maxFileBytes must be positive")
        precondition(maxFiles >= 1, "maxFiles must be at least 1")
        self.url = fileURL
        self.flushPolicy = flushPolicy
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.withoutEscapingSlashes]
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        self.handle = handle
        // Appending to an existing file: start the size accounting from
        // what is already there so rotation triggers on total size.
        self.bytesWritten = Int(try handle.seekToEnd())
    }

    /// URL of a rotated generation of `base`: `base.1` is the most
    /// recent archive, higher numbers are older.
    public static func archiveURL(base: URL, generation: Int) -> URL {
        URL(fileURLWithPath: base.path + ".\(generation)")
    }

    /// Stamps `event` with the current time and appends it as one JSON
    /// line, rotating first if the line would overflow ``maxFileBytes``.
    public func record(_ event: TraceEvent) async {
        let data: Data
        do {
            data = try encoder.encode(TraceRecord(event: event))
        } catch {
            logger.error("jsonl.encode_failed label=\(event.label, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        var line = data
        line.append(0x0A)
        rotateIfNeeded(incoming: line.count)
        guard let handle else {
            logger.error("jsonl.write_dropped label=\(event.label, privacy: .public) reason=closed")
            return
        }
        do {
            try handle.write(contentsOf: line)
        } catch {
            logger.error("jsonl.write_failed label=\(event.label, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        bytesWritten += line.count
        writesSinceFlush += 1
        if shouldFlush() {
            try? handle.synchronize()
            writesSinceFlush = 0
        }
    }

    /// Forces a `fsync` of the underlying handle and resets the
    /// since-flush counter.
    public func flush() {
        try? handle?.synchronize()
        writesSinceFlush = 0
    }

    /// Synchronizes and closes the handle. Subsequent writes are dropped
    /// (and logged) rather than throwing.
    public func close() throws {
        guard let handle else { return }
        try? handle.synchronize()
        self.handle = nil
        try handle.close()
    }

    /// Current size of the active file, in bytes.
    public var currentFileBytes: Int { bytesWritten }

    private func shouldFlush() -> Bool {
        switch flushPolicy {
        case .never: return false
        case .everyEvent: return true
        case .everyN(let n): return n > 0 && writesSinceFlush >= n
        }
    }

    /// Rotates when the pending line would push the file past its cap.
    /// An empty file always accepts its line, so a single oversized event
    /// cannot spin the rotation forever.
    private func rotateIfNeeded(incoming: Int) {
        guard handle != nil, bytesWritten > 0, bytesWritten + incoming > maxFileBytes else { return }
        let fileManager = FileManager.default
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        if maxFiles > 1 {
            // Discard the oldest, then shift every surviving generation
            // one slot up before the current file becomes `.1`.
            try? fileManager.removeItem(at: Self.archiveURL(base: url, generation: maxFiles - 1))
            var generation = maxFiles - 2
            while generation >= 1 {
                let source = Self.archiveURL(base: url, generation: generation)
                if fileManager.fileExists(atPath: source.path) {
                    let destination = Self.archiveURL(base: url, generation: generation + 1)
                    try? fileManager.removeItem(at: destination)
                    try? fileManager.moveItem(at: source, to: destination)
                }
                generation -= 1
            }
            let firstArchive = Self.archiveURL(base: url, generation: 1)
            try? fileManager.removeItem(at: firstArchive)
            try? fileManager.moveItem(at: url, to: firstArchive)
        } else {
            try? fileManager.removeItem(at: url)
        }
        fileManager.createFile(atPath: url.path, contents: nil)
        do {
            let reopened = try FileHandle(forWritingTo: url)
            try reopened.seekToEnd()
            handle = reopened
            bytesWritten = 0
        } catch {
            // Fail quiet: tracing must never take the run down. Further
            // events are dropped until a new tracer is constructed.
            logger.error("jsonl.rotate_failed url=\(self.url.lastPathComponent, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }
}

