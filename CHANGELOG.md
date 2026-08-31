# Changelog

All notable changes to this project will be documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] – 2026-08-30

Hardening release: budgets that mean what they say, a typed error taxonomy, deadline enforcement for hung models, fail-closed security gates, tool-output verification, self-contained repair prompts, typed structured output through the control loop, and token accounting with proactive context compaction. Contains breaking changes; see the migration notes at the end of this entry.

### Added

- Typed structured output through the control loop: `ControlLoop.run(prompt:modelClient:runContext:mode:extract:verifiers:)` returns a `TypedRunOutcome<T>` gated by a typed `VerifierChain<T>`, with `.reasonThenExtract` (free-form reasoning with tools first, constrained extraction second) and `.direct` modes. `CompoundSession.respond(to:generating:verifiers:mode:)` exposes it at the facade; `ModelResponding.extractor(_:options:)` binds extraction to `respondGenerating`.
- `withDeadline(_:clock:onTimeout:operation:)` and `DeadlineExceededError` (`Core/Deadline.swift`) — a general-purpose deadline race that cancels the losing operation.
- Mid-stream stall detection: `Budget.firstToken` and `Budget.interChunkGap` durations with matching `BudgetExhaustion.firstToken` / `.interChunkGap` cases. `StreamingControlLoop` races chunk consumption against a stall watchdog; on a mid-stream timeout, non-empty partial output that passes the full verifier chain is salvaged as the run's final output.
- Typed error taxonomy for FoundationModels session failures: new `CompoundError` cases `.guardrailViolation(context:)`, `.contextWindowExceeded(promptTokens:)`, `.refusal`, `.unsupportedLanguage`, and `.modelRateLimited`, mapped at the `ModelClient` boundary via `CompoundError.mapSessionError(_:)` (handles both `GenerationError` and the OS 27+ `LanguageModelError`).
- Transient-failure retry in `ControlLoop`: new `retryPolicy` (default `.default`) and `retryClassifier` (default `DefaultRetryClassifier()`) parameters. Guardrail violations and unsupported-language errors throw immediately without consuming retry or repair budget; each guardrail violation is counted in the trace.
- `RepairPromptBuilder` on `ControlLoop` and `StreamingControlLoop`: `.default` builds a self-contained repair prompt (original task + byte-capped failed output + every diagnostic with suggestions) so stateless `ModelResponding` conformers can actually repair; `.diagnosticOnly` preserves the previous diagnostic-only prompt for stateful transports.
- `VerifierChain.Mode.collectAll(maxDiagnostics:)` — run past `.repair` verdicts and fold every diagnostic into one repair round (`.reject` / `.escalate` still terminate immediately); new `verifyCollecting(_:context:)`, `Verdict.diagnostic`, and `Diagnostic.combined(_:verifier:)`.
- Tool-output verification: `VerifiedTool` now runs an output verifier chain over every tool result before it re-enters the model context; `ToolRegistry.register` accepts `outputVerifiers:`. Rejections throw `CompoundError.toolOutputRejected(name:diagnostic:)` and the poisoned output is withheld. New trace events `tool.argument.rejected` / `tool.output.rejected` and matching `MetricsSnapshot` counters.
- Budget `maxToolCalls` enforcement: a new `ToolCallMeter` actor on `RunContext`, recorded by every `VerifiedTool` invocation, throws `budgetExhausted(.toolCalls)` mid-turn on the call after the cap.
- Token accounting: `TokenCounting` protocol with `HeuristicTokenCounter` (default) and `SystemModelTokenCounter` (real on-device tokenizer on 26.4+), plus `SessionTokenLedger`. `ModelClient` tracks context occupancy per turn and proactively compacts its session (fresh transcript seeded with instructions + the last exchange) when the configurable high watermark (default 80%) is crossed. `CompoundSession.respond` recovers from `contextWindowExceeded` by re-assembling once under a token budget; new `Configuration.tokenCounter` / `Configuration.contextHighWatermark`.
- Eval hardening: `EvalGate` (pass-rate threshold + baseline tolerance with per-case regression listing), `EvalReport` is now `Codable` with an `Environment` snapshot (OS version, model availability), per-case `caseTimeout` producing `.timedOut` outcomes, per-case `runID`, sliding-window concurrency, and typed `EvalError` instead of a `fatalError` trap on duplicate case IDs.
- `CompoundSession.Configuration.makeModel` — an injection seam receiving the assembled instructions, the run's policy-wrapped tools, and the `RunContext`; enables full off-device facade testing.
- Context redaction and fencing: `RedactionScope` OptionSet (default `.all`) on `DefaultContextAssembler` / `ConversationContextAssembler`; rendered prompts fence untrusted content (`<source id="...">`, `<message role="...">`, with `&`/`<` escaping) via the new public `PromptFrame` / `PromptFraming` customization point; `CommonRedactors.fromSecretsRules()` builds redactors from `SecretsVerifier`'s default rule set.
- Shell command-substitution tokenization: `ShellToken.commandSubstitution` for `$(...)` and backtick spans; both shell verifiers recursively re-gate inner commands with a recursion-depth cap.
- `DefaultProcessRunner`: per-stream output capture capped at `maxOutputBytes` (default 4 MB) with a truncation marker, `killGracePeriod` (default 2 s) for SIGTERM → SIGKILL escalation, and `ProcessResult.truncated`.
- New red-team test suite (`RedTeamTests`) covering shell substitution bypasses, SQL CTE/EXPLAIN bypasses, redirect SSRF, and fail-closed verifier internals.
- `MetricsCollectingTracer` — aggregates `TraceEvent`s into a `MetricsSnapshot` (per-run, per-tool, per-verifier rollups with latency stats and approximate p50/p99).
- `MetricKitObserver` — iOS / macOS / visionOS bridge for Apple's MetricKit aggregated payloads.
- Apache 2.0 license, contributor guide, security policy, GitHub Actions CI workflow.

