import Foundation

/// Scans model output for common PII patterns.
///
/// Credit-card matches are Luhn-validated to keep false positives
/// down — random 16-digit strings rarely satisfy the checksum. Other
/// categories are regex-only; tune ``categories`` per use case.
///
/// All quantifiers are bounded (`{n,m}`, not `{n,}`) to keep the regex
/// engine on a linear path. Inputs above ``inputSizeLimit`` are
/// rejected outright.
public struct PIIVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Active categories.
    public let categories: Set<Category>
    /// Verdict kind returned on match.
    public let returnAs: SecretsVerifier.VerdictKind
    /// Maximum input size (bytes) the verifier scans.
    public let inputSizeLimit: Int

    /// 1 MiB. See ``SecretsVerifier/defaultInputSizeLimit``.
    public static let defaultInputSizeLimit: Int = 1 << 20

    /// PII categories the verifier can detect.
    public enum Category: String, Sendable, Hashable, CaseIterable {
        /// US Social Security Number (3-2-4 with dummy ranges excluded).
        case ssn
        /// Luhn-valid credit card number.
        case creditCard
        /// Email address.
        case email
        /// US-shaped phone number.
        case phoneUS
        /// IPv4 address.
        case ipv4
    }

    /// Creates a verifier.
    public init(name: String = "pii",
                categories: Set<Category> = Set(Category.allCases),
                returnAs: SecretsVerifier.VerdictKind = .repair,
                inputSizeLimit: Int = PIIVerifier.defaultInputSizeLimit) {
        self.name = name
        self.categories = categories
        self.returnAs = returnAs
        self.inputSizeLimit = inputSizeLimit
    }

    nonisolated(unsafe) private static let ssnPattern: Regex<AnyRegexOutput> = {
        // 3-2-4 with optional dashes/spaces; exclude obvious dummy ranges (000-, 666-, 9xx-).
        try! Regex(#"\b(?!000|666|9\d\d)\d{3}[- ]?(?!00)\d{2}[- ]?(?!0000)\d{4}\b"#)
    }()
    nonisolated(unsafe) private static let creditCardPattern: Regex<AnyRegexOutput> = {
        // Bounded run of digits with optional separators. Upper bound of
        // 19 + 18 separators = 37 keeps the engine on a linear path.
        try! Regex(#"\b(?:\d[ -]?){13,19}\b"#)
    }()
    nonisolated(unsafe) private static let emailPattern: Regex<AnyRegexOutput> = {
        // Bounded local-part and domain pieces so a long pathological
        // input can't drive the engine into a slow path.
        try! Regex(#"\b[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,253}\.[A-Za-z]{2,24}\b"#)
    }()
    nonisolated(unsafe) private static let phonePattern: Regex<AnyRegexOutput> = {
        try! Regex(#"(?:\+?1[\s\-.]?)?\(?\b[2-9][0-8]\d\)?[\s\-.]?[2-9]\d{2}[\s\-.]?\d{4}\b"#)
    }()
    nonisolated(unsafe) private static let ipv4Pattern: Regex<AnyRegexOutput> = {
        try! Regex(#"\b(?:(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\b"#)
    }()

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        if input.utf8.count > inputSizeLimit {
            return .reject("input too large to scan safely (\(input.utf8.count) bytes > \(inputSizeLimit))")
        }
        var hits: [String] = []
        if categories.contains(.ssn), (try? Self.ssnPattern.firstMatch(in: input)) != nil {
            hits.append("SSN")
        }
        if categories.contains(.creditCard) {
            for match in input.matches(of: Self.creditCardPattern) {
                let raw = String(input[match.range])
                let digits = raw.filter(\.isNumber)
                if Self.luhnValid(digits) {
                    hits.append("credit-card")
                    break
                }
            }
        }
        if categories.contains(.email), (try? Self.emailPattern.firstMatch(in: input)) != nil {
            hits.append("email")
        }
        if categories.contains(.phoneUS), (try? Self.phonePattern.firstMatch(in: input)) != nil {
            hits.append("phone")
        }
        if categories.contains(.ipv4), (try? Self.ipv4Pattern.firstMatch(in: input)) != nil {
            hits.append("ipv4")
        }
        if hits.isEmpty { return .pass }
        let msg = "output contains PII-like content: \(hits.joined(separator: ", "))"
        switch returnAs {
        case .repair: return .repair(Diagnostic(verifier: name, message: msg, suggestion: "redact or replace with placeholders"))
        case .reject: return .reject(msg)
        }
    }

    static func luhnValid(_ digits: String) -> Bool {
        let ds = digits.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(ds.count) else { return false }
        var sum = 0
        for (i, d) in ds.reversed().enumerated() {
            if i.isMultiple(of: 2) {
                sum += d
            } else {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }
}
