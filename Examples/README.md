# Examples

Runnable patterns demonstrating Compound's typical wirings. Each example is a single `main.swift` file plus a brief README; none are part of the Compound library's build graph because they use the `@Generable` macro from `FoundationModels` or the `@Model` macro from `SwiftData`, both of which require compiler plugins that ship only with full Xcode (not with the CommandLineTools toolchain CI uses).

To run an example, open this package in Xcode 26 on a device or simulator with Apple Intelligence enabled and add the example as a target.

## Examples

- **`CompoundExample/`** — the smallest end-to-end demo: assembler + verifier chain + tracer + a single model call.

- **`SQLAgent/`** — natural-language to read-only SQL. The model proposes; `SQLSafetyVerifier` gates by statement type, multi-statement rejection, and the `WHERE`-required rule on `UPDATE`/`DELETE`. Demonstrates schema injection via `StaticRetriever`.

- **`RAGBot/`** — grounded question-answering. A hybrid retriever (BM25 + `NLEmbedding`) finds passages, the assembler injects them with stable `[source-id]` tags, the citation verifier requires the model to ground every claim. Includes a streaming progress reporter for SwiftUI and an eval suite that locks the behavior in place across model upgrades.

- **`CodeEditAgent/`** — a Claude-Code-style edit agent. The model proposes `(path, oldString, newString)` tuples; the verifier chain checks workspace containment, deny-list (`.git`, `.env`, SSH keys), and the exact-match contract that prevents hallucinated quotations from applying.

- **`SwiftDataConversationStore/`** — drop-in SwiftData implementation of the `ConversationStore` protocol. Copy-paste into your app target.
