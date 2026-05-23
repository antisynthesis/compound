# ``Compound``

Build production compound AI systems in Swift over Apple's on-device language model.

## Overview

A language model is a beautiful liar — fluent, confident, wrong on its own schedule. The Compound AI Systems pattern is the architectural admission of that: a stochastic component (the model) wired into a constellation of deterministic components (retrievers, verifiers, typed tools, observability, governance) so that overall system behavior is governed by the part that does not lie. The model proposes; the system disposes. Quality, safety, and auditability come from the composition. They are not extracted from the model in isolation.

Compound implements that pattern as a Swift package targeting Apple platforms. The stochastic core is Apple's on-device `SystemLanguageModel`, accessed through `FoundationModels`. There is no external LLM dependency, no API key to leak, no per-token meter ticking against you, no third party reading over your user's shoulder.

## Topics

### Getting started

- <doc:GettingStarted>
- <doc:Architecture>
- <doc:SecurityModel>
- <doc:ObservabilityModel>

### Core types

- ``CompoundSession``
- ``ControlLoop``
- ``StreamingControlLoop``
- ``LoopOutcome``
- ``StreamingLoopOutcome``
- ``ModelClient``
- ``ModelResponding``
- ``ModelStreaming``
- ``ModelStreamResult``
- ``RunContext``
- ``Budget``
- ``BudgetUsage``
- ``BudgetExhaustion``
- ``CompoundError``
- ``CompoundError/Severity``
- ``CompoundError/Layer``
- ``EmbeddingError``

### Context assembly

- ``ContextAssembler``
- ``DefaultContextAssembler``
- ``ConversationContextAssembler``
- ``TokenBudgetedAssembler``
- ``Retriever``
- ``BM25Retriever``
- ``DenseRetriever``
- ``HybridRetriever``
- ``Reranker``
- ``RerankingRetriever``
- ``DocumentChunker``
- ``Redactor``
- ``PatternRedactor``
- ``CompositeRedactor``
- ``CommonRedactors``

### Tools

- ``VerifiedTool``
- ``ToolRegistry``
- ``ToolRegistration``
- ``GenericToolRegistration``
- ``CalculatorTool``
- ``SearchTool``
- ``WebFetchTool``
- ``HostResolver``
- ``SystemHostResolver``
- ``KVStoreTool``
- ``KVStoreBackend``
- ``InMemoryKVStoreBackend``
- ``SharedKVStoreBackend``
- ``KVStoreToolRegistration``

### Verifiers

- <doc:VerifierKit>
- ``Verifier``
- ``VerifierChain``
- ``Verdict``
- ``Diagnostic``
- ``VerifierCost``
- ``AnyVerifier``

### Streaming and progress

- ``ProgressEvent``
- ``ProgressReporter``
- ``StreamingProgressReporter``
- ``RecordingProgressReporter``
- ``NullProgressReporter``

### Observability

- ``Tracer``
- ``TraceEvent``
- ``TraceEventVisitor``
- ``NullTracer``
- ``InMemoryTracer``
- ``OSLogTracer``
- ``OSLogTracer/PrivacyLevel``
- ``JSONLTracer``
- ``JSONLTracer/FlushPolicy``
- ``SignpostTracer``
- ``CompositeTracer``
- ``RedactingTracer``
- ``MetricsCollectingTracer``
- ``MetricsSnapshot``

### Governance

- ``Policy``
- ``AuthContext``
- ``ScopeRequirement``
- ``CompositePolicy``
- ``PolicyDecision``

### Conversation

- ``ConversationMessage``
- ``ConversationStore``
- ``InMemoryConversationStore``
- ``JSONLConversationStore``
- ``ConversationSummarizer``
- ``TruncatingSummarizer``

### Prompts

- ``PromptTemplate``
- ``PromptRegistry``
- ``PromptError``

### Evaluation

- ``EvalCase``
- ``EvalSuite``
- ``EvalRunner``
- ``EvalReport``
- ``EvalPredicate``
- ``EvalTarget``
- ``ContainsPredicate``
- ``MatchesRegexPredicate``
- ``VerifierPredicate``

### Reliability

- ``RetryPolicy``
- ``Retry``
- ``RetryClassifier``
- ``DefaultRetryClassifier``
