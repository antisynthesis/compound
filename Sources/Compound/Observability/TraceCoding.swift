import Foundation

/// Wire format for ``TraceEvent`` and ``TraceRecord``.
///
/// The encoding is hand-written rather than synthesized for three
/// reasons: a stable string discriminator (`type`) that matches
/// ``TraceEvent/label`` keeps exported traces greppable and lets a reader
/// route *unknown* future events into ``TraceEvent/unknown(runID:label:payload:)``
/// instead of failing the line; durations land as whole nanoseconds
/// instead of `Duration`'s opaque high/low pair; and every key is a plain
/// identifier, which is what lets ``RedactingTracer`` scrub the encoded
/// form structurally without mangling the structure.
///
/// Format contract:
/// - Every object carries `type` (case discriminator) and `run` (UUID).
/// - ``TraceRecord`` adds `ts`, epoch seconds as a `Double`.
/// - Payload keys are per-case and documented by ``TraceEvent/CodingKeys``.
/// - An unrecognized `type` decodes as `.unknown`, preserving the label
///   and any string-ish fields, so an older build can still read a newer
///   build's trace.
enum TraceCoding {
    /// Every key the trace format uses structurally — that is, keys whose
    /// *spelling* is part of the schema and must survive redaction, as
    /// opposed to free-form dictionary keys supplied by a caller.
    ///
    /// Assembled from the `CodingKeys` of every type that appears in the
    /// encoded form so a newly added key cannot be forgotten here.
    static let structuralKeys: Set<String> = {
        var keys = Set(TraceEvent.CodingKeys.allCases.map(\.rawValue))
        keys.formUnion(TraceRecord.CodingKeys.allCases.map(\.rawValue))
        keys.formUnion(Budget.CodingKeys.allCases.map(\.rawValue))
        keys.formUnion(BudgetUsage.CodingKeys.allCases.map(\.rawValue))
        keys.formUnion(Verdict.CodingKeys.allCases.map(\.rawValue))
        keys.formUnion(Diagnostic.CodingKeys.allCases.map(\.rawValue))
        keys.formUnion(SourceRange.CodingKeys.allCases.map(\.rawValue))
        return keys
    }()

    /// Keys whose *values* are load-bearing identifiers rather than
    /// free-form text: case discriminators, the run UUID, the budget
    /// dimension name, the timestamp. Rewriting these would either break
    /// decoding or destroy run correlation, and none of them can carry
    /// user content.
    /// (``signal``, ``from``, ``to``, and ``mode`` join them: they are
    /// enum raw values, so rewriting one makes the event undecodable.)
    static let preservedValueKeys: Set<String> = [
        "type", "run", "kind", "ts", "signal", "from", "to", "mode"
    ]

    /// Keys whose value is a caller-populated dictionary. Everything
    /// inside — keys included — is free-form text and is scrubbed.
    static let freeFormContainerKeys: Set<String> = ["payload"]
}

// MARK: - TraceEvent Codable