### Changed

- **Budget caps now mean "number of allowed occurrences"**: `Budget(maxTurns: N)` permits N model turns and `Budget(maxRepairAttempts: N)` permits N repairs (each previously permitted N−1, and `maxTurns: 1` failed before any call). `maxToolCalls: 0` now means "no tool calls allowed" instead of instantly exhausting tool-free runs. `BudgetUsage` in `budgetExhausted` errors reflects only occurrences that actually ran.
- `ControlLoop` and `StreamingControlLoop` now share an internal `LoopCore` (budget check-then-record, verifier execution, verdict disposition, repair prompts), removing ~150 duplicated lines. In-flight model calls are wall-clock bounded, so a hung `respond()` surfaces as `budgetExhausted(.wallClock)` instead of blocking forever.
- `ModelClient.respond` / `respondGenerating` / `stream` no longer wrap every session error in `.underlying`: recognized FoundationModels errors surface as typed cases, and `CancellationError` crossing the boundary surfaces as `CompoundError.cancelled`. Model availability is re-checked at the start of every run and before every call.
- `DefaultRetryClassifier` unwraps `.underlying` before classifying, treats `.modelRateLimited` as transient, and splits `.modelUnavailable` by reason: model-not-ready / downloading / assets-unavailable retry; device-not-eligible, Apple Intelligence disabled, and unknown reasons are terminal.
- `VerifierChain` ordering is fully deterministic via a stable `(cost, name)` sort key; equal-cost members execute in alphabetical name order.
- `EvalRunner.run(_:against:)` now throws; `StubEvalTarget` throws on unknown prompts instead of silently returning `""`; `MatchesRegexPredicate` rethrows regex-engine errors instead of reporting them as a mismatch.
- `ConversationContextAssembler` no longer embeds the transcript in `userPrompt` — history travels in the new `AssembledContext.transcript` field and is rendered (fenced) by `renderedPrompt()`.
- `TokenBudgetedAssembler` measures cost through the context's own `PromptFraming` (render format can no longer drift), charges system instructions against the budget, accepts an injected token counter, and preserves transcript/framing when trimming.
- `SQLTokenizer.classify` returns the most-privileged top-level verb rather than the first keyword (`WITH x AS (...) DELETE` → `.delete`, `EXPLAIN ANALYZE DELETE` → `.delete`).
- On timeout, `ProcessResult.exitCode` is the child's actual termination status (post SIGTERM/SIGKILL) rather than always −1; `timedOut` remains the authoritative flag. Timed-out compile-gate verifiers now attach partial output to their `.repair` suggestion.
- Tool invocations that return in-band `"error: ..."` strings are traced with `succeeded=false`; argument-verifier `.repair` verdicts on `String`-output tools return the diagnostic in band so the model can retry, instead of throwing.
- The statefulness contract is now documented on `ModelResponding`.

### Fixed

