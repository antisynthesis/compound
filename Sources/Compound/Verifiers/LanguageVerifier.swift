import Foundation
import NaturalLanguage

/// Requires that model output be in a specific language (or one of a
/// set). Backed by `NLLanguageRecognizer`, which ships on every Apple
/// platform.
///
/// The ``minimumConfidence`` threshold gates on the recognizer's
/// probability — leaving it permissive (~0.5) catches outright
/// wrong-language output without false-positiving on mixed-language
/// text. Inputs shorter than ``minimumLength`` are passed unchecked
/// because the recognizer is unreliable on short fragments.
public struct LanguageVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .schema
    /// Allowed languages.
    public let allowed: Set<NLLanguage>
    /// Minimum recognizer confidence required to accept.
    public let minimumConfidence: Double
    /// Minimum input length below which the verifier auto-passes.
    public let minimumLength: Int

    /// Creates a verifier.
    public init(
        name: String = "language",
        allowed: Set<NLLanguage>,
        minimumConfidence: Double = 0.5,
        minimumLength: Int = 16
    ) {
        self.name = name
        self.allowed = allowed
        self.minimumConfidence = minimumConfidence
        self.minimumLength = minimumLength
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < minimumLength { return .pass }  // too short to judge reliably
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        for (language, confidence) in hypotheses where confidence >= minimumConfidence {
            if allowed.contains(language) { return .pass }
        }
        let best = hypotheses.max(by: { $0.value < $1.value })
        let detected = best?.key.rawValue ?? "unknown"
        let allowedList = allowed.map(\.rawValue).sorted().joined(separator: ", ")
        return .repair(Diagnostic(
            verifier: name,
            message: "output language '\(detected)' not in allow-list [\(allowedList)]",
            suggestion: "respond in \(allowedList)"
        ))
    }
}