extension TraceEvent {
    /// Wire keys for the trace format. `CaseIterable` so
    /// ``TraceCoding/structuralKeys`` stays complete as cases are added.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case run
        case prompt
        case budget
        case auth
        case success
        case usage
        case turn
        case promptBytes = "prompt_bytes"
        case outputBytes = "output_bytes"
        case elapsed = "elapsed_ns"
        case reason
        case tool
        case diagnostic
        case verifier
        case cost
        case verdict
        case attempt
        case candidates
        case scores
        case agreement
        case selected
        case signal
        case from
        case to
        case failures
        case mode
        case step
        case confidence
        case round
        case query
        case retrieved
        case newSources = "new_sources"
        case rounds
        case sources
        case kind
        case category
        case message
        case label
        case payload
    }

    /// Case discriminator written to `type`. Identical to ``label`` for
    /// every in-tree case; ``unknown(runID:label:payload:)`` encodes as
    /// `"unknown"` and carries its dynamic label in the `label` field, so
    /// a forwarded future event never impersonates a real case.
    public var wireType: String {
        if case .unknown = self { return "unknown" }
        return label
    }

    /// Label used for the placeholder event a ``RedactingTracer`` emits
    /// when an event cannot be scrubbed and is therefore withheld.
    public static let redactionFailedLabel = "trace.redaction_failed"

    /// Encodes the full event — no field is summarized or dropped.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireType, forKey: .type)
        try container.encode(runID, forKey: .run)
        switch self {
        case .runStarted(_, let prompt, let budget, let auth):
            try container.encode(prompt, forKey: .prompt)
            try container.encode(budget, forKey: .budget)
            try container.encode(auth, forKey: .auth)
        case .runEnded(_, let success, let usage):
            try container.encode(success, forKey: .success)
            try container.encode(usage, forKey: .usage)
        case .modelInvocationStarted(_, let turn, let promptBytes):
            try container.encode(turn, forKey: .turn)
            try container.encode(promptBytes, forKey: .promptBytes)
        case .modelInvocationCompleted(_, let turn, let outputBytes, let elapsed):
            try container.encode(turn, forKey: .turn)
            try container.encode(outputBytes, forKey: .outputBytes)
            try container.encode(DurationCoding.nanoseconds(elapsed), forKey: .elapsed)
        case .modelInvocationFailed(_, let turn, let reason):
            try container.encode(turn, forKey: .turn)
            try container.encode(reason, forKey: .reason)
        case .toolInvocationRequested(_, let tool):
            try container.encode(tool, forKey: .tool)
        case .toolInvocationCompleted(_, let tool, let elapsed, let succeeded):
            try container.encode(tool, forKey: .tool)
            try container.encode(DurationCoding.nanoseconds(elapsed), forKey: .elapsed)
            try container.encode(succeeded, forKey: .success)
        case .toolPolicyDenied(_, let tool, let reason):
            try container.encode(tool, forKey: .tool)
            try container.encode(reason, forKey: .reason)
        case .toolArgumentRejected(_, let tool, let diagnostic),
             .toolOutputRejected(_, let tool, let diagnostic):
            try container.encode(tool, forKey: .tool)
            try container.encode(diagnostic, forKey: .diagnostic)
        case .verifierEvaluated(_, let verifier, let cost, let verdict, let elapsed):
            try container.encode(verifier, forKey: .verifier)
            try container.encode(cost, forKey: .cost)
            try container.encode(verdict, forKey: .verdict)
            try container.encode(DurationCoding.nanoseconds(elapsed), forKey: .elapsed)
        case .bestOfNSampled(_, let candidates, let scores, let agreement, let selectedIndex):
            try container.encode(candidates, forKey: .candidates)
            try container.encode(scores, forKey: .scores)
            try container.encodeIfPresent(agreement, forKey: .agreement)
            try container.encode(selectedIndex, forKey: .selected)
        case .breakerTransitioned(_, let signal, let from, let to, let failures):
            try container.encode(signal, forKey: .signal)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
            try container.encode(failures, forKey: .failures)
        case .degradationApplied(_, let mode, let reason):
            try container.encode(mode, forKey: .mode)
            try container.encode(reason, forKey: .reason)
        case .routingEscalated(_, let step, let confidence, let attempt):
            try container.encode(step, forKey: .step)
            try container.encodeIfPresent(confidence, forKey: .confidence)
            try container.encode(attempt, forKey: .attempt)
        case .retrievalRound(_, let round, let query, let retrieved, let newSources, let verdict):
            try container.encode(round, forKey: .round)
            try container.encode(query, forKey: .query)
            try container.encode(retrieved, forKey: .retrieved)
            try container.encode(newSources, forKey: .newSources)
            try container.encode(verdict, forKey: .verdict)
        case .retrievalLoopEnded(_, let rounds, let sources, let reason):
            try container.encode(rounds, forKey: .rounds)
            try container.encode(sources, forKey: .sources)
            try container.encode(reason, forKey: .reason)
        case .repairScheduled(_, let attempt, let diagnostic):
            try container.encode(attempt, forKey: .attempt)
            try container.encode(diagnostic, forKey: .diagnostic)
        case .budgetExhausted(_, let kind):
            try container.encode(kind, forKey: .kind)
        case .escalation(_, let reason):
            try container.encode(reason, forKey: .reason)
        case .info(_, let category, let message):
            try container.encode(category, forKey: .category)
            try container.encode(message, forKey: .message)
        case .unknown(_, let label, let payload):
            try container.encode(label, forKey: .label)
            try container.encode(payload, forKey: .payload)
        }
    }

    /// Decodes an event written by ``encode(to:)``.
    ///
    /// An unrecognized `type` is *not* an error: it decodes as
    /// ``unknown(runID:label:payload:)`` with the unknown discriminator as
    /// the label and every scalar field flattened into the payload, so a
    /// consumer built against an older Compound can still reconstruct the
    /// shape of a newer run. Malformed lines — bad JSON, missing `type`,
    /// wrong field types — still throw, and ``TraceReader`` counts them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let run = try container.decode(UUID.self, forKey: .run)
        func elapsed() throws -> Duration {
            DurationCoding.duration(nanoseconds: try container.decode(Int64.self, forKey: .elapsed))
        }
        switch type {
        case "run.started":
            self = .runStarted(
                runID: run,
                prompt: try container.decode(String.self, forKey: .prompt),
                budget: try container.decode(Budget.self, forKey: .budget),
                auth: try container.decode(String.self, forKey: .auth)
            )
        case "run.ended":
            self = .runEnded(
                runID: run,
                success: try container.decode(Bool.self, forKey: .success),
                usage: try container.decode(BudgetUsage.self, forKey: .usage)
            )
        case "model.started":
            self = .modelInvocationStarted(
                runID: run,
                turn: try container.decode(Int.self, forKey: .turn),
                promptBytes: try container.decode(Int.self, forKey: .promptBytes)
            )
        case "model.completed":
            self = .modelInvocationCompleted(
                runID: run,
                turn: try container.decode(Int.self, forKey: .turn),
                outputBytes: try container.decode(Int.self, forKey: .outputBytes),
                elapsed: try elapsed()
            )
        case "model.failed":
            self = .modelInvocationFailed(
                runID: run,
                turn: try container.decode(Int.self, forKey: .turn),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case "tool.requested":
            self = .toolInvocationRequested(runID: run, tool: try container.decode(String.self, forKey: .tool))
        case "tool.completed":
            self = .toolInvocationCompleted(
                runID: run,
                tool: try container.decode(String.self, forKey: .tool),
                elapsed: try elapsed(),
                succeeded: try container.decode(Bool.self, forKey: .success)
            )
        case "tool.denied":
            self = .toolPolicyDenied(
                runID: run,
                tool: try container.decode(String.self, forKey: .tool),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case "tool.argument.rejected":
            self = .toolArgumentRejected(
                runID: run,
                tool: try container.decode(String.self, forKey: .tool),
                diagnostic: try container.decode(Diagnostic.self, forKey: .diagnostic)
            )
        case "tool.output.rejected":
            self = .toolOutputRejected(
                runID: run,
                tool: try container.decode(String.self, forKey: .tool),
                diagnostic: try container.decode(Diagnostic.self, forKey: .diagnostic)
            )
        case "verifier.evaluated":
            self = .verifierEvaluated(
                runID: run,
                verifier: try container.decode(String.self, forKey: .verifier),
                cost: try container.decode(VerifierCost.self, forKey: .cost),
                verdict: try container.decode(Verdict.self, forKey: .verdict),
                elapsed: try elapsed()
            )
        case "sampling.best_of_n":
            self = .bestOfNSampled(
                runID: run,
                candidates: try container.decode(Int.self, forKey: .candidates),
                scores: try container.decode([Double].self, forKey: .scores),
                agreement: try container.decodeIfPresent(Double.self, forKey: .agreement),
                selectedIndex: try container.decode(Int.self, forKey: .selected)
            )
        case "health.breaker":
            self = .breakerTransitioned(
                runID: run,
                signal: try container.decode(DegradationSignal.self, forKey: .signal),
                from: try container.decode(BreakerState.self, forKey: .from),
                to: try container.decode(BreakerState.self, forKey: .to),
                failures: try container.decode(Int.self, forKey: .failures)
            )
        case "health.degraded":
            self = .degradationApplied(
                runID: run,
                mode: try container.decode(DegradedMode.self, forKey: .mode),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case "routing.escalated":
            self = .routingEscalated(
                runID: run,
                step: try container.decode(String.self, forKey: .step),
                confidence: try container.decodeIfPresent(Double.self, forKey: .confidence),
                attempt: try container.decode(Int.self, forKey: .attempt)
            )
        case "retrieval.round":
            self = .retrievalRound(
                runID: run,
                round: try container.decode(Int.self, forKey: .round),
                query: try container.decode(String.self, forKey: .query),
                retrieved: try container.decode(Int.self, forKey: .retrieved),
                newSources: try container.decode(Int.self, forKey: .newSources),
                verdict: try container.decode(String.self, forKey: .verdict)
            )
        case "retrieval.loop_ended":
            self = .retrievalLoopEnded(
                runID: run,
                rounds: try container.decode(Int.self, forKey: .rounds),
                sources: try container.decode(Int.self, forKey: .sources),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case "repair.scheduled":
            self = .repairScheduled(
                runID: run,
                attempt: try container.decode(Int.self, forKey: .attempt),
                diagnostic: try container.decode(Diagnostic.self, forKey: .diagnostic)
            )
        case "budget.exhausted":
            self = .budgetExhausted(runID: run, kind: try container.decode(BudgetExhaustion.self, forKey: .kind))
        case "escalation":
            self = .escalation(runID: run, reason: try container.decode(String.self, forKey: .reason))
        case "info":
            self = .info(
                runID: run,
                category: try container.decode(String.self, forKey: .category),
                message: try container.decode(String.self, forKey: .message)
            )
        case "unknown":
            self = .unknown(
                runID: run,
                label: try container.decodeIfPresent(String.self, forKey: .label) ?? "unknown",
                payload: try container.decodeIfPresent([String: String].self, forKey: .payload) ?? [:]
            )
        default:
            self = .unknown(
                runID: run,
                label: type,
                payload: try TraceEvent.flattenedPayload(from: decoder)
            )
        }
    }

    /// Best-effort flattening of an unrecognized event's scalar fields
    /// into `[String: String]` so nothing observable is silently dropped
    /// when an older consumer reads a newer trace. Nested objects and
    /// arrays are skipped — the label plus the scalars is enough to see
    /// what happened.
    private static func flattenedPayload(from decoder: any Decoder) throws -> [String: String] {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var payload: [String: String] = [:]
        for key in container.allKeys where !TraceCoding.preservedValueKeys.contains(key.stringValue) {
            if let text = try? container.decode(String.self, forKey: key) {
                payload[key.stringValue] = text
            } else if let number = try? container.decode(Int.self, forKey: key) {
                payload[key.stringValue] = String(number)
            } else if let flag = try? container.decode(Bool.self, forKey: key) {
                payload[key.stringValue] = String(flag)
            } else if let number = try? container.decode(Double.self, forKey: key) {
                payload[key.stringValue] = String(number)
            }
        }
        return payload
    }
}

/// Coding key that accepts any string, used to sweep the fields of an
/// event whose `type` this build does not recognize.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - TraceRecord

/// A ``TraceEvent`` stamped with the wall-clock instant it was recorded.
///
/// ``TraceEvent`` itself is a pure enum whose cases are pattern-matched
/// throughout the framework, so the timestamp lives on this wrapper
/// rather than as an associated value repeated across every case (which
/// would break every existing `case .runEnded(_, let ok, _)` match in the
/// framework and in adopter code). Tracers
/// stamp at emission (``InMemoryTracer`` and ``JSONLTracer`` both do),
/// which makes a persisted trace a genuine timeline: sortable, joinable
/// across sinks, and sufficient to reconstruct a run.
public struct TraceRecord: Sendable, Equatable, Codable {
    /// When the event was recorded.
    public var timestamp: Date
    /// The event itself, losslessly preserved.
    public var event: TraceEvent

    /// Stamps `event`, defaulting to now.
    public init(event: TraceEvent, timestamp: Date = Date()) {
        self.event = event
        self.timestamp = timestamp
    }

    /// Run the event belongs to.
    public var runID: UUID { event.runID }
    /// Stable dot-separated label of the event.
    public var label: String { event.label }

    /// Timestamp key. The event's own keys are merged into the same
    /// object so a JSONL line stays flat and `jq`-friendly.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case ts
    }

    /// Encodes the event's fields plus `ts` (epoch seconds).
    public func encode(to encoder: any Encoder) throws {
        try event.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp.timeIntervalSince1970, forKey: .ts)
    }

    /// Decodes a stamped record. A line without `ts` is treated as
    /// corrupt — a record with a fabricated timestamp is worse than a
    /// skipped line for reconstruction.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestamp = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .ts))
        self.event = try TraceEvent(from: decoder)
    }
}
