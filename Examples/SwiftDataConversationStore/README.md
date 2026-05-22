# SwiftData Conversation Store

A drop-in SwiftData implementation of Compound's `ConversationStore` protocol. The conversation stays on the device, in the user's hands — there is no second copy on someone else's server.

## Why it's a template, not a library file

The `@Model` macro from SwiftData requires the SwiftData compiler plugin, which is bundled with full Xcode but not with the CommandLineTools-only Swift toolchain. To keep Compound's library compilable on every toolchain (including CI runners without Xcode), persistent-model definitions are shipped as copy-paste templates rather than as library code.

## Use it

1. Copy `SwiftDataConversationStore.swift` into your app target.
2. Add `Compound` as a dependency in your Package.swift / project.
3. In your app startup:

```swift
import SwiftData
import Compound

let container = try ModelContainer(for: PersistentConversationMessage.self)
let store = SwiftDataConversationStore(container: container)

let assembler = ConversationContextAssembler(
    baseInstructions: "You are a helpful assistant.",
    store: store
)

let session = CompoundSession(.init(
    assembler: assembler,
    tracer: OSLogTracer()
))
```

4. Bind `@Query` to `PersistentConversationMessage` in your SwiftUI views for live history.

## Customizing the schema

Add fields to `PersistentConversationMessage` and update the `init(from:)` / `asConversationMessage` accessors to round-trip them. The protocol contract Compound depends on is only `ConversationStore`, so you can also swap to a different `@Model` class entirely — the example here is one way to spell it, not the only way.
