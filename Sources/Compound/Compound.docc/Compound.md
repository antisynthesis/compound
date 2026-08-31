# ``Compound``

Build production compound AI systems in Swift over Apple's on-device language model.

## Overview

The Compound AI Systems pattern composes a stochastic component (a large language model) with a constellation of deterministic components (retrievers, verifiers, typed tools, observability, governance) such that overall system behavior is governed by the deterministic layer rather than by the model alone. The pattern treats the model as a powerful but unreliable proposer and treats the surrounding system as the authoritative disposer. Quality, safety, and auditability arise from the composition; they are not extracted from the model in isolation.

Compound implements that pattern as a Swift package targeting Apple platforms. The stochastic core is Apple's on-device `SystemLanguageModel`, accessed through `FoundationModels`. There is no external LLM dependency, no API key, and no per-token cost.

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
- ``TypedRunOutcome``
- ``SamplingStrategy``
- ``SelectionPolicy``
- ``SampleVariation``
- ``SampledCandidate``
- ``BestOfNDraw``
- ``AgreementRate``
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
- ``IdentityReranker``
- ``LexicalProximityReranker``
- ``ModelReranker``
- ``RerankingRetriever``
- ``IterativeRetrievalAssembler``
- ``SufficiencyVerdict``
- ``SufficiencyAssessing``
- ``AlwaysSufficientAssessor``
- ``TermCoverageAssessor``
- ``ModelSufficiencyAssessor``
- ``QueryReformulating``
- ``MissingAspectReformulator``
- ``ModelQueryReformulator``
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
- ``TraceRecord``
- ``TraceReader``
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

### Reliability under load

- ``DegradedMode``
- ``DegradationSignal``
- ``DegradationPolicy``
- ``BreakerState``
- ``HealthMonitor``
- ``HealthAssessment``
- ``RoutingPolicy``
- ``EscalationStep``
- ``RoutedOutcome``

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
- ``EvalGate``
- ``RetrievalMetrics``
- ``RetrievalScores``
- ``RetrievalEvalCase``
- ``RetrievalEvalSuite``
- ``RetrievalEvalRunner``
- ``RetrievalEvalReport``
- ``RetrievalRobustness``
- ``RankStability``

### Reliability

- ``RetryPolicy``
- ``Retry``
- ``RetryClassifier``
- ``DefaultRetryClassifier``
