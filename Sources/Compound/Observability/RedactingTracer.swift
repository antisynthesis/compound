import Foundation

/// Wraps another ``Tracer`` and applies a chain of ``Redactor`` rules to
/// every string in every ``TraceEvent`` before forwarding it. The
/// symmetric counterpart to running redactors on model-bound prompts:
/// anything that goes back out through the trace pipe (OSLog, JSONL on
/// disk, a remote sink) gets the same scrubbing.
///
/// Redaction is **structural, not case-enumerated**. The event is encoded
/// through its ``Codable`` conformance, every string in the resulting
/// tree is scrubbed, and the tree is decoded back into a `TraceEvent`.
/// Nothing here switches over the enum, so a case added to ``TraceEvent``
/// tomorrow is covered the day it lands — the old design enumerated cases
/// and leaked by omission the moment someone forgot an arm.
///
/// Two categories of value are passed through untouched:
/// - **Numbers, booleans, and durations** (counts, byte sizes, elapsed
///   times) have no plausible secret content and redacting them would
///   only destroy telemetry.
/// - **Load-bearing identifiers** — the case discriminator, the run UUID,
///   the budget-dimension name, the timestamp — because rewriting them
///   would break decoding or run correlation, and none can carry user
///   content. Every other string, including dictionary keys inside
///   caller-supplied payloads, is scrubbed.
///
/// If an event cannot be encoded, scrubbed, and decoded cleanly, the
/// tracer **fails closed**: the original event is withheld and a
/// payload-free placeholder labeled
/// ``TraceEvent/redactionFailedLabel`` is forwarded in its place, so the
/// gap is visible in the trace without leaking what could not be
/// scrubbed.
public struct RedactingTracer: Tracer {
    private let inner: any Tracer
    private let redactors: [any Redactor]

    /// Wraps `inner` and applies `redactors` in order.
    public init(inner: any Tracer, redactors: [any Redactor]) {
        self.inner = inner
        self.redactors = redactors
    }

    /// Scrubs `event` and forwards the result to the inner tracer.
    public func record(_ event: TraceEvent) async {
        await inner.record(redact(event))
    }

    /// Returns `event` with every free-form string scrubbed by the
    /// redactor chain, or the fail-closed placeholder if the round-trip
    /// through the wire format does not survive.
    func redact(_ event: TraceEvent) -> TraceEvent {
        guard !redactors.isEmpty else { return event }
        do {
            let encoded = try JSONEncoder().encode(event)
            let tree = try JSONSerialization.jsonObject(with: encoded, options: [])
            let scrubbed = scrub(tree, freeForm: false)
            let reencoded = try JSONSerialization.data(withJSONObject: scrubbed, options: [])
            return try JSONDecoder().decode(TraceEvent.self, from: reencoded)
        } catch {
            return .unknown(runID: event.runID, label: TraceEvent.redactionFailedLabel, payload: [:])
        }
    }

    private func scrub(_ value: Any, freeForm: Bool) -> Any {
        switch value {
        case let object as [String: Any]:
            var out: [String: Any] = [:]
            out.reserveCapacity(object.count)
            for (key, member) in object {
                if !freeForm, TraceCoding.preservedValueKeys.contains(key) {
                    out[key] = member
                    continue
                }
                // Structural keys are schema, not content: rewriting them
                // would make the event undecodable. Free-form keys (and
                // every key inside a caller-supplied payload) are content.
                let scrubbedKey = !freeForm && TraceCoding.structuralKeys.contains(key) ? key : scrub(string: key)
                let nested = freeForm || TraceCoding.freeFormContainerKeys.contains(key)
                out[scrubbedKey] = scrub(member, freeForm: nested)
            }
            return out
        case let array as [Any]:
            return array.map { scrub($0, freeForm: freeForm) }
        case let text as String:
            return scrub(string: text)
        default:
            return value
        }
    }

    private func scrub(string: String) -> String {
        redactors.reduce(string) { accumulated, redactor in redactor.redact(accumulated) }
    }
}
