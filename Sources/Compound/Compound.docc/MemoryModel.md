# Memory model

How Compound remembers across turns, what it forgets, and why almost none of it calls a model.

## Overview

Memory in Compound is a **cost, latency, and correctness mechanism**, not a claim to beat full context on accuracy.

That distinction is load-bearing, so it is worth stating plainly. When you can afford to put the whole conversation in the prompt, doing so generally wins: on Mem0's own LOCOMO table, full context scored 72.90 against Mem0's 66.88, and BEAM puts structured memory's edge over long context at 3.5–12.7%. Compound targets Apple's on-device model with a **4096-token window**, where a full LOCOMO conversation (9k–16k tokens) does not fit — roughly 3× the entire budget. There is no full-context alternative to lose to.

What Compound does claim is the part that actually breaks in production: a **forgetting control plane**. Supersession, decay, amnesia, purge, and drift are the failure modes that turn a memory feature into a support ticket, and they are all deterministic, all testable, and all measured by an eval suite with no LLM judge in it.

Two properties define the design:

- **The read path makes zero model calls.** Every turn's recall is a store query plus deterministic ranking. Reads stay at BM25/dense speed whether or not Apple Intelligence is available.
- **The write path runs off the critical path.** A completed turn is enqueued in O(1) and consolidated later from a background activity.

## The two tiers

### Tier 1 — facts

``Fact`` is a small, structured, bi-temporal record: a deterministic id, verbatim-span text, provenance back to ``ConversationMessage`` ids, confidence, importance, tags, a trust origin, an optional TTL, and four dates.

The four dates are the bi-temporal shape, borrowed from Zep **without** its knowledge graph:

| Field | Meaning |
| --- | --- |
| `validFrom` | when the claim became true in the world |
| `validUntil` | when it stopped being true (`nil` while current) |
| `recordedAt` | when the system wrote the record |
| `invalidatedAt` | when the system retired it (`nil` while live) |

Separating world time from transaction time is what makes "what did I believe in March?" answerable. A correction never mutates history in place: it inserts a new record and sets the outgoing one's `validUntil` to the incoming one's `validFrom`.

Ids come from ``FactID/derive(threadID:subject:predicate:text:)``, which routes through `DocumentChunker.chunkID` under a `compound.memory.fact.v1` domain. Facts therefore share the 32-hex id space with document chunks but occupy a **disjoint region**, so hybrid fusion can never double-credit a fact and a chunk as if they agreed.

``MemoryStore`` has two implementations — ``InMemoryFactStore`` and the durable ``FileFactStore`` — and is deliberately **embedding-free**. Its ``MemoryStore/similar(to:slot:threadID:limit:now:)`` is weighted Jaccard over `BM25Retriever.defaultTokenize`. Two reasons: the store stays testable off-device with zero providers, and MemDelta showed that swapping an embedder alone can reverse a published memory conclusion, so the control plane must not depend on embedding quality.

A corrupt store file **throws** ``MemoryError/corruptStore(path:detail:)`` rather than skipping bad entries the way a JSONL transcript reader does. Silently discarding a user's memory is worse than failing loudly.

### Tier 2 — archive

Transcript aged out of the working window is chunked at **round** granularity (LongMemEval: 0.615 vs 0.592 for session-level) by ``RoundBuilder``, then indexed and read back through the retrievers that already exist. There is no third index.

``IndexedArchivalStore`` implements LongMemEval's K = V + facts key expansion (+9.4% Recall@5) without touching `DocumentChunk`, `BM25Retriever`, or `DenseRetriever`. It indexes an `indexText` — display text plus a deterministically derived key line of dates, entity candidates, and quantities — while **serving** the verbatim `displayText`. Indexing summaries or extracted facts *as* the served value measurably hurt accuracy in LongMemEval, which is why the raw round survives as the content.

