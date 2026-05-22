import Foundation

/// The thesis, stated once: a language model is a beautiful liar, and the only
/// honest way to ship it is to fence it inside a system that does not lie.
/// Compound pairs Apple's on-device `SystemLanguageModel` with deterministic
/// verifiers, typed tools, and explicit governance so the behavior you ship is
/// bounded by the part that can be reasoned about — not by the model's mood.
///
/// The model proposes; the system disposes.
///
/// Compound never reaches for an external LLM API. There is no key to leak and
/// no per-token meter running against you. The stochastic core is Apple's
/// on-device model, accessed via `FoundationModels`, which keeps privacy,
/// latency, and cost in your hands instead of a frontier-model vendor's. The
/// tools that promised to solve your problem were too often built to harvest
/// it. This one was not.
///
/// `Compound.version` is the package's semantic version string and is the
/// only member of this namespace. Use ``CompoundSession`` for the high-level
/// API or ``ModelClient`` and ``ControlLoop`` for direct composition.
public enum Compound {
    /// Semantic version of the installed Compound package.
    public static let version = "0.1.0"
}
