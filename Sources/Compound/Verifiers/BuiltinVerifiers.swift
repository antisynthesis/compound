import Foundation

// A small starter kit of pure-Swift verifiers. They are not exhaustive; their
// purpose is to be useful out of the box and to model the shape that custom
// verifiers should take. None of these depend on FoundationModels — they
// operate on plain Swift values produced by the rest of the system.

/// Validates an input string against a regex. When `mustMatch` is
/// `true` (the default) the pattern must match for the verifier to
/// pass; when `false` the pattern must *not* match.
///
/// Marked `@unchecked Sendable` because `Regex<AnyRegexOutput>` is not
/// formally `Sendable`; all stored fields are immutable.
public struct RegexVerifier: Verifier, @unchecked Sendable {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Compiled regex.
    public let pattern: Regex<AnyRegexOutput>
    /// `true` requires a match; `false` requires absence of any match.
    public let mustMatch: Bool

    /// Creates a verifier by compiling `pattern`.
    public init(name: String, pattern: String, mustMatch: Bool = true) throws {
        self.name = name
        self.pattern = try Regex(pattern)
        self.mustMatch = mustMatch
    }

    /// Creates a verifier from an already-compiled regex.
    public init(name: String, pattern: Regex<AnyRegexOutput>, mustMatch: Bool = true) {
        self.name = name
        self.pattern = pattern
        self.mustMatch = mustMatch
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let hit = (try? pattern.firstMatch(in: input)) != nil
        if hit == mustMatch { return .pass }
        let msg = mustMatch ? "expected pattern not found" : "forbidden pattern matched"
        return .repair(Diagnostic(verifier: name, message: msg))
    }
}

/// Validates that an input string's character count falls within
/// optional `min`/`max` bounds.
public struct LengthVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Minimum length, in characters.
    public let min: Int?
    /// Maximum length, in characters.
    public let max: Int?

    /// Creates a verifier. At least one bound must be supplied.
    public init(name: String = "length", min: Int? = nil, max: Int? = nil) {
        precondition(min != nil || max != nil, "LengthVerifier needs at least one bound")
        self.name = name
        self.min = min
        self.max = max
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let n = input.count
        if let min, n < min {
            return .repair(Diagnostic(verifier: name, message: "output too short: \(n) < \(min)"))
        }
        if let max, n > max {
            return .repair(Diagnostic(verifier: name, message: "output too long: \(n) > \(max)"))
        }
        return .pass
    }
}

/// Validates the input parses as JSON (fragments allowed). Use
/// ``JSONSchemaVerifier`` when shape-level validation is required.
public struct JSONParseVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse

    /// Creates a verifier.
    public init(name: String = "json-parse") {
        self.name = name
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        guard let data = input.data(using: .utf8) else {
            return .repair(Diagnostic(verifier: name, message: "output is not valid UTF-8"))
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return .pass
        } catch {
            return .repair(Diagnostic(
                verifier: name,
                message: "invalid JSON: \(error.localizedDescription)",
                suggestion: "return only valid JSON with no surrounding prose"
            ))
        }
    }
}

/// Generic verifier that delegates to a `Bool`-returning closure.
/// Useful for inline checks and one-off cases.
public struct PredicateVerifier<Input: Sendable>: Verifier {
    public let name: String
    public let cost: VerifierCost
    private let predicate: @Sendable (Input) async throws -> Bool
    private let failureMessage: String
    private let suggestion: String?

    /// Creates a verifier.
    public init(
        name: String,
        cost: VerifierCost = .parse,
        suggestion: String? = nil,
        failureMessage: String = "predicate failed",
        predicate: @escaping @Sendable (Input) async throws -> Bool
    ) {
        self.name = name
        self.cost = cost
        self.suggestion = suggestion
        self.failureMessage = failureMessage
        self.predicate = predicate
    }

    public func verify(_ input: Input, context _: RunContext) async throws -> Verdict {
        if try await predicate(input) { return .pass }
        return .repair(Diagnostic(verifier: name, message: failureMessage, suggestion: suggestion))
    }
}

/// Requires the model output to cite at least one of the known source
/// IDs supplied at construction, and refuses citations of unknown IDs.
/// Pair with ``DefaultContextAssembler`` or
/// ``ConversationContextAssembler`` so the known IDs match the
/// retrieved sources.
///
/// Marked `@unchecked Sendable` because `Regex<AnyRegexOutput>` is not
/// formally `Sendable`; all stored fields are immutable.
public struct CitationVerifier: Verifier, @unchecked Sendable {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .schema
    /// Source IDs the model is permitted to cite.
    public let knownSourceIDs: Set<String>
    /// Compiled citation pattern (must capture the source ID in group 1).
    public let citationPattern: Regex<AnyRegexOutput>

    /// Creates a verifier.
    public init(
        name: String = "citation",
        knownSourceIDs: Set<String>,
        pattern: String = #"\[\s*([A-Za-z0-9_\-:]+)\s*\]"#
    ) throws {
        self.name = name
        self.knownSourceIDs = knownSourceIDs
        self.citationPattern = try Regex(pattern)
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let matches = input.matches(of: citationPattern)
        if matches.isEmpty {
            return .repair(Diagnostic(
                verifier: name,
                message: "output contains no citations",
                suggestion: "annotate every claim with a [source-id] from the provided context"
            ))
        }
        var unknown: [String] = []
        for match in matches {
            if let range = match[1].range {
                let id = String(input[range])
                if !knownSourceIDs.contains(id) {
                    unknown.append(id)
                }
            }
        }
        if !unknown.isEmpty {
            return .repair(Diagnostic(
                verifier: name,
                message: "unknown citation IDs: \(unknown.joined(separator: ", "))",
                suggestion: "only cite IDs present in the retrieved sources"
            ))
        }
        return .pass
    }
}
