# Changelog

All notable changes to this project will be documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] – 2026-08-31

Capability release: the loop can now draw several candidates and pick a winner, report how confident it is, escalate when it is not, and step down a degradation ladder when the device stops cooperating. Retrieval grew deterministic chunk ids, an upsert-correct index, a rerank stage, an iterative retrieve-assess-reformulate loop, and its own eval suite. Traces became a lossless, size-bounded, round-trippable record, and a 32-case golden suite now gates every commit. Contains breaking changes; see the migration notes at the end of this entry.

### Added

- **Best-of-N sampling.** `SamplingStrategy.bestOf(n:selection:variation:)` draws several candidates per free-form turn, scores each against the run's own `VerifierChain`, and hands one winner to the normal verdict disposition. Surfaced as `ControlLoop.sampling` and `CompoundSession.Configuration.sampling`; `.single` remains the default and is byte-for-byte the previous behavior. `.firstPassing` draws lazily and stops at the first candidate that clears the whole chain; `.weightedVerifierScore(weights:)` draws all `n` and takes the highest weighted fraction of members satisfied. A candidate drawing `reject`/`escalate` is disqualified and skipped while any candidate survives; the run fails terminally only when every candidate is disqualified. Per-sample variation lands via `GenerationOptions.varied(forSample:by:)` (an ascending temperature ladder by default, `.fixed` to opt out, `seedBase` to make a whole draw reproducible).
- **Agreement-rate confidence.** `AgreementRate` computes a deterministic, off-device mean pairwise token-overlap Jaccard across candidates, exposed as `LoopOutcome.confidence` / `TypedRunOutcome.confidence` and as the `TraceEvent.bestOfNSampled` event (candidate count, per-candidate scores, agreement, winning index).
- **Confidence cascade router.** `RoutingPolicy` + `EscalationStep` re-run a low-confidence turn at successively higher rungs — more samples, a different `SelectionPolicy` or `SampleVariation`, `collectAll` mode, extra verifiers — through `session.respondRouted(to:)`. Bounded by the ladder's length; the returned `RoutedOutcome` carries `confidence`, `appliedSteps`, and a `lowConfidence` flag telling callers when to defer to a human.
- **Degradation ladder.** `DegradedMode` (`full` → `reducedContext` → `noTools` → `deterministicOnly`, cumulative) driven by a `HealthMonitor` actor running one circuit breaker per typed failure class — guardrail violations, deadline/stall caps, model unavailability, context pressure — with configurable thresholds, an injected-clock cooldown, and half-open probes. `CompoundSession` applies the rung before every run (squeezing the assembled prompt, withholding the tool registry, or refusing the model call with `CompoundError.degraded(mode:reason:)` / a caller-supplied `degradedFallback`) and reports each run's typed outcome back. Manual override and inspection via `currentDegradedMode()`, `healthAssessment()`, `setDegradedMode(_:)`.
- **Iterative (agentic) RAG.** `IterativeRetrievalAssembler` is a `ContextAssembler` running a controller-owned retrieve → assess → reformulate → re-retrieve loop, bounded by round count, per-round top-k, an optional accumulated-source cap, and a wall-clock deadline. Evidence is deduped by chunk id (best rank and best score win) and ordered by interleaved rank, because scores from different queries are not comparable. Final assembly is delegated to an inner assembler built over the gathered evidence, so redaction, policy, prompt fencing, and token budgeting all still apply. `gatherEvidence(for:runContext:)` exposes the whole trajectory (`Evidence`, `Round`, `StopReason`) so the loop is testable without parsing trace strings.
- **Sufficiency and reformulation seams.** `SufficiencyAssessing` / `QueryReformulating` with deterministic, off-device defaults — `TermCoverageAssessor` (content-term coverage with a score floor and minimum-evidence check) and `MissingAspectReformulator` (narrows to the uncovered aspects, keeping bounded anchors only when they change the query's term bag) — plus `AlwaysSufficientAssessor` as the single-round control and thin model-backed `ModelSufficiencyAssessor` / `ModelQueryReformulator` conformers with per-call deadlines, fenced prompt builders, and fail-safe fallbacks.
- **Rerank stage.** `LexicalProximityReranker` — deterministic and on-device, scoring query-term coverage, minimal-window proximity, and an exact-phrase bonus — and `ModelReranker`, batched and deadline-capped behind an injectable scorer seam, falling back to first-stage order on any failure and rethrowing cancellation. Its guided-generation adapter (`guidedScorer`) is generic over the caller's `@Generable` rating type so the library still builds without the macro plugin. `HybridRetriever` gained `reranker` and `rerankCandidateMultiplier` (default 3): it widens the per-member fetch, fuses to `limit × multiplier`, reranks, then truncates.
- **Deterministic chunk ids.** `DocumentChunker.chunkID(documentID:ordinal:content:)` derives a 32-hex-character id from a domain-separated, length-prefixed SHA256 over NFC-normalized document id, ordinal, and content, so a document chunks identically across processes and machines. `DocumentChunk.init` uses it whenever an explicit `id` is not supplied.
- **Retriever lifecycle surface.** `BM25Retriever` and `DenseRetriever` gained `remove(id:)`, `remove(ids:)`, `removeAll()`, and `contains(id:)`; BM25 also exposes `averageDocumentLength` and `documentFrequency(of:)`.
- **Retrieval evals.** `RetrievalMetrics` (recall@k, precision@k, graded nDCG@k, reciprocal rank — each returning `nil` when the metric is *undefined* for the query rather than a misleading zero) plus `RetrievalScores`; `RetrievalEvalCase` / `RetrievalEvalSuite` / `RetrievalEvalRunner` scoring any `Retriever` against graded ground truth keyed by deterministic chunk ids into a Codable `RetrievalEvalReport` with derived and tag-sliced aggregates; and `RetrievalRobustness` — near-duplicate distractor generation, rank stability (overlap, top-rank retention, max displacement, Kendall's tau), and `RetrievalEvalReport.abstention(scoreFloor:)` for queries whose corpus holds no answer.
- **Golden eval suite and CI gate.** 32 deterministic golden cases replay loop repair, every budget-exhaustion kind, model-error classification, shell/SQL/secret gate red-team samples (with positive controls), redaction and prompt framing, and typed reason-then-extract — entirely off-device against fakes. `GoldenGateTests` runs them, normalizes the report via the new `EvalReport.normalizedForBaseline()`, and gates against the committed `Evals/baseline.json`; regenerate deliberately with `REGENERATE_EVAL_BASELINE=1 swift test --filter GoldenGate`. CI gained a job type-checking all `Examples/` sources against the built module and an informational API-breakage diff against the latest tag.
- **Trace round-trip and rotation.** `TraceEvent` is now `Codable`; `TraceRecord` pairs an event with the instant it was emitted; `JSONLTracer` writes the full event losslessly under a stable `type` discriminator (durations as nanoseconds) instead of a lossy flattened summary that dropped `Budget` and collapsed `Verdict`. New `TraceReader` decodes a file — or a rotated set, oldest-first — back into `[TraceRecord]`, skipping and counting corrupt lines rather than throwing, and decoding unrecognized `type`s as `.unknown` so an older consumer can still read a newer run. `JSONLTracer` is size-bounded by `maxFileBytes` (default 8 MiB) and `maxFiles` (default 4).
- **New trace events**: `bestOfNSampled`, `breakerTransitioned` (`health.breaker`), `degradationApplied` (`health.degraded`), `routingEscalated` (`routing.escalated`), `retrievalRound` (`retrieval.round`), and `retrievalLoopEnded` (`retrieval.loop_ended`) — all fully Codable and redaction-safe, with matching (defaulted) `TraceEventVisitor` methods.
- **Sample budget dimension.** `BudgetUsage.samples` counts every drawn candidate and `Budget.maxSamples` caps the multiplied model-call cost `bestOf(n:)` introduces. Single-candidate runs never debit it; output tokens are still recorded for discarded candidates.
- `BackgroundActivityCompletion`, a `BackgroundDeferralSource` seam (with `NullDeferralSource`), and a `deferralPollInterval` parameter on `scheduleAsBackgroundActivity` (default 200 ms), so background deferral and cancellation are testable off-device with a fake scheduler.

### Changed

- `RedactingTracer` now redacts **structurally** — encode, scrub every string in the JSON tree, decode — rather than by enumerating cases, so a newly added `TraceEvent` case cannot bypass redaction by omission. It consequently scrubs strictly more than before, including `.unknown` payload *keys* and the `.unknown` label. Only four load-bearing identifier keys pass through (`type`, `run`, `kind`, `ts`), joined by the enum-raw-value keys `signal`, `from`, `to`, `mode`. An event that fails the encode/scrub/decode round-trip is withheld and replaced by `.unknown(label: "trace.redaction_failed", payload: [:])`.
- `SignpostTracer` emits real `os_signpost` begin/end **intervals** for runs, model turns, and tool invocations under deterministic IDs derived from the run UUID, so Instruments can profile durations instead of showing isolated points.
- `BM25Retriever.index(_:)` and `DenseRetriever.index(_:)` are now true upserts: re-indexing an id retracts the superseded posting's contribution before applying the new one, so document frequency and average document length are exactly as if only the current version had ever been indexed. `BM25Retriever.init(chunks:)` dedupes a corpus containing repeated ids (last occurrence wins).
- Both retrievers now break score ties by chunk id ascending, so ranking is a function of corpus contents rather than of insertion order or `sort`'s unspecified behavior on equal elements.
- `HybridRetriever` RRF fusion credits a repeated id only once per member retriever, at its best rank, so a retriever returning duplicates cannot outvote genuine cross-retriever agreement. `k` is documented and required to be non-negative; `retrieve` returns empty for a non-positive `limit` instead of trapping, and candidate-depth arithmetic saturates rather than overflowing.
- The macOS `BackgroundCompoundActivity` path now honors the same cancellation contract as iOS: the work `Task` is held and cancelled when `NSBackgroundActivityScheduler` asks the activity to defer (or is invalidated and released), and the completion handler reports `.deferred`. Both platform paths funnel through one shared `runToCompletion()` core.
- Best-of-N deliberately ignores `VerifierChain.Mode.shortCircuit` and evaluates every member, because a short-circuiting chain scores every failing candidate identically and would silently degenerate to "pick the first one". This is a real cost increase for short-circuit chains and is documented on the method.
- `IterativeRetrievalAssembler` traces rounds and stop reasons through the typed `retrieval.round` / `retrieval.loop_ended` events instead of free-form `.info` messages; queries are still flattened and length-capped before reaching a log line.

### Fixed

- **BM25 statistics were permanently skewed by removal**: the average-document-length recomputation ran before the document was removed from the array, so the mean was divided by a count that still included it and was never corrected. Length normalization now returns to a never-indexed state after `remove`.
- **`DenseRetriever` kept stale entries**: re-indexing an existing id with content that embeds to a zero-norm vector skipped the degenerate vector and left the old entry alive. It now removes the entry.
- **A latent iOS background race**: a `BGTask` expiration landing before the work `Task` was registered was silently dropped. `WorkBox` now remembers a `cancel()` that arrives before `set(_:)` and applies it on registration, cancelling at most once.
- `Budget.init(from:)` validates rather than preconditions, so a corrupt or hostile trace file throws a `DecodingError` instead of trapping the process.
- `JSONLTracer.close()` nils its handle; writes after close are dropped and logged instead of failing the write path.

### Migration notes

- **JSONL trace files are not backward-readable.** Lines are now the full event plus `ts` (epoch seconds, `Double`) keyed by a stable `type` discriminator, replacing the old `label` plus lossy flat `payload` string map. Files written by ≤ 0.4.0 are counted as skipped lines by `TraceReader`. `JSONLTracer` also rotates by default (`maxFileBytes` 8 MiB, `maxFiles` 4), so long-lived deployments will see `<file>.1`…`.3` archives and eventual discard of the oldest generation. Both new init parameters are defaulted; call sites are source-compatible.
- **Chunk ids are no longer random.** `DocumentChunk.init`'s `id` parameter changed from `id: String = UUID().uuidString` to `id: String? = nil`. Every existing call still compiles, but the default id is now derived from `documentID + ordinal + content`. Any persisted index, cache, or ground-truth file keyed on previously generated UUID chunk ids will not join against newly chunked documents — re-chunk and re-index, or pass explicit ids.
- **Indexing is now an upsert.** Callers that relied on `index(_:)` appending a duplicate posting for an already-present id will see counts and scores change. Tied results now come back in chunk-id order rather than whatever `sort` happened to leave.
- **New enum cases.** Exhaustive switches must add arms for: `CompoundError.degraded(mode:reason:)`; `BudgetExhaustion.samples`; and `TraceEvent` `.bestOfNSampled`, `.breakerTransitioned`, `.degradationApplied`, `.routingEscalated`, `.retrievalRound`, `.retrievalLoopEnded`. `TraceEventVisitor` adopters and consumers with a `default:` arm are unaffected — the visitor's new methods carry no-op defaults.
- **New protocol conformances.** `TraceEvent` is now `Equatable, Codable`, and `Verdict`, `Diagnostic`, `SourceRange`, `VerifierCost`, `Budget`, `BudgetUsage`, `BudgetExhaustion` are now `Codable`. These are additive but collide with any retroactive conformance an adopter declared.
- **Redaction scrubs more.** `RedactingTracer` now scrubs every string in every case, including free-form payload keys and labels, not just the reject reasons, diagnostic messages, and tool names it enumerated before. Downstream consumers that pattern-matched on unredacted text in a case with no previous redaction arm will now see placeholders.
- **`Reranker`, `IdentityReranker`, and `RerankingRetriever` moved** from the tail of `Context/HybridRetriever.swift` into the new `Context/Reranker.swift`. Same module, so this is source-compatible for every caller — but a branch that also edits the tail of `HybridRetriever.swift` will conflict there.
- **Rerankers replace `RetrievedSource.score`** with the rerank score. A fused RRF score and a relevance score are not comparable, and `TokenBudgetedAssembler` drops by score, so leaving the stale first-stage value would silently mis-budget.
- **Struct fields added.** `LoopOutcome` and `TypedRunOutcome` each gained `confidence: Double?`; both have internal memberwise inits and are constructed only inside `ControlLoop.swift`, so no out-of-module call site breaks. `CompoundSession.Configuration.init` gained four trailing defaulted parameters (`health`, `routing`, `degradedFallback`, `reducedContextFactor`) after `makeModel`; all existing labeled call sites compile unchanged.
- **Signpost intervals.** `SignpostTracer` now emits begin/end intervals rather than point events. Instruments traces recorded against an older build are not comparable.
- **`.firstPassing` usually reports no confidence.** Stopping after one candidate leaves no pair to compare, so `agreement` is `nil`. `.weightedVerifierScore()` is the default for `bestOf(n:)` for exactly that reason; callers who need the confidence signal on every turn must not use `.firstPassing`. Streaming does not sample at all, and the typed loop samples only its reasoning phase, so `TypedRunOutcome.confidence` is `nil` for every `.direct` run.

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
- MIT license, contributor guide, security policy, GitHub Actions CI workflow.

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
