# Architecture

The six layers of the Compound AI Systems pattern and how Compound wires them together.

## Overview

The pattern composes a stochastic component with a constellation of deterministic components such that overall system behavior is governed by the deterministic layer. Six layers cooperate on every run, and each is addressable on its own and replaceable independently.

```
   1. Context Assembly  →  2. Model  →  3. Tools  →  4. Verifier  →  5. Control Loop
                                              ╲              ╱
                                               6. Observability + Governance
```

## 1. Context assembly

Determines what the model sees. Before the model is invoked, deterministic code gathers inputs: retrieved documents, schema definitions, tool descriptions, prior turns of conversation, summaries, and system instructions. This is where most quality is won or lost and where most enterprise governance lives — the model never sees raw data, it sees the projection that assembly chose to admit.

Compound types:

- ``ContextAssembler`` — protocol
- ``DefaultContextAssembler`` — instructions + retriever + redactors + policy gate
- ``ConversationContextAssembler`` — adds prior message history with optional summarization
- ``TokenBudgetedAssembler`` — wraps any assembler to drop low-score sources until a soft token budget fits
- ``Retriever`` — protocol (``BM25Retriever``, ``DenseRetriever``, ``HybridRetriever``)
- ``MemoryContextAssembler`` — adds the two memory tiers (structured ``Fact`` records and archived transcript rounds) plus a pinned core block, with zero model calls on the read path; see <doc:MemoryModel>
- ``Redactor`` — pattern-based input redaction

Memory enters through this layer rather than beside it. Recalled facts and archived rounds become `RetrievedSource`s, pass through the same single redaction pass as documents, and are fenced by the same ``PromptFrame`` — so a remembered fact is exactly as inert as a retrieved one, and there is no second redaction seam to forget.

## 2. Stochastic core

The model invocation. The layer's responsibilities are narrow: format the request, send it, handle transport, parse the response. Sophisticated implementations expose temperature, sampling, and structured-output constraints at this boundary.

Compound types:

- ``ModelClient`` — actor wrapping `FoundationModels.LanguageModelSession`
  - `respond(to:options:)` — string
  - `respondGenerating(_:to:options:)` — typed via `Generable`
  - `stream(to:options:)` — delta async stream + final task

## 3. Tool surface

The model does not act on the world directly; it requests actions through named, typed, documented tools. Each tool is a deterministic function. Tools accept structured input, perform a bounded action, return a structured result. Every call is observable and replayable.

Compound types:

- ``VerifiedTool`` — wraps any `FoundationModels.Tool` with policy + verifier gating
- ``ToolRegistry`` — collection with per-run instantiation
- ``ToolRegistration`` — protocol for custom registration

The tool layer is the security boundary. Authorization lives in tools, not in the model.

## 4. Verifier layer

After the model produces an output (a tool call, a code edit, a SQL query, a structured document, or a final answer), the system runs one or more checks before treating the output as accepted. Verifiers range in cost: schema validation in microseconds, type checking in milliseconds, unit tests in seconds, formal proof checking in seconds-to-hours.

Compound types:

- ``Verifier`` — protocol parameterized by `Input`
- ``Verdict`` — `.pass`, `.repair(Diagnostic)`, `.reject(Diagnostic)`, `.escalate(Diagnostic)`; ``Verdict/reject(_:)-swift.type.method`` and ``Verdict/escalate(_:)-swift.type.method`` synthesize a diagnostic from a free-form reason string
- ``VerifierChain`` — ordered by ``VerifierCost``, short-circuits on first non-pass
- Around 40 verifier types totaling 100-plus built-in detection rules (see <doc:VerifierKit>)

A well-designed system runs the cheapest applicable verifier first and escalates only when cheap checks pass. The cardinal rule: the verifier must be more reliable than the model on the property being checked, otherwise it adds false confidence.

## 5. Control loop

Decides what to do at each step: which prompt to send, when to retry, when to stop, when to ask the human. In Compound it is bounded by ``Budget`` on every dimension (turns, tool calls, repair attempts, wall-clock, output tokens).

Compound types:

- ``ControlLoop`` — single-shot with repair turns
- ``StreamingControlLoop`` — same shape, yields ``ProgressEvent``s while running
- ``CompoundSession`` — the user-facing façade bundling all six layers

Bounded loops are a hard requirement. Unbounded agent loops are the most common production failure mode in this pattern.

## 6. Observability and governance

Surrounds the others. Every input, every model call, every tool invocation, every verifier outcome, and every control decision is logged with sufficient fidelity to reconstruct the full trace.

Compound types:

- ``Tracer`` — protocol
- ``InMemoryTracer``, ``OSLogTracer``, ``JSONLTracer``, ``SignpostTracer``, ``CompositeTracer``, ``MetricsCollectingTracer``
- ``RedactingTracer`` — decorator that scrubs reject reasons, diagnostics, and tool names through a chain of ``Redactor`` instances before they reach the inner tracer
- ``TraceEventVisitor`` — no-op-defaulted visitor for handling new ``TraceEvent`` cases without exhaustive switches
- ``ProgressReporter`` — UI-facing live signal (separate from Tracer)
- ``Policy``, ``AuthContext``, ``ScopeRequirement``, ``CompositePolicy`` — governance

See <doc:SecurityModel> for the security perimeter and <doc:ObservabilityModel> for the tracing surface.

Governance hooks belong at the deterministic boundaries: policy at the tool surface and the context assembly layer, never in the prompt.

## Why six layers, not one model call

The pattern is the architectural acknowledgment that large language models are powerful proposers and unreliable certifiers. Production systems are built from this asymmetry rather than against it. The pattern is not a shortcut — it requires investment comparable to investment in the model itself. The payoff is a system whose reliability does not depend on the model being right, only on the model being right often enough for the verifier loop to converge, and whose governance is structural rather than aspirational.
