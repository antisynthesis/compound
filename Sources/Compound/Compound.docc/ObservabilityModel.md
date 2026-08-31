# Observability Model

How Compound separates structured tracing from live progress, where redaction sits, and the knobs you have for cost and forward compatibility.

## Overview

Compound separates two observability surfaces. ``Tracer`` and ``TraceEvent`` capture the structured-log record of a run: every model call, every tool invocation, every verifier verdict, every control-loop decision, with enough fidelity to reconstruct the run after the fact. ``ProgressReporter`` and ``ProgressEvent`` are the high-frequency, UI-facing signal a SwiftUI view binds to. Both surfaces run in parallel; neither replaces the other.

## Tracer composition

Tracers compose. ``CompositeTracer`` fans events out to its members in parallel via a `TaskGroup`, so adding another sink does not serialize the existing ones. The shipped tracers are:

- ``NullTracer``: discards events; the default
- ``InMemoryTracer``: capped ring buffer suitable for tests and replay
- ``OSLogTracer``: unified-log destination with privacy controls
- ``JSONLTracer``: newline-delimited JSON file, with a flush policy and size-bounded rotation
- ``SignpostTracer``: Instruments signposts for `os_signpost`-driven profiling
- ``MetricsCollectingTracer``: aggregates per-run counters and latency percentiles
- ``CompositeTracer``: parallel fan-out across members
- ``RedactingTracer``: decorator that scrubs sensitive fields before they reach an inner tracer

## RedactingTracer

``RedactingTracer`` wraps any tracer and runs every string in an event through a chain of ``Redactor`` instances before it reaches the inner tracer. The pattern is straightforward:

```swift
let tracer = RedactingTracer(
    inner: try JSONLTracer(fileURL: traceURL, flushPolicy: .everyN(64)),
    redactors: [try CommonRedactors.email(), try CommonRedactors.bearerToken()]
)
```

Redaction is **structural**, not case-by-case: the tracer encodes the event to its wire form, rewrites every string in the resulting JSON tree, and decodes it back. That matters because the alternative — a `switch` with one redaction arm per case — silently stops covering the taxonomy the moment someone adds a case and forgets an arm. With the structural pass, a new ``TraceEvent`` case is scrubbed the day it lands, and a coverage harness drives an exemplar of every case through the tracer asserting that seeded PII never survives.

Two classes of value pass through untouched:

- Numbers, booleans, and durations, which cannot carry free-form text.
- Four load-bearing identifier keys — `type`, `run`, `kind`, `ts` — plus the enum raw-value keys `signal`, `from`, `to`, and `mode`. These are case discriminators, the run UUID, and the emission timestamp; rewriting one would either break decoding or destroy run correlation.

Everything else is scrubbed, including the *keys* of a caller-supplied ``TraceEvent/unknown(runID:label:payload:)`` payload and the label itself. The tracer fails closed: an event that does not survive the encode-scrub-decode round-trip is withheld entirely and replaced by `.unknown(label: "trace.redaction_failed", payload: [:])`, so a redaction bug loses an event rather than leaking one.

Persist traces with confidence that raw secrets and PII do not survive the boundary.

## OSLogTracer privacy levels

``OSLogTracer/PrivacyLevel`` controls how the tracer hands TraceEvent fields to the unified log:

- `.maximal`: every field is logged as `.public`; matches the framework's earliest behavior
- `.balanced`: the default. Stable IDs and counts stay `.public`; free-form text (prompts, reject reasons, tool names) is marked `.private`
- `.opaque`: every field is `.private`

`.balanced` is the right default for production. Switch to `.maximal` only when you are exercising the framework in a controlled environment and want everything visible in Console.

## JSONLTracer: durability, size, and reading back

``JSONLTracer/FlushPolicy`` lets you trade durability for write cost:

- `.never`: the default. The OS flushes when it pleases.
- `.everyEvent`: fsync after every record. Maximum durability, maximum write cost.
- `.everyN(Int)`: fsync every N records. The middle ground.

Errors during write are reported through `os.Logger` rather than thrown, and a write after `close()` is dropped and logged rather than failing the write path.

