import Foundation

/// Verifies basic encoding hygiene on a string output. Swift's `String`
/// invariant already guarantees valid UTF-8, so the remaining hazards
/// are NUL bytes, replacement characters from earlier decode failures,
/// and CRLF line endings sneaking into LF-only files.
public struct EncodingVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Reject inputs containing `\0`.
    public let forbidNullBytes: Bool
    /// Reject inputs containing `U+FFFD`.
    public let forbidReplacementCharacter: Bool
    /// Reject inputs containing `\r\n` line endings.
    public let forbidCRLF: Bool

    /// Creates a verifier.
    public init(name: String = "encoding",
                forbidNullBytes: Bool = true,
                forbidReplacementCharacter: Bool = true,
                forbidCRLF: Bool = false) {
        self.name = name
        self.forbidNullBytes = forbidNullBytes
        self.forbidReplacementCharacter = forbidReplacementCharacter
        self.forbidCRLF = forbidCRLF
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        if forbidNullBytes, input.contains("\0") {
            return .repair(Diagnostic(verifier: name, message: "output contains NUL byte"))
        }
        if forbidReplacementCharacter, input.contains("\u{FFFD}") {
            return .repair(Diagnostic(
                verifier: name,
                message: "output contains Unicode replacement character",
                suggestion: "regenerate without lossy encoding"
            ))
        }
        if forbidCRLF, input.contains("\r\n") {
            return .repair(Diagnostic(
                verifier: name,
                message: "output contains CRLF line endings",
                suggestion: "use LF only"
            ))
        }
        return .pass
    }
}

/// Walks the input maintaining a bracket stack. Strings and comments
/// are skipped by default so text inside `"doesn't]"` or
/// `// ignore [me]` does not cause false positives. Cheap and one of
/// the most useful defenses against truncated code outputs.
public struct BalancedBracketsVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Map of opener to expected closer.
    public let pairs: [Character: Character]
    /// Skip content inside `"`, `'`, and backtick-delimited strings.
    public let ignoreStrings: Bool
    /// Skip content from `//` to end-of-line.
    public let ignoreLineComments: Bool
    /// Skip content between `/*` and `*/`.
    public let ignoreBlockComments: Bool

    /// Creates a verifier.
    public init(name: String = "balanced-brackets",
                pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"],
                ignoreStrings: Bool = true,
                ignoreLineComments: Bool = true,
                ignoreBlockComments: Bool = true) {
        self.name = name
        self.pairs = pairs
        self.ignoreStrings = ignoreStrings
        self.ignoreLineComments = ignoreLineComments
        self.ignoreBlockComments = ignoreBlockComments
    }

    private enum ParseState {
        case normal
        case inString(quote: Character, escaped: Bool)
        case lineComment
        case blockComment
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        var stack: [Character] = []
        let openers = Set(pairs.keys)
        let closerToOpener: [Character: Character] = Dictionary(uniqueKeysWithValues: pairs.map { ($1, $0) })
        var state: ParseState = .normal
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch state {
            case .normal:
                if ignoreStrings && (c == "\"" || c == "'" || c == "`") {
                    state = .inString(quote: c, escaped: false)
                    i += 1
                } else if ignoreLineComments, c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    state = .lineComment
                    i += 2
                } else if ignoreBlockComments, c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    state = .blockComment
                    i += 2
                } else if openers.contains(c) {
                    stack.append(c)
                    i += 1
                } else if let expectedOpener = closerToOpener[c] {
                    guard let top = stack.popLast() else {
                        return .repair(Diagnostic(verifier: name, message: "unmatched closer '\(c)'"))
                    }
                    if top != expectedOpener {
                        return .repair(Diagnostic(verifier: name, message: "expected closer for '\(top)', got '\(c)'"))
                    }
                    i += 1
                } else {
                    i += 1
                }
            case .inString(let quote, let escaped):
                if escaped {
                    state = .inString(quote: quote, escaped: false)
                    i += 1
                } else if c == "\\" {
                    state = .inString(quote: quote, escaped: true)
                    i += 1
                } else if c == quote {
                    state = .normal
                    i += 1
                } else {
                    i += 1
                }
            case .lineComment:
                if c == "\n" { state = .normal }
                i += 1
            case .blockComment:
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    state = .normal
                    i += 2
                } else {
                    i += 1
                }
            }
        }
        if case .inString = state {
            return .repair(Diagnostic(verifier: name, message: "unterminated string"))
        }
        if case .blockComment = state {
            return .repair(Diagnostic(verifier: name, message: "unterminated block comment"))
        }
        if !stack.isEmpty {
            return .repair(Diagnostic(
                verifier: name,
                message: "unclosed: \(stack.map(String.init).joined(separator: ", "))"
            ))
        }
        return .pass
    }
}

/// Enforces a min/max line count. Useful for catching cases where the
/// model decided to rewrite an entire file rather than make a targeted
/// edit.
public struct LineCountVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Minimum required line count.
    public let min: Int?
    /// Maximum permitted line count.
    public let max: Int?

    /// Creates a verifier. At least one bound must be supplied.
    public init(name: String = "line-count", min: Int? = nil, max: Int? = nil) {
        precondition(min != nil || max != nil, "LineCountVerifier needs at least one bound")
        self.name = name
        self.min = min
        self.max = max
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let count = input.split(separator: "\n", omittingEmptySubsequences: false).count
        if let min, count < min {
            return .repair(Diagnostic(verifier: name, message: "too few lines: \(count) < \(min)"))
        }
        if let max, count > max {
            return .repair(Diagnostic(verifier: name, message: "too many lines: \(count) > \(max)"))
        }
        return .pass
    }
}
