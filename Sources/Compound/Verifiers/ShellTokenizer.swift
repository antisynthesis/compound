import Foundation

/// One element of a tokenized shell command — the unit at which a command
/// stops being a string the model can disguise and becomes a structure the
/// system can interrogate.
///
/// Produced by ``ShellTokenizer/tokenize(_:)``. Verifiers reason about
/// tokens rather than raw strings so quoting tricks like
/// `'rm' "-rf" /` do not slip past head-based allowlists.
public enum ShellToken: Sendable, Equatable {
    /// A literal word or quoted string with quoting removed.
    case word(String)
    /// A shell operator: `;`, `|`, `||`, `&`, `&&`, `<`, `<<`, `>`, `>>`.
    case op(String)
}

/// Errors thrown by ``ShellTokenizer/tokenize(_:)``.
public enum ShellParseError: Error, Equatable, CustomStringConvertible {
    /// A `'`-delimited single-quoted string was not closed.
    case unterminatedSingleQuote
    /// A `"`-delimited double-quoted string was not closed.
    case unterminatedDoubleQuote
    /// The input ends with a `\` escape with nothing to escape.
    case trailingBackslash

    /// Human-readable description.
    public var description: String {
        switch self {
        case .unterminatedSingleQuote: return "unterminated single quote"
        case .unterminatedDoubleQuote: return "unterminated double quote"
        case .trailingBackslash: return "trailing backslash"
        }
    }
}

/// A surgical, POSIX-flavored shell tokenizer.
///
/// It does not pretend to be `/bin/sh` — that abstraction would be a
/// beautiful lie. Its single job is to give downstream verifiers a
/// stable, structured view of the command line so allowlists and
/// danger rules can be expressed against tokens rather than regex on
/// raw strings. Quoting and escaping behave closely enough to real
/// shells that injection attempts surface instead of disguising
/// themselves.
public enum ShellTokenizer {
    /// Tokenizes `input`.
    ///
    /// - Throws: ``ShellParseError`` on unterminated quoting or a
    ///   trailing backslash.
    public static func tokenize(_ input: String) throws -> [ShellToken] {
        var tokens: [ShellToken] = []
        var current = ""
        var hasCurrent = false
        var i = input.startIndex

        func flush() {
            if hasCurrent {
                tokens.append(.word(current))
                current = ""
                hasCurrent = false
            }
        }

        while i < input.endIndex {
            let c = input[i]
            switch c {
            case " ", "\t", "\n":
                flush()
                i = input.index(after: i)
            case "'":
                hasCurrent = true
                i = input.index(after: i)
                while i < input.endIndex && input[i] != "'" {
                    current.append(input[i])
                    i = input.index(after: i)
                }
                if i == input.endIndex { throw ShellParseError.unterminatedSingleQuote }
                i = input.index(after: i)
            case "\"":
                hasCurrent = true
                i = input.index(after: i)
                while i < input.endIndex && input[i] != "\"" {
                    if input[i] == "\\" {
                        let next = input.index(after: i)
                        if next == input.endIndex { throw ShellParseError.trailingBackslash }
                        current.append(input[next])
                        i = input.index(after: next)
                    } else {
                        current.append(input[i])
                        i = input.index(after: i)
                    }
                }
                if i == input.endIndex { throw ShellParseError.unterminatedDoubleQuote }
                i = input.index(after: i)
            case "\\":
                let next = input.index(after: i)
                if next == input.endIndex { throw ShellParseError.trailingBackslash }
                hasCurrent = true
                current.append(input[next])
                i = input.index(after: next)
            case ";":
                flush()
                tokens.append(.op(";"))
                i = input.index(after: i)
            case "|":
                flush()
                let next = input.index(after: i)
                if next < input.endIndex, input[next] == "|" {
                    tokens.append(.op("||"))
                    i = input.index(after: next)
                } else {
                    tokens.append(.op("|"))
                    i = next
                }
            case "&":
                flush()
                let next = input.index(after: i)
                if next < input.endIndex, input[next] == "&" {
                    tokens.append(.op("&&"))
                    i = input.index(after: next)
                } else {
                    tokens.append(.op("&"))
                    i = next
                }
            case ">":
                flush()
                let next = input.index(after: i)
                if next < input.endIndex, input[next] == ">" {
                    tokens.append(.op(">>"))
                    i = input.index(after: next)
                } else {
                    tokens.append(.op(">"))
                    i = next
                }
            case "<":
                flush()
                let next = input.index(after: i)
                if next < input.endIndex, input[next] == "<" {
                    tokens.append(.op("<<"))
                    i = input.index(after: next)
                } else {
                    tokens.append(.op("<"))
                    i = next
                }
            default:
                hasCurrent = true
                current.append(c)
                i = input.index(after: i)
            }
        }
        flush()
        return tokens
    }

    /// Splits a token stream into command segments. A segment is the
    /// run of tokens between sequence operators (`;`, `|`, `||`, `&&`,
    /// `&`). Redirection operators (`>`, `>>`, `<`, `<<`) stay inside
    /// their segment so danger rules can reason about them.
    public static func commands(_ tokens: [ShellToken]) -> [[ShellToken]] {
        let sequenceOperators: Set<String> = [";", "|", "||", "&&", "&"]
        var segments: [[ShellToken]] = []
        var current: [ShellToken] = []
        for token in tokens {
            if case .op(let op) = token, sequenceOperators.contains(op) {
                if !current.isEmpty {
                    segments.append(current)
                    current = []
                }
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Returns only the `.word` payloads from `tokens`, in order.
    public static func words(_ tokens: [ShellToken]) -> [String] {
        tokens.compactMap { token in
            if case .word(let w) = token { return w } else { return nil }
        }
    }

    /// Returns the "head" word of a segment — the executable name. Skips
    /// leading `VAR=value` assignments that POSIX permits in front of a
    /// command.
    public static func head(_ segment: [ShellToken]) -> String? {
        for token in segment {
            if case .word(let w) = token {
                if w.contains("=") && !w.hasPrefix("=") && Self.isAssignmentPrefix(w) {
                    continue
                }
                return w
            }
        }
        return nil
    }

    private static func isAssignmentPrefix(_ word: String) -> Bool {
        // VAR=value where VAR is [A-Za-z_][A-Za-z0-9_]*
        guard let eq = word.firstIndex(of: "=") else { return false }
        let varName = word[..<eq]
        guard let first = varName.first else { return false }
        if !(first.isLetter || first == "_") { return false }
        return varName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