The key line is a pure function of the round alone, never of the evolving fact store, so chunk ids are stable and re-archiving is idempotent. Dates come from `NSDataDetector` and only when an explicit four-digit year is present: a relative expression like "tomorrow" would resolve against the current date and make the id a function of *when archiving ran*.

``ArchivalRetriever`` is a plain `Retriever`, so the archive drops into `HybridRetriever`, `RerankingRetriever`, and `RetrievalEvalRunner` with no new API.

## Deletion fans out to every index

This is the correctness path that matters most. ForgetEval showed lexical and vector deletion are **complementary, not redundant**: 32/39 vs 12/39 on prefix collision, and 21/38 vs 0/38 on cross-lingual aliases. A purge that reaches only one index leaves the content retrievable through the other.

``ArchivalStore/remove(chunkIDs:)`` therefore fans out to every index, **collects** per-index failures instead of short-circuiting on the first, drops the round from the journal either way, queues the failures durably, and throws ``MemoryError/partialRemoval(chunkIDs:failedIndexes:)``. Pending removals are retried at the head of the next `archive`, `remove`, or `rehydrate`, and by ``MemoryMaintenance``. A purge one index refuses is never silently partial.

Invalidation and purge are **separate code paths on purpose**. Invalidation is bi-temporal and recoverable; purge is destructive, compliance-shaped, and **exact-match only** — ``PurgePredicate`` has no similarity field and no id-prefix field, because substring matching is precisely the prefix-collision failure mode, and semantic similarity is the wrong primitive for a GDPR-shaped deletion. Consolidation never reaches the purge path at all; a spy store asserts that in the test suite.

## The deterministic core, and the two optional model hooks

Everything below is deterministic — all of it, with no model call anywhere:

- the entire read path,
- all id derivation,
- ranking and budget fitting,
- reconciliation routing and contradiction resolution,
- TTL, decay, and eviction,
- purge,
- the entire eval suite.

Exactly **two** model hooks exist. Both are optional, both sit behind `#if canImport(FoundationModels)` with an availability guard and a deterministic fallback, and both are placed where ForgetEval measured a +22.6 to +24.1 point lift — mutation time — and nowhere else. The circuit-analysis result is the reason for the shape: bounded routing decisions mature below 1B parameters, while open-ended content extraction does not mature until roughly 4B.

**``ModelFactExtractor``** selects a subset of *already-computed* spans and re-rates importance. Its entire vocabulary is integers. It cannot author text, edit text, add a span, or invent a subject.

**``ModelMutationHook``** re-decides only genuinely ambiguous candidates, choosing one of add/update/delete/noop plus an **index into a bounded option list** it was handed. It never supplies text and never names an id that was not in the list.

Both copy `ModelReranker`'s contract exactly: a `withDeadline` cap, an explicit `maxModelCalls` budget, deterministic validation before admission, whole-response rejection on any violation (partial merges are forbidden — model scores and deterministic ranks are not on a common scale), and **cancellation rethrown rather than treated as a fallback**.

Validation is not optional politeness. Syntactic validity is not evidence of correctness: a routing token decodes cleanly whether or not it is right. So a model-proposed fact text must be a verbatim substring of a real message, and a model-proposed target id must be one that was supplied.

## Provenance, trust, and redaction

**Memory is user data.** Every record carries a ``MemoryOrigin`` with a trust rank — `userStated` (4), `assistantStated` (3), `toolOutput` (2), `retrievedDocument` (1), `derived` (0) — and non-user-stated origins must clear a higher confidence bar to be admitted at all.

Be precise about what that buys. Reported memory-poisoning success rates run 34–67%, and the most vulnerable configuration was the one that auto-injects memory into the prompt. Provenance binding here is **defense in depth and debuggability, not a validated mitigation**. It is not a reason to relax any other control.

Two guards do the real work on the write path:

