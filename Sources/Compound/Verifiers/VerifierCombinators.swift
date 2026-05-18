import Foundation

// Combinators for composing verifiers. The most important is contramap, which
// lets a Verifier<String> (e.g. EncodingVerifier, BalancedBracketsVerifier) be
// reused on a substring of a richer input type — e.g. the newString field of a
// ProposedEdit.

extension Verifier {
    /// Adapts a `Verifier<Input>` into a `Verifier<NewInput>` by projecting
    /// the new input to the original input type. Lets a string-level
    /// verifier (e.g. ``BalancedBracketsVerifier``) gate a field of a
    /// richer record (e.g. ``ProposedEdit/newString``).
    ///
    /// - Parameters:
    ///   - newName: Optional override for the wrapped verifier's ``name``.
    ///   - project: Pure function from `NewInput` to `Input`.
    /// - Returns: A type-erased verifier over `NewInput`.
    public func contramap<NewInput: Sendable>(
        name newName: String? = nil,
        _ project: @escaping @Sendable (NewInput) -> Input
    ) -> AnyVerifier<NewInput> {
        AnyVerifier<NewInput>(
            name: newName ?? self.name,
            cost: self.cost
        ) { input, ctx in
            try await self.verify(project(input), context: ctx)
        }
    }
}
