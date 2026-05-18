import Foundation

/// Top-level namespace for the Compound framework. Pairs Apple's on-device
/// `SystemLanguageModel` with deterministic verifiers, typed tools, and
/// explicit governance so the system's behavior is bounded by the
/// deterministic layer rather than by the model alone.
///
/// The model proposes; the system disposes.
///
/// Compound never reaches for an external LLM API. Its stochastic core is
/// Apple's on-device model, accessed via `FoundationModels`, which keeps
/// privacy, latency, and cost under the framework's control and avoids a
/// dependency on commercial frontier-model providers.
///
/// `Compound.version` is the package's semantic version string and is the
/// only member of this namespace. Use ``CompoundSession`` for the high-level
/// API or ``ModelClient`` and ``ControlLoop`` for direct composition.
public enum Compound {
    /// Semantic version of the installed Compound package.
    public static let version = "0.1.0"
}
