import Foundation

/// Wraps another ``Tracer`` and applies a chain of ``Redactor`` rules to
/// every string-valued field on each ``TraceEvent`` before forwarding to
/// the inner tracer. The symmetric counterpart to running redactors on
/// model-bound prompts: anything that goes back out through the trace
/// pipe (OSLog, JSONL on disk, a remote sink) gets the same scrubbing.
///
/// Numeric fields (counts, durations, byte sizes) and identifiers
/// (UUIDs, ``VerifierCost`` raw values, ``BudgetExhaustion`` raw values)
/// are passed through unchanged — they have no plausible secret content
/// and redaction would only obscure telemetry.
public struct RedactingTracer: Tracer {
    private let inner: any Tracer
    private let redactors: [any Redactor]

    /// Wraps `inner` and applies `redactors` in order.
    public init(inner: any Tracer, redactors: [any Redactor]) {
        self.inner = inner
        self.redactors = redactors
    }

    /// Scrubs string fields in `event` and forwards to the inner tracer.
    public func record(_ event: TraceEvent) async {
        await inner.record(redact(event))
    }

    private func scrub(_ s: String) -> String {
        redactors.reduce(s) { acc, r in r.redact(acc) }
    }

    private func redact(_ event: TraceEvent) -> TraceEvent {
        switch event {
        case .runStarted(let id, let prompt, let budget, let auth):
            return .runStarted(runID: id, prompt: scrub(prompt), budget: budget, auth: scrub(auth))
        case .runEnded:
            return event
        case .modelInvocationStarted:
            return event
        case .modelInvocationCompleted:
            return event
        case .modelInvocationFailed(let id, let turn, let reason):
            return .modelInvocationFailed(runID: id, turn: turn, reason: scrub(reason))
        case .toolInvocationRequested(let id, let tool):
            return .toolInvocationRequested(runID: id, tool: scrub(tool))
        case .toolInvocationCompleted(let id, let tool, let elapsed, let ok):
            return .toolInvocationCompleted(runID: id, tool: scrub(tool), elapsed: elapsed, succeeded: ok)
        case .toolPolicyDenied(let id, let tool, let reason):
            return .toolPolicyDenied(runID: id, tool: scrub(tool), reason: scrub(reason))
        case .verifierEvaluated(let id, let v, let cost, let verdict, let elapsed):
            return .verifierEvaluated(runID: id, verifier: scrub(v), cost: cost, verdict: redact(verdict), elapsed: elapsed)
        case .repairScheduled(let id, let attempt, let diag):
            return .repairScheduled(runID: id, attempt: attempt, diagnostic: redact(diag))
        case .budgetExhausted:
            return event
        case .escalation(let id, let reason):
            return .escalation(runID: id, reason: scrub(reason))
        case .info(let id, let category, let message):
            return .info(runID: id, category: scrub(category), message: scrub(message))
        case .unknown(let id, let label, let payload):
            var out: [String: String] = [:]
            out.reserveCapacity(payload.count)
            for (k, v) in payload { out[k] = scrub(v) }
            return .unknown(runID: id, label: label, payload: out)
        }
    }

    private func redact(_ verdict: Verdict) -> Verdict {
        switch verdict {
        case .pass: return .pass
        case .repair(let d): return .repair(redact(d))
        case .reject(let d): return .reject(redact(d))
        case .escalate(let d): return .escalate(redact(d))
        }
    }

    private func redact(_ d: Diagnostic) -> Diagnostic {
        Diagnostic(
            verifier: scrub(d.verifier),
            message: scrub(d.message),
            suggestion: d.suggestion.map(scrub),
            location: d.location
        )
    }
}
