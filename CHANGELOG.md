# Changelog

All notable changes to this project will be documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `MetricsCollectingTracer` — aggregates `TraceEvent`s into a `MetricsSnapshot` (per-run, per-tool, per-verifier rollups with latency stats and approximate p50/p99).
- `MetricKitObserver` — iOS / macOS / visionOS bridge for Apple's MetricKit aggregated payloads.
- Apache 2.0 license, contributor guide, security policy, GitHub Actions CI workflow.

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