1. **The verbatim-span guard.** A candidate's text must be a literal substring of a message the candidate *names* as its evidence — not merely a span found somewhere else in the transcript, which would make the provenance pointer decorative. An extractive-only write path eliminates hallucinated memories at essentially zero cost, and is the single highest-value guard available for a ~3B writer.
2. **Write-path redaction.** Redactors run on the way **in** as well as out. If any redactor *changes* a candidate's text, the candidate is **rejected outright** rather than stored redacted — for two reasons. A redacted span is no longer a verbatim span, so the first guard's invariant would be void; and a fact containing a secret should not be persisted at all.

On the read path, everything admitted — the core block, facts, archival rounds, and document sources alike — passes through **one** `.retrievedSources` redaction pass, and everything reaches the model through `sources` or `transcript`. `PromptFrame` fencing therefore applies to a remembered fact exactly as it does to a retrieved document. A fact whose body contains fence-shaped text is escaped, not parsed. There is no per-tier redaction seam that a future change could forget to call.

## Budget

Memory's whole prompt share defaults to **~448 tokens of 4096** (~11%): 96 for the pinned core block, 160 for facts, 192 for archival rounds.

That is deliberately far below the field's norms — Zep injects roughly 1.6k memory tokens and Mem0 roughly 6.7–7k — because at a 4096-token total either would starve the task the user actually asked about.

Three mechanics make the number hold:

- The **core block is pinned** with `score: nil`, which `TokenBudgetedAssembler` documents as the evict-last position. It is the highest value per token available: zero retrieval cost and zero read-path model calls.
- **Facts carry normalized salience scores**, so the least salient is evicted first.
- The **assembler trims its own transcript**. This closes a real hazard: `TokenBudgetedAssembler` evicts sources but never transcript, so an oversized transcript would be charged to the budget, be untrimmable, starve retrieval completely, and then merely log that it had dropped every source.

One asymmetry is deliberate and documented: ``MemoryBudget/coreBlockTokens`` caps the core block's **body**, while every other tier is fitted on title-plus-body. Charging the fixed core title too was tried and reverted, because under a tight budget it deletes the one source the design pins as un-evictable — and a cap that removes the un-evictable source is worse than one that undercounts a constant. The title is still real prompt weight, and the eval measures the whole share title-inclusive against ``MemoryBudget/memoryTokens``.

## Configuring memory

Memory is entirely optional. ``CompoundSession/Configuration/memory`` defaults to `nil`, and `nil` preserves prior behavior exactly — a memory-free session emits no `memory.consolidated` event, no `category: "memory"` trace line, and touches no store. Three tests pin that as a falsifiable property.

### Read path

Swap the assembler for a ``MemoryContextAssembler``:

```swift
let facts = InMemoryFactStore()
let conversation = InMemoryConversationStore()

let assembler = MemoryContextAssembler(
    baseInstructions: "You are a helpful on-device assistant.",
    conversation: conversation,
    memory: facts,
    budget: .default,
    redactors: [try CommonRedactors.email()]
)
```

### Write path

Attach a ``MemorySessionConfiguration`` and a ``MemoryConsolidator``. The consolidator conforms to ``MemoryTurnObserving``; its `turnCompleted` is a bounded-queue append and nothing else, which is the contract the protocol requires.

```swift
let consolidator = MemoryConsolidator(
    memory: facts,
    conversation: conversation
)

let session = CompoundSession(.init(
    assembler: assembler,
    memory: MemorySessionConfiguration(
        conversation: conversation,
        observer: consolidator
    )
))
```

Threads scope through `RunContext.metadata` rather than through a new `ConversationStore` requirement:

```swift
let outcome = try await session.respond(
    to: "Remember that I live in Reykjavik.",
    metadata: [MemorySessionConfiguration.defaultThreadIDMetadataKey: "thread-7"]
)
```

### Draining the queue

Nothing consolidates until a maintenance pass runs. ``MemoryConsolidator`` deliberately spawns **no internal pump task** — nothing else in the package creates hidden unstructured `Task`s, and one here would sit outside the cancellation discipline every other component honors. The resulting freshness gap is an accepted, documented property, matching Mem0's treatment of its asynchronous rolling summary.

