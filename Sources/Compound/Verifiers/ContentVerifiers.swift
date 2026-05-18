import Foundation

/// Rejects (or repairs) outputs that contain any of a list of
/// prohibited terms. Configurable for case-sensitivity and whole-word
/// matching.
public struct ProhibitedTermsVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Prohibited terms.
    public let terms: [String]
    /// `true` for case-insensitive matching.
    public let caseInsensitive: Bool
    /// Require word boundaries around each term.
    public let wholeWord: Bool
    /// Verdict kind on match.
    public let returnAs: SecretsVerifier.VerdictKind

    /// Creates a verifier.
    public init(
        name: String = "prohibited-terms",
        terms: [String],
        caseInsensitive: Bool = true,
        wholeWord: Bool = false,
        returnAs: SecretsVerifier.VerdictKind = .reject
    ) {
        self.name = name
        self.terms = terms
        self.caseInsensitive = caseInsensitive
        self.wholeWord = wholeWord
        self.returnAs = returnAs
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let haystack = caseInsensitive ? input.lowercased() : input
        var hits: [String] = []
        for raw in terms {
            let needle = caseInsensitive ? raw.lowercased() : raw
            if needle.isEmpty { continue }
            if wholeWord {
                let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: needle))\b"#
                if let regex = try? Regex(pattern), (try? regex.firstMatch(in: haystack)) != nil {
                    hits.append(raw)
                }
            } else if haystack.contains(needle) {
                hits.append(raw)
            }
        }
        if hits.isEmpty { return .pass }
        let msg = "output contains prohibited terms: \(hits.joined(separator: ", "))"
        switch returnAs {
        case .reject: return .reject(msg)
        case .repair: return .repair(Diagnostic(verifier: name, message: msg, suggestion: "rewrite without these terms"))
        }
    }
}

/// Requires the output to contain a set of terms — either every term
/// (`allRequired: true`) or at least one (`allRequired: false`).
public struct RequiredTermsVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Required terms.
    public let terms: [String]
    /// `true` for case-insensitive matching.
    public let caseInsensitive: Bool
    /// `true` requires every term, `false` requires at least one.
    public let allRequired: Bool

    /// Creates a verifier.
    public init(
        name: String = "required-terms",
        terms: [String],
        caseInsensitive: Bool = true,
        allRequired: Bool = true
    ) {
        self.name = name
        self.terms = terms
        self.caseInsensitive = caseInsensitive
        self.allRequired = allRequired
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let haystack = caseInsensitive ? input.lowercased() : input
        var missing: [String] = []
        var anyPresent = false
        for raw in terms {
            let needle = caseInsensitive ? raw.lowercased() : raw
            if haystack.contains(needle) { anyPresent = true }
            else { missing.append(raw) }
        }
        if allRequired {
            if missing.isEmpty { return .pass }
            return .repair(Diagnostic(
                verifier: name,
                message: "output is missing required terms: \(missing.joined(separator: ", "))"
            ))
        } else {
            if anyPresent { return .pass }
            return .repair(Diagnostic(
                verifier: name,
                message: "output contains none of the required terms: \(terms.joined(separator: ", "))"
            ))
        }
    }
}

/// Validates a logical implication: when `antecedent` holds,
/// `consequent` must also hold. Useful for cross-field invariants like
/// `"if status == 'closed' then closedAt != nil"` — easier to read
/// than two separate predicate verifiers wired together.
public struct ImplicationVerifier<Input: Sendable>: Verifier {
    public let name: String
    public let cost: VerifierCost
    private let antecedent: @Sendable (Input) async throws -> Bool
    private let consequent: @Sendable (Input) async throws -> Bool
    private let onViolation: String
    private let suggestion: String?

    /// Creates a verifier.
    public init(
        name: String,
        cost: VerifierCost = .parse,
        onViolation: String = "implication violated",
        suggestion: String? = nil,
        when antecedent: @escaping @Sendable (Input) async throws -> Bool,
        then consequent: @escaping @Sendable (Input) async throws -> Bool
    ) {
        self.name = name
        self.cost = cost
        self.antecedent = antecedent
        self.consequent = consequent
        self.onViolation = onViolation
        self.suggestion = suggestion
    }

    public func verify(_ input: Input, context _: RunContext) async throws -> Verdict {
        let ant = try await antecedent(input)
        if !ant { return .pass }
        let con = try await consequent(input)
        if con { return .pass }
        return .repair(Diagnostic(verifier: name, message: onViolation, suggestion: suggestion))
    }
}

/// Asserts every element of the input collection is distinct. The
/// element type must be `Hashable` so duplicates can be detected in
/// O(n).
public struct UniqueElementsVerifier<Element: Hashable & Sendable>: Verifier {
    public typealias Input = [Element]
    public let name: String
    public let cost: VerifierCost = .parse

    /// Creates a verifier.
    public init(name: String = "unique-elements") { self.name = name }

    public func verify(_ input: [Element], context _: RunContext) async throws -> Verdict {
        var seen: Set<Element> = []
        var duplicates: Set<Element> = []
        for e in input {
            if !seen.insert(e).inserted { duplicates.insert(e) }
        }
        if duplicates.isEmpty { return .pass }
        return .repair(Diagnostic(
            verifier: name,
            message: "collection has \(duplicates.count) duplicate value(s)"
        ))
    }
}

/// SHA-256 content hash check. Useful when a tool returns a payload
/// that should match a known-good fingerprint, or when the model
/// asserts a content hash whose claim must hold against the actual
/// bytes.
///
/// The digester is supplied as a closure so callers can plug in
/// CryptoKit on Apple platforms while keeping the type signature
/// portable. See ``SHA256HashVerifier+CryptoKit.swift`` for the
/// pre-wired factory.
public struct SHA256HashVerifier: Verifier {
    public typealias Input = HashCheck
    public let name: String
    public let cost: VerifierCost = .parse
    private let digester: @Sendable (Data) -> Data

    /// Pairing of `data` and the lowercase hex digest it must match.
    public struct HashCheck: Sendable {
        /// Bytes to hash.
        public let data: Data
        /// Expected hex digest (lowercased on init).
        public let expectedHex: String
        /// Creates a check.
        public init(data: Data, expectedHex: String) {
            self.data = data
            self.expectedHex = expectedHex.lowercased()
        }
    }

    /// Creates a verifier with a pluggable SHA-256 digester.
    public init(name: String = "sha256-hash", digester: @escaping @Sendable (Data) -> Data) {
        self.name = name
        self.digester = digester
    }

    public func verify(_ input: HashCheck, context _: RunContext) async throws -> Verdict {
        let actual = digester(input.data).map { String(format: "%02x", $0) }.joined()
        if actual == input.expectedHex { return .pass }
        return .reject("SHA-256 mismatch: got \(actual), expected \(input.expectedHex)")
    }
}
