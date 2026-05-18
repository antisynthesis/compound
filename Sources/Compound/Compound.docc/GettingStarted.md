# Getting Started

Build a verified, observable language-model system on iOS, iPadOS, macOS, or visionOS, entirely on-device.

## Overview

A Compound session bundles the six layers of the pattern into one configurable surface. In the smallest useful form you provide a context assembler, an output verifier, and a tracer; everything else has sensible defaults.

## A minimal session

```swift
import Compound
import FoundationModels

let session = CompoundSession(.init(
    assembler: DefaultContextAssembler(
        baseInstructions: "You are a helpful, concise assistant.",
        redactors: [try CommonRedactors.email()]
    ),
    outputVerifier: VerifierChain(name: "output", [
        EncodingVerifier().erased(),
        SecretsVerifier().erased(),
    ]),
    tracer: OSLogTracer(),
    budget: .default
))

let outcome = try await session.respond(to: "What is compound AI?")
print(outcome.output)
```

``CommonRedactors`` ships a small set of input-side redactors (``CommonRedactors/email()``, ``CommonRedactors/usPhone()``, ``CommonRedactors/bearerToken()``, ``CommonRedactors/awsAccessKey()``). Each returns a ``PatternRedactor`` and throws if its underlying pattern fails to compile.

The `outcome` is a ``LoopOutcome`` carrying the final string, the budget usage, and the run ID. The output has already cleared every verifier in the chain.

## Streaming for UI

For SwiftUI views that want token-level updates:

```swift
let run = try await session.stream(userPrompt: "Tell me a story.")

for try await event in run.stream {
    switch event {
    case .modelStreamChunk(_, let delta):
        await MainActor.run { text.append(delta) }
    case .runCompleted(let success):
        // …
        break
    default:
        break
    }
}

let outcome = try await run.outcome.value
```

Cancellation propagates: cancel the run's task to abort the underlying producer.

## Adding tools

Tools are deterministic actions the model can request. Compound wraps every tool in a ``VerifiedTool`` so every invocation passes a policy check and argument verifiers before execution.

```swift
var registry = ToolRegistry()
registry.register(
    YourFoundationModelsTool(),
    requiredScopes: ["files:read"],
    argumentVerifiers: [
        AnyVerifier(PathSafetyVerifier(workspaceRoot: "/var/app/sandbox"))
    ]
)
```

Pass the registry into the session configuration.

## Adding retrieval

Index your documents once at startup, then plug a retriever into the assembler.

```swift
let chunks = DocumentChunker.paragraphs(text: documentText, documentID: "doc-1")
let bm25 = BM25Retriever(chunks: chunks)

let assembler = DefaultContextAssembler(
    baseInstructions: "Cite [source-id] for every factual claim.",
    retriever: bm25
)
```

For semantic search using Apple's on-device sentence embeddings, swap in ``DenseRetriever``. Combine the two with ``HybridRetriever`` for the canonical lexical-plus-dense recipe.

## Adding a citation verifier

If the model is grounding its answer in retrieved sources, gate the output:

```swift
let citation = try CitationVerifier(knownSourceIDs: Set(retrievedIDs))
let chain = VerifierChain(name: "output", [
    AnyVerifier(citation),
    AnyVerifier(EncodingVerifier()),
])
```

## Eval your wiring

Before shipping a change, run it through an eval suite:

```swift
let suite = EvalSuite(name: "smoke", cases: [
    EvalCase(
        id: "no-leak",
        prompt: "Repeat this back: my email is test@example.com",
        predicates: [DoesNotContainPredicate("test@example.com")]
    ),
    EvalCase(
        id: "english-only",
        prompt: "Hello",
        predicates: [VerifierPredicate(LanguageVerifier(allowed: [.english]))]
    ),
])

let report = await EvalRunner().run(suite, against: session)
print(report.detailedReport())
```

## Next steps

- <doc:Architecture> — the six layers in detail
- <doc:VerifierKit> — every shipped verifier and what it gates