- `Budget(maxTurns: 1)` no longer throws before the first model call (fencepost).
- `Budget.maxToolCalls` was silently dead; it is now enforced.
- `DefaultProcessRunner` pipe deadlock: children emitting more than 64 KB on stdout/stderr no longer hang — both pipes drain concurrently before `waitUntilExit`. Timeout and task cancellation now escalate SIGTERM → SIGKILL and reap children that ignore SIGTERM.
- `CompoundError.verifierRejected` and `.escalationRequired` carry the rejecting/escalating verifier's own diagnostic instead of a stale diagnostic from an earlier repair turn.
- Flaky mid-turn token-budget enforcement in `StreamingControlLoop`: a cap breach measured on received chunks now deterministically fails the run instead of relying on the model's final task observing cancellation.
- `StreamingControlLoop` finishes its event stream with the error on cancellation and other non-loop failures instead of leaving it unterminated, and reports `turnStarted` through the `ProgressReporter`.
- A hung final task after a completed stream is now bounded by the remaining wall clock.
- `TokenBudgetedAssembler` silently discarded `transcript` and `framing` when rebuilding trimmed contexts, and its cost heuristics had drifted from the actual render format.
- SQL number lexer no longer swallows `1-2` into one token (`+`/`-` are only absorbed as an exponent sign after `e`/`E`).
- `EvalRunner` no longer traps (`fatalError`) on duplicate case IDs.
- Stale doc-comment examples (`PromptOnlyAssembler`, non-throwing `registry.register` / `EvalRunner().run`) corrected in docs and `Examples/`.

### Security

- Fail-closed gate hardening across the shell, SQL, secrets, JSON-schema, and web-fetch verifiers (all landed red-first in `RedTeamTests`):
  - Shell verifiers tokenize and recursively re-gate `$(...)` / backtick command substitutions using the caller's `RunContext` (a fabricated internal context was removed), and see fetch-pipe-shell (`curl | sudo sh`, `curl | env bash`) through wrapper words.
  - `SQLSafetyVerifier` closes `WITH ... DELETE` CTE and `EXPLAIN ANALYZE DELETE` bypasses via most-privileged-verb classification.
  - `SecretsVerifier.defaultRules` (now 24 rules) compiles eagerly and traps on an uncompilable pattern instead of silently dropping it (fail-open); mid-scan engine errors reject.
  - `JSONSchemaVerifier` rejects an uncompilable `pattern` instead of treating it as no-constraint.
  - `WebFetchTool` re-runs the full SSRF gate on every HTTP redirect hop and caps hops (default 5), closing redirect-to-metadata SSRF; the remaining DNS TOCTOU is documented in-code.
- Tool outputs are verified before re-entering the model context, closing an indirect prompt-injection channel; rejected outputs are withheld.
- Retrieved sources and stored conversation history are now redacted by default (`RedactionScope.all`) and fenced in rendered prompts, so injected citation lines, fake fences, and forged `User:` turns stay inert.
- `PatternRedactor` fails closed on inputs larger than `inputSizeLimit` (default 1 MiB): the whole text is replaced with a placeholder instead of passing through unscanned.

### Migration notes

- **Budget fencepost semantics.** Each cap is now the number of allowed occurrences: `Budget(maxTurns: N)` permits N model turns (previously N−1) and `Budget(maxRepairAttempts: N)` permits N repairs. Runs tuned around the old off-by-one will make one more call/repair than before. The `repairScheduled` event is no longer emitted for a repair the budget refuses.
- **`maxToolCalls` is now enforced.** With a cap of N, the N+1-th tool invocation throws `CompoundError.budgetExhausted(.toolCalls, usage)` mid-turn, before policy evaluation or execution. `maxToolCalls: 0` now means "no tool calls allowed".
- **New enum cases.** Exhaustive switches must add arms for: `CompoundError` `.guardrailViolation`, `.contextWindowExceeded`, `.refusal`, `.unsupportedLanguage`, `.modelRateLimited`, `.toolOutputRejected`, `.toolAlreadyRegistered`; `BudgetExhaustion` `.firstToken`, `.interChunkGap`; `TraceEvent` `.toolArgumentRejected`, `.toolOutputRejected` (`TraceEventVisitor` adopters inherit no-op defaults); `ShellToken.commandSubstitution` and `ShellParseError` `.unterminatedCommandSubstitution` / `.unterminatedBacktick`; `EvalReport.CaseOutcome.Result.timedOut`.
- **Throwing APIs.** `EvalRunner.run(_:against:)` and `ToolRegistry.register(...)` now throw — add `try`. `EvalReport.CaseOutcome`'s memberwise init requires the new `runID:`. `VerifiedTool` / `ToolRegistry.register` now require `Wrapped.Output: Sendable`.
- **Error mapping.** Code that matched `CompoundError.underlying` for rate limits, guardrails, context overflow, refusals, or cancellation must match the new typed cases; `CancellationError` at the model boundary is now `.cancelled`.
- **Retry defaults.** `ControlLoop` now retries transient model failures by default (up to 3 attempts with backoff, debiting `Budget.wallClock`); pass `retryPolicy: .none` for single-attempt behavior. `DefaultRetryClassifier` no longer retries every `.modelUnavailable`.
- **Repair prompts.** The default repair prompt is now self-contained (task + truncated failed output + diagnostics). Stateful transports that depended on the minimal prompt should pass `repairPromptBuilder: .diagnosticOnly`.
- **Verifier ordering.** Equal-cost `VerifierChain` members now run in alphabetical name order; chains relying on insertion order must rename or re-cost.
- **Redaction and rendering.** Redactors now scan retrieved source titles/bodies and stored history by default — pass a narrower `redactionScope` for prompt-only scanning. `renderedPrompt()` output changed to fenced `<source>` / `<message>` blocks with escaping; `AssembledContext.userPrompt` from `ConversationContextAssembler` no longer contains the transcript.
- **Streaming semantics.** A turn that stalls mid-stream (`firstToken` / `interChunkGap` / `wallClock`) may now complete with salvaged partial output when the partial passes the full verifier chain; previously a stalled model blocked indefinitely.
- **Stricter gates.** Statements formerly slipping through the SQL allow-list via `WITH` / `EXPLAIN` are now rejected; `WebFetchTool` follows at most `maxRedirects` (default 5) hops and re-gates each; `StubEvalTarget` throws on unknown prompts instead of returning `""`.

