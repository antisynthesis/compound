# Examples

Runnable patterns demonstrating Compound's typical wirings. Each example is a single `main.swift` file plus a brief README; none are part of the Compound library's build graph, because they use the `@Generable` macro from `FoundationModels` or the `@Model` macro from `SwiftData`, and putting those macro plugins on `swift build`'s critical path would change the library's build graph for every consumer.

They are not unchecked, though: CI type-checks every example against the built module (`xcrun swiftc -typecheck -parse-as-library -I .build/debug`), so an example that drifts out of sync with the API fails the build. That step needs full Xcode; the library itself still builds under the CommandLineTools toolchain.

To run an example, open this package in Xcode 26 on a device or simulator with Apple Intelligence enabled and add the example as a target.

## Examples

- **`CompoundExample/`** — the smallest end-to-end demo: assembler + verifier chain + tracer + a single model call.

- **`SQLAgent/`** — natural-language to read-only SQL. The model proposes; `SQLSafetyVerifier` gates by statement type, multi-statement rejection, and the `WHERE`-required rule on `UPDATE`/`DELETE`. Demonstrates schema injection via `StaticRetriever`.

- **`RAGBot/`** — grounded question-answering. A hybrid retriever (BM25 + `NLEmbedding`) finds passages, the assembler injects them with stable `[source-id]` tags, the citation verifier requires the model to ground every claim. Includes a streaming progress reporter for SwiftUI and an eval suite that locks the behavior in place across model upgrades.

- **`CodeEditAgent/`** — a Claude-Code-style edit agent. The model proposes `(path, oldString, newString)` tuples; the verifier chain checks workspace containment, deny-list (`.git`, `.env`, SSH keys), and the exact-match contract that prevents hallucinated quotations from applying.

- **`SwiftDataConversationStore/`** — drop-in SwiftData implementation of the `ConversationStore` protocol. Copy-paste into your app target.
