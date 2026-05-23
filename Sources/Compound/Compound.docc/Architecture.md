# Architecture

The six layers of the Compound AI Systems pattern and how Compound wires them together.

## Overview

A language model on its own is a fluent, confident, frequently wrong oracle. The pattern is the architectural admission of that — a stochastic component wired into a constellation of deterministic ones, so that overall system behavior is governed by the part that does not lie. Six layers cooperate on every run, each addressable on its own and replaceable independently. Not because six is elegant: because the work has six genuine seams.

```
   1. Context Assembly  →  2. Model  →  3. Tools  →  4. Verifier  →  5. Control Loop
                                              ╲              ╱
                                               6. Observability + Governance
```

## 1. Context assembly

Determines what the model sees — and, more importantly, what it doesn't. Before the model is invoked, deterministic code assembles the inputs: retrieved documents, schema definitions, tool descriptions, prior turns of conversation, summaries, system instructions. This is where most quality is won or lost, and where most enterprise governance actually lives. The model never sees raw data. It sees the projection that assembly chose to admit.

Compound types:

- ``ContextAssembler`` — protocol
- ``DefaultContextAssembler`` — instructions + retriever + redactors + policy gate
- ``ConversationContextAssembler`` — adds prior message history with optional summarization
- ``TokenBudgetedAssembler`` — wraps any assembler to drop low-score sources until a soft token budget fits
- ``Retriever`` — protocol (``BM25Retriever``, ``DenseRetriever``, ``HybridRetriever``)
- ``Redactor`` — pattern-based input redaction

## 2. Stochastic core

The model invocation. Narrow responsibilities, on purpose: format the request, send it, handle transport, parse the response. Sophisticated implementations expose temperature, sampling, and structured-output constraints at this boundary. The model is the beautiful liar. Everything else in this architecture exists because we know that and refuse to ship it raw.

Compound types:

- ``ModelClient`` — actor wrapping `FoundationModels.LanguageModelSession`
  - `respond(to:options:)` — string
  - `respondGenerating(_:to:options:)` — typed via `Generable`
  - `stream(to:options:)` — delta async stream + final task

## 3. Tool surface

The model does not touch the world directly; the moment it could is the moment everything can go wrong. It requests actions through named, typed, documented tools. Each tool is a deterministic function — structured input, bounded action, structured result, every call observable and replayable. Letting a model reach through unguarded is exactly the easy idea that goes wrong in production.

Compound types:

- ``VerifiedTool`` — wraps any `FoundationModels.Tool` with policy + verifier gating
- ``ToolRegistry`` — collection with per-run instantiation
- ``ToolRegistration`` — protocol for custom registration

The tool layer is the security boundary. Authorization lives in tools, not in the prompt — a prompt is a wish, not a guarantee.

## 4. Verifier layer

The disposer. After the model produces an output — a tool call, a code edit, a SQL query, a structured document, a final answer — the system runs one or more checks before treating the output as accepted. Verifiers range in cost: schema validation in microseconds, type checking in milliseconds, unit tests in seconds, formal proof checking in seconds-to-hours. The system's reliability is bounded by the verifier's reliability, no further.

Compound types:

- ``Verifier`` — protocol parameterized by `Input`
- ``Verdict`` — `.pass`, `.repair(Diagnostic)`, `.reject(Diagnostic)`, `.escalate(Diagnostic)`; ``Verdict/reject(_:)-swift.type.method`` and ``Verdict/escalate(_:)-swift.type.method`` synthesize a diagnostic from a free-form reason string
- ``VerifierChain`` — ordered by ``VerifierCost``, short-circuits on first non-pass
- Around 40 verifier types totaling 100-plus built-in detection rules (see <doc:VerifierKit>)

A well-designed system runs the cheapest applicable verifier first and escalates only when cheap checks pass. The cardinal rule, non-negotiable: the verifier must be more reliable than the model on the property being checked, otherwise it adds false confidence — a more dangerous failure than no check at all.

## 5. Control loop

Decides what to do at each step: which prompt to send, when to retry, when to stop, when to ask the human. In Compound it is bounded by ``Budget`` on every dimension (turns, tool calls, repair attempts, wall-clock, output tokens). The leash is short and it is in your hand.

Compound types:

- ``ControlLoop`` — single-shot with repair turns
- ``StreamingControlLoop`` — same shape, yields ``ProgressEvent``s while running
- ``CompoundSession`` — the user-facing façade bundling all six layers

Bounded loops are a hard requirement, not a suggestion. Unbounded agent loops are the most common production failure mode in this pattern — they burn battery and money until something catches fire.

## 6. Observability and governance

Surrounds the others. Nothing happens off the books. Every input, every model call, every tool invocation, every verifier outcome, and every control decision is recorded with enough fidelity to reconstruct the full trace. A system you cannot inspect is a system you cannot trust.

Compound types:

- ``Tracer`` — protocol
- ``InMemoryTracer``, ``OSLogTracer``, ``JSONLTracer``, ``SignpostTracer``, ``CompositeTracer``, ``MetricsCollectingTracer``
- ``RedactingTracer`` — decorator that scrubs reject reasons, diagnostics, and tool names through a chain of ``Redactor`` instances before they reach the inner tracer
- ``TraceEventVisitor`` — no-op-defaulted visitor for handling new ``TraceEvent`` cases without exhaustive switches
- ``ProgressReporter`` — UI-facing live signal (separate from Tracer)
- ``Policy``, ``AuthContext``, ``ScopeRequirement``, ``CompositePolicy`` — governance

See <doc:SecurityModel> for the security perimeter and <doc:ObservabilityModel> for the tracing surface.

Governance hooks belong at the deterministic boundaries: policy at the tool surface and the context assembly layer. Never in the prompt — the model will be talked out of any rule written there.

## Why six layers, not one model call

The pattern is the architectural acknowledgment that large language models are powerful proposers and unreliable certifiers. Production systems are built from that asymmetry, not against it. It is not a shortcut. It demands investment comparable to investment in the model itself. The payoff is a system whose reliability does not depend on the model being right — only on the model being right often enough for the verifier loop to converge — and whose governance is structural rather than aspirational. The hard things are not made easy here. They are made possible.