## [0.3.0] – initial public preview

### Added — streaming, conversation, prompts, eval, retrieval, retry, Apple integration

- `ModelClient.stream(to:options:)` — delta-chunk `AsyncThrowingStream` plus final-result `Task`.
- `StreamingControlLoop` — propose-and-check loop that yields `ProgressEvent`s while running. Cancellation propagates through the loop.
- `ProgressReporter` protocol with `NullProgressReporter`, `RecordingProgressReporter`, `StreamingProgressReporter` (SwiftUI binding via subscriber `AsyncStream`).
- `ConversationMessage`, `InMemoryConversationStore`, `JSONLConversationStore`, `ConversationContextAssembler`, `TruncatingSummarizer`.
- `PromptTemplate`, `PromptRegistry` — versioned prompts with strict parameter substitution.
- `EvalCase`, `EvalSuite`, `EvalRunner`, `EvalReport`, `EvalPredicate` (Contains / DoesNotContain / MatchesRegex / Verifier / Closure).
- `DocumentChunker.slidingWindow` and `.paragraphs`.
- `BM25Retriever` (pure-Swift), `DenseRetriever` (NLEmbedding-backed), `HybridRetriever` (Reciprocal Rank Fusion), `Reranker` + `RerankingRetriever`, `TokenBudgetedAssembler`.
- `RetryPolicy`, `Retry.with`, `DefaultRetryClassifier`, `UnionRetryClassifier`.
- `NSDataDetectorPIIVerifier`, `LanguageVerifier` (NLLanguageRecognizer), `SHA256HashVerifier.cryptoKit()`, `SignpostTracer`, `CompositeTracer`.

## [0.2.0]

### Added — verifier kit expansion

- `SecretsVerifier` with 21 default rules covering major cloud / SaaS credentials and PEM-style private keys.
- `PIIVerifier` with Luhn-validated credit-card detection.
- Format verifiers: `UUIDVerifier`, `ISO8601DateVerifier`, `SemVerVerifier`, `EmailVerifier`, `PhoneE164Verifier`, `HexStringVerifier`, `Base64Verifier`.
- Numeric verifiers: `NumericRangeVerifier`, `ProbabilityVerifier`, `SumVerifier`, `MonotonicVerifier<T>`.
- `SQLTokenizer` and `SQLSafetyVerifier`.
- `MarkdownStructureVerifier`.
- Content / invariant verifiers: `ProhibitedTermsVerifier`, `RequiredTermsVerifier`, `ImplicationVerifier<T>`, `UniqueElementsVerifier<T>`, `SHA256HashVerifier`.

## [0.1.0]

### Added — initial scaffold

- Six-layer framework over Apple `FoundationModels`: `CompoundSession`, `ControlLoop`, `ModelClient`, `ContextAssembler`, `Tool`/`VerifiedTool`, `Verifier`, `Tracer`, `Policy`.
- Verifier kit covering Claude Code's tool surface: edit / path / shell / diff / structure / JSON-schema / URL / process-backed compile gates.
- Hand-rolled assertion harness to run on CommandLineTools-only toolchains that lack XCTest / swift-testing.