Each line is a complete ``TraceRecord``: the whole event, losslessly, plus `ts` (epoch seconds) for the instant it was emitted. Events are keyed by a stable `type` discriminator matching ``TraceEvent/label``, and durations land as whole nanoseconds rather than the standard library's opaque high/low pair, so the file stays greppable and `jq`-friendly. This is a break from the pre-0.5 format, which wrote a flattened string summary that dropped ``Budget`` entirely and collapsed ``Verdict`` to a label; files written by older builds are not readable by ``TraceReader``.

The file is size-bounded. `maxFileBytes` (default 8 MiB) and `maxFiles` (default 4) rotate `<file>` → `<file>.1` → `<file>.2`, discarding the oldest generation, so a trace on a user's device cannot grow without limit. A single event larger than the cap is still written rather than dropped.

``TraceReader`` reads the format back — one file, or a whole rotated set oldest-first — into `[TraceRecord]`:

```swift
let batch = try TraceReader.readRotated(baseURL: traceURL)
for record in batch.records where record.label == "verifier.evaluated" {
    print(record.timestamp, record.event)
}
print("skipped \(batch.skippedLines) corrupt line(s)")
```

Two decisions make this robust against the files you actually find in the field. A corrupt or truncated line — the last line of a trace from a process that was killed mid-write, say — is **skipped and counted**, not thrown, so one bad byte does not cost you the run. And a line whose `type` this build does not recognize decodes as ``TraceEvent/unknown(runID:label:payload:)`` with its scalar fields flattened into the payload, so a consumer built against an older Compound can still reconstruct the shape of a newer run.

Decoding is also safe against a hostile file: ``Budget``'s decoder validates rather than asserting, so a trace with a negative cap throws a `DecodingError` instead of trapping the process.

## SignpostTracer intervals

``SignpostTracer`` emits `os_signpost` begin/end **intervals** for runs, model turns, and tool invocations, not point events, so Instruments shows durations on a timeline instead of isolated marks. Interval IDs are derived deterministically from the run UUID (plus the turn index or tool name), which means begin and end pair correctly even though they arrive as two independent ``TraceEvent`` values with no shared state — and the tracer stays a lock-free struct rather than an actor. One documented consequence: two concurrent invocations of the *same* tool within one run share an interval ID and pair in emission order.

Because these are intervals rather than points, Instruments traces recorded against a pre-0.5 build are not comparable with new ones.

## MetricsCollectingTracer

``MetricsCollectingTracer`` aggregates a ``MetricsSnapshot`` that holds run counts, model invocation latency, per-tool counters, per-verifier counters, repair scheduling counts, budget exhaustion breakdowns, and — via ``MetricsSnapshot/MemoryMetrics`` — memory write-path cost (consolidations, facts added/updated/deleted, rounds archived, model calls, consolidation latency). Model latency is backed by ``LatencyStats``, which keeps a sorted sample for O(log n) percentile reads. Call `current()` from the actor to read a consistent snapshot.

## Memory events

The memory layer adds exactly **one** ``TraceEvent`` case: ``TraceEvent/memoryConsolidated(runID:extracted:added:updated:deleted:archived:modelCalls:elapsed:)``, label `memory.consolidated`. It carries the per-pass write-path cost — candidates extracted, facts added/updated/deleted, rounds archived, model calls actually issued, and wall clock.

One case, and no more, is a deliberate budget. Each case costs an enum case, two switch arms, a visitor method, a default, an accept arm, three ``OSLogTracer`` privacy switches, and a pair of coding keys. This one earns it because write-path cost is the memory field's measurement blind spot, and on-device it is the number that decides shippability — those are structured integers that free-form strings cannot aggregate. `modelCalls` is reported even in the fully deterministic configuration where it is always zero, because "this configuration issues no model calls" is a claim that should be visible in the data rather than asserted in a doc comment.

Everything else memory does — recall, purge, decay, eviction, candidate rejection, queue overflow — uses ``TraceEvent/info(runID:category:message:)`` under the grammar documented on ``MemoryTrace``:

- category is always `memory`;
- the message is a space-joined list of `key=value` pairs;
- the first pair is always `event=<name>`;
- values never contain a space.

That last rule is enforced by ``MemoryTrace/value(_:)`` at the single choke point rather than trusted at each call site, because some values are host-supplied — a thread id comes from `RunContext.metadata` and is whatever the application put there. Unsanitized, a value containing a space would split into bogus pairs and one containing a newline could forge an entire log line.

Error values are reported by **type name, never message**. An error thrown by the memory write path can quote the very content a guard just refused to store, and a diagnostic line is not the place to leak it.

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
