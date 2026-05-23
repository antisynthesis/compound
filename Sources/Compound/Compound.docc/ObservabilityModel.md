# Observability Model

How Compound separates structured tracing from live progress, where redaction sits, and the knobs you have for cost and forward compatibility.

## Overview

A system you cannot inspect is a system you cannot trust. Nothing happens off the books. Compound separates two observability surfaces. ``Tracer`` and ``TraceEvent`` capture the structured-log record of a run — every model call, every tool invocation, every verifier verdict, every control-loop decision — with enough fidelity to reconstruct what happened after the fact. ``ProgressReporter`` and ``ProgressEvent`` are the high-frequency, UI-facing signal a SwiftUI view binds to. Both surfaces run in parallel; neither replaces the other.

## Tracer composition

Tracers compose. ``CompositeTracer`` fans events out to its members in parallel via a `TaskGroup`, so adding another sink does not serialize the existing ones. The shipped tracers are:

- ``NullTracer``: discards events; the default
- ``InMemoryTracer``: capped ring buffer suitable for tests and replay
- ``OSLogTracer``: unified-log destination with privacy controls
- ``JSONLTracer``: newline-delimited JSON file, with a flush policy
- ``SignpostTracer``: Instruments signposts for `os_signpost`-driven profiling
- ``MetricsCollectingTracer``: aggregates per-run counters and latency percentiles
- ``CompositeTracer``: parallel fan-out across members
- ``RedactingTracer``: decorator that scrubs sensitive fields before they reach an inner tracer

## RedactingTracer

A trace that records a secret is a secret. ``RedactingTracer`` wraps any tracer and runs reject reasons, diagnostic messages, and tool names through a chain of ``Redactor`` instances before they reach the inner tracer. The pattern is straightforward:

```swift
let tracer = RedactingTracer(
    inner: try JSONLTracer(fileURL: traceURL, flushPolicy: .everyN(64)),
    redactors: [try CommonRedactors.email(), try CommonRedactors.bearerToken()]
)
```

Persist traces with confidence that raw secrets and PII do not survive the boundary.

## OSLogTracer privacy levels

``OSLogTracer/PrivacyLevel`` controls how the tracer hands TraceEvent fields to the unified log:

- `.maximal`: every field is logged as `.public`; matches the framework's earliest behavior
- `.balanced`: the default. Stable IDs and counts stay `.public`; free-form text (prompts, reject reasons, tool names) is marked `.private`
- `.opaque`: every field is `.private`

`.balanced` is the right default for production. Switch to `.maximal` only when you are exercising the framework in a controlled environment and want everything visible in Console.

## JSONLTracer flush policy

``JSONLTracer/FlushPolicy`` lets you trade durability for write cost:

- `.never`: the default. The OS flushes when it pleases.
- `.everyEvent`: fsync after every record. Maximum durability, maximum write cost.
- `.everyN(Int)`: fsync every N records. The middle ground.

Errors during write are reported through `os.Logger` rather than thrown.

## MetricsCollectingTracer

``MetricsCollectingTracer`` aggregates a ``MetricsSnapshot`` that holds run counts, model invocation latency, per-tool counters, per-verifier counters, repair scheduling counts, and budget exhaustion breakdowns. Model latency is backed by ``LatencyStats``, which keeps a sorted sample for O(log n) percentile reads. Call `current()` from the actor to read a consistent snapshot.

## Forward compatibility with TraceEventVisitor

``TraceEvent`` carries an open-ended ``TraceEvent/unknown(runID:label:payload:)`` case so consumers that switch with a `default:` arm stay source-stable across new events. ``TraceEventVisitor`` is the preferred shape for consumers who want to handle a subset of cases without writing exhaustive switches; every method has a no-op default. Dispatch happens through `TraceEvent.accept(_:)`:

```swift
struct ToolFailureCounter: TraceEventVisitor {
    let counter: Counter

    func visitToolInvocationCompleted(
        runID _: UUID,
        tool: String,
        elapsed _: Duration,
        succeeded: Bool
    ) async {
        if !succeeded { await counter.bump(tool: tool) }
    }
}
```

New cases added to ``TraceEvent`` need to be wired through `accept(_:)`, but adopters of ``TraceEventVisitor`` pick them up automatically as no-ops until they care.

## ProgressReporter

``ProgressReporter`` is the high-frequency, UI-facing signal. It carries ``ProgressEvent`` values like `.modelStreamChunk(turn:content:)`, `.verifierStarted(name:cost:)`, `.repairScheduled(attempt:diagnostic:)`. The shipped implementations are ``NullProgressReporter``, ``RecordingProgressReporter``, and ``StreamingProgressReporter`` for SwiftUI bindings. All streaming async sequences use bounded buffer policies so a slow consumer does not grow memory without bound.
