import Foundation

// Small, sharp parsers for common typed identifiers. Each verifier expects
// the full input string to be one well-formed value of the format — they
// are anchored, not search-based, because "contains something that looks
// like a UUID" is the kind of loose abstraction that lets bad data through.

/// Demands a genuine UUID, not a string that resembles one.
public struct UUIDVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse

    /// Creates a verifier.
    public init(name: String = "uuid") { self.name = name }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed) != nil ? .pass : .repair(Diagnostic(
            verifier: name,
            message: "value is not a UUID",
            suggestion: "use the form xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        ))
    }
}

/// Insists a timestamp be a real moment in time, parsing as an ISO-8601
/// date under the supplied formatter options.
///
/// Marked `@unchecked Sendable` because `ISO8601DateFormatter` is
/// documented thread-safe (10.12+) but is not formally `Sendable`.
public struct ISO8601DateVerifier: Verifier, @unchecked Sendable {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Configured formatter.
    public let formatter: ISO8601DateFormatter

    /// Creates a verifier with the supplied formatter options.
    public init(name: String = "iso8601", options: ISO8601DateFormatter.Options = [.withInternetDateTime]) {
        self.name = name
        let f = ISO8601DateFormatter()
        f.formatOptions = options
        self.formatter = f
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return formatter.date(from: trimmed) != nil ? .pass : .repair(Diagnostic(
            verifier: name,
            message: "value is not a valid ISO-8601 date",
            suggestion: "use the form 2026-05-17T12:00:00Z"
        ))
    }
}

/// Holds the input to the SemVer 2.0 contract — `major.minor.patch` plus
/// optional pre-release and build metadata — permissively but precisely.
public struct SemVerVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse

    nonisolated(unsafe) private static let pattern: Regex<AnyRegexOutput> = {
        try! Regex(#"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#)
    }()

    /// Creates a verifier.
    public init(name: String = "semver") { self.name = name }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? Self.pattern.firstMatch(in: trimmed)) != nil ? .pass : .repair(Diagnostic(
            verifier: name,
            message: "value is not a SemVer 2.0 string",
            suggestion: "use major.minor.patch — e.g. 1.4.0 or 2.0.0-rc.1"
        ))
    }
}

/// Requires a well-formed email address — structure, not a guess at intent.
public struct EmailVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse

    nonisolated(unsafe) private static let pattern: Regex<AnyRegexOutput> = {
        try! Regex(#"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#)
    }()

    /// Creates a verifier.
    public init(name: String = "email") { self.name = name }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? Self.pattern.firstMatch(in: trimmed)) != nil ? .pass : .repair(Diagnostic(
            verifier: name,
            message: "value is not a well-formed email address"
        ))
    }
}

/// Holds a phone number to the E.164 standard (`+CC...`) and nothing looser.
public struct PhoneE164Verifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse

    nonisolated(unsafe) private static let pattern: Regex<AnyRegexOutput> = {
        try! Regex(#"^\+[1-9]\d{1,14}$"#)
    }()

    /// Creates a verifier.
    public init(name: String = "phone-e164") { self.name = name }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? Self.pattern.firstMatch(in: trimmed)) != nil ? .pass : .repair(Diagnostic(
            verifier: name,
            message: "value is not E.164 phone format",
            suggestion: "use +<countryCode><number> — e.g. +14155551212"
        ))
    }
}

/// Reads bytes as bytes. Validates the input as a hex string, optionally
/// with a `0x` prefix and an exact expected byte length.
public struct HexStringVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Exact required decoded byte length, or `nil` to accept any length.
    public let expectedByteLength: Int?
    /// `true` to strip a leading `0x` or `0X` before validating.
    public let allowPrefix: Bool

    /// Creates a verifier.
    public init(name: String = "hex", expectedByteLength: Int? = nil, allow0xPrefix: Bool = true) {
        self.name = name
        self.expectedByteLength = expectedByteLength
        self.allowPrefix = allow0xPrefix
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowPrefix, s.hasPrefix("0x") || s.hasPrefix("0X") {
            s = String(s.dropFirst(2))
        }
        guard !s.isEmpty, s.allSatisfy({ $0.isHexDigit }) else {
            return .repair(Diagnostic(verifier: name, message: "value is not a hex string"))
        }
        if !s.count.isMultiple(of: 2) {
            return .repair(Diagnostic(verifier: name, message: "hex string has odd length: \(s.count)"))
        }
        if let expected = expectedByteLength, s.count != expected * 2 {
            return .repair(Diagnostic(
                verifier: name,
                message: "hex string has \(s.count / 2) bytes, expected \(expected)"
            ))
        }
        return .pass
    }
}

/// Confirms the input is genuinely base64 (or base64url) encoded, alphabet
/// and padding both, not merely plausible.
public struct Base64Verifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// `true` to use the URL-safe alphabet (`-_` for `+/`).
    public let urlSafe: Bool
    /// `true` to allow `=` padding (and require length to be a multiple of 4).
    public let allowPadding: Bool

    /// Creates a verifier.
    public init(name: String = "base64", urlSafe: Bool = false, allowPadding: Bool = true) {
        self.name = name
        self.urlSafe = urlSafe
        self.allowPadding = allowPadding
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .repair(Diagnostic(verifier: name, message: "value is empty"))
        }
        let standardAlphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let urlAlphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
        let alphabet = urlSafe ? urlAlphabet : standardAlphabet
        if trimmed.rangeOfCharacter(from: alphabet.inverted) != nil {
            return .repair(Diagnostic(verifier: name, message: "value contains characters outside the base64 alphabet"))
        }
        if !allowPadding, trimmed.contains("=") {
            return .repair(Diagnostic(verifier: name, message: "value has padding but allowPadding is false"))
        }
        if allowPadding, !trimmed.count.isMultiple(of: 4) {
            return .repair(Diagnostic(verifier: name, message: "padded base64 length must be a multiple of 4"))
        }
        // Foundation decoder as a final authoritative check for the standard alphabet.
        if !urlSafe, Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) == nil {
            return .repair(Diagnostic(verifier: name, message: "Foundation rejected the base64 value"))
        }
        return .pass
    }
}