```swift
let maintenance = MemoryMaintenance.activity(
    identifier: "com.example.app.memory",
    consolidator: consolidator,
    store: facts,
    forgetting: .default
)
```

Every step of a pass is idempotent and resumable, because any throw or observed cancellation maps to `.deferred` and the scheduler retries from the top. A pass that fails leaves memory **unchanged** rather than half-written: the read-only analysis phase runs under a deadline that degrades to an empty decision list, and the one store-mutating stage is never raced.

## Forgetting

``ForgettingPolicy`` covers TTL by tag, expiry of unreconfirmed derived facts, confidence decay, and per-thread salience eviction. Every path **invalidates, never purges**, and a sweep is idempotent at a fixed instant.

Two design points are worth knowing before you tune it:

- **Decay is computed, never written back.** Persisting a decayed confidence would require a "confidence as of" timestamp to decay from next pass; without one, a second sweep at the same instant would decay an already-decayed number and retire records the first pass kept. The sweep would stop being idempotent, which a deferred background body cannot tolerate.
- **The default forgets almost nothing.** No default TTL, no decay, no per-thread cap; the single active rule expires unreconfirmed derived facts after 30 days. Nothing a user *said* expires on age alone. Aggressive forgetting is an opt-in a host application makes on purpose.

State the epistemic status honestly: **TTL and decay are engineering convention, not validated cognitive science.** The 2026 survey calls current forgetting approaches crude and names learned forgetting an open problem. That is exactly why they ship as explicit, user-visible, deterministically tested policy rather than as a tuned default nobody can inspect.

## Observability

Exactly one new trace event earns its keep: `memory.consolidated`, carrying extracted / added / updated / deleted / archived counts, model calls, and elapsed time. Write-path cost is the field's measurement blind spot, and on-device it is the number that decides shippability — those are structured integers that free-form `.info` strings cannot aggregate. `MetricsCollectingTracer` folds them into ``MetricsSnapshot/MemoryMetrics``.

Everything else — recall, purge, decay, eviction, rejection — uses `.info` under ``MemoryTrace``'s documented grammar: category `memory`, a space-joined `key=value` list, `event=` always first, and values sanitized so a host-supplied thread id cannot split a pair or forge a line. Error values are reported by **type name, never message**, since an error thrown by the write path can quote the very content a guard just refused to store.

## Evaluation

The memory suite uses **no LLM judge anywhere**. A case passes iff every `mustContain` term is present in the normalized top-k blob and no `mustNotContain` term is — a pure set predicate, reproducible across model versions, which is what a committed golden baseline requires.

Fourteen cases span supersession, drift, decay, amnesia, purge, prefix collision, cross-lingual obfuscation, fact recall across turns, and contradiction updates. Reports record ``MemoryEvalReport/Provenance`` (embedder, extractor, reconciler, prompt version, model availability) alongside the pass rate, because MemDelta showed a +11pp "memory gain" reversing to −1.2pp on an embedder swap alone: a baseline that does not record its confounds silently invalidates itself.

Every report also carries a **memory-off control** delta. MemDelta found agent self-memory (42%) losing to basic retrieval (47%), so the suite always reports memory-on minus memory-off and the gate never blesses a component that fails to beat the control.

The gate is `EvalGate(passRateThreshold: 0.75, tolerance: 0.0)` rather than the golden gate's `1.0 / 0.0`. The threshold is below 1.0 because the suite **deliberately includes adversarial families that deterministic systems are known to fail** — ForgetEval reports ≤5% on identifier obfuscation and 0% on cross-lingual aliases — and the committed baseline records one such failure today. Including them keeps the known weakness visible in the baseline rather than absent from it. Tolerance 0.0 is what stops those documented gaps from widening silently: you may ship a suite with documented gaps, but you may not widen them without a reviewer seeing it.

Regenerate deliberately, and commit the diff:

```
REGENERATE_MEMORY_BASELINE=1 swift test --filter MemoryGoldenGate
```
