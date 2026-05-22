import Foundation

/// Top-level SQL statement classification produced by ``SQLTokenizer/classify(_:)``.
public enum SQLStatementKind: String, Sendable, Hashable, CaseIterable {
    case select, insert, update, delete
    case create, alter, drop, truncate
    case grant, revoke
    case explain, with, set, begin, commit, rollback
    /// Could not be classified.
    case unknown
}

/// The gate between a model's fluent SQL and your production database.
/// Text-to-SQL is a beautiful liar's favorite trick — a confident query
/// that drops a table it was never meant to touch. This refuses to take
/// the statement on faith.
///
/// The internal tokenizer recognizes strings, identifiers, keywords,
/// comments, and statement terminators well enough to classify each
/// top-level statement and to scan for guard clauses (the `WHERE`
/// keyword on `UPDATE`/`DELETE`). Not a full SQL parser; this verifier
/// catches the dangerous cases the design doc calls out — multiple
/// statements, DDL outside the allow-list, destructive verbs without
/// bounding clauses.
public struct SQLSafetyVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Statement kinds permitted to appear in input.
    public let allowedStatements: Set<SQLStatementKind>
    /// When `false`, more than one terminated statement causes a reject.
    public let allowMultipleStatements: Bool
    /// Reject `UPDATE` statements without a `WHERE` clause.
    public let requireWhereOnUpdate: Bool
    /// Reject `DELETE` statements without a `WHERE` clause.
    public let requireWhereOnDelete: Bool

    /// Creates a verifier.
    public init(
        name: String = "sql-safety",
        allowedStatements: Set<SQLStatementKind> = [.select, .with, .explain],
        allowMultipleStatements: Bool = false,
        requireWhereOnUpdate: Bool = true,
        requireWhereOnDelete: Bool = true
    ) {
        self.name = name
        self.allowedStatements = allowedStatements
        self.allowMultipleStatements = allowMultipleStatements
        self.requireWhereOnUpdate = requireWhereOnUpdate
        self.requireWhereOnDelete = requireWhereOnDelete
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let tokens: [SQLToken]
        do {
            tokens = try SQLTokenizer.tokenize(input)
        } catch {
            return .reject("malformed SQL: \(error)")
        }
        let statements = SQLTokenizer.statements(tokens)
        if statements.isEmpty {
            return .reject("empty SQL input")
        }
        if !allowMultipleStatements, statements.count > 1 {
            return .reject("multiple SQL statements not allowed (\(statements.count) seen)")
        }
        for stmt in statements {
            let kind = SQLTokenizer.classify(stmt)
            if !allowedStatements.contains(kind) {
                return .reject("SQL statement '\(kind.rawValue)' is not in the allow-list \(allowedStatements.map(\.rawValue).sorted())")
            }
            if kind == .update, requireWhereOnUpdate, !SQLTokenizer.containsKeyword("where", in: stmt) {
                return .reject("UPDATE without WHERE")
            }
            if kind == .delete, requireWhereOnDelete, !SQLTokenizer.containsKeyword("where", in: stmt) {
                return .reject("DELETE without WHERE")
            }
        }
        return .pass
    }
}

/// One token of an SQL statement.
public enum SQLToken: Sendable, Equatable {
    /// A reserved word, lowercased.
    case keyword(String)
    /// An identifier, original case preserved.
    case identifier(String)
    /// A numeric literal.
    case number(String)
    /// A string literal with surrounding quotes removed.
    case string(String)
    /// Operator or punctuation that is not a statement terminator.
    case op(String)
    /// Statement terminator (`;`).
    case semicolon

    var isTerminator: Bool {
        if case .semicolon = self { return true }
        return false
    }
}

/// Errors thrown by ``SQLTokenizer/tokenize(_:)``.
public enum SQLParseError: Error, Equatable, CustomStringConvertible {
    /// A `'...'` or `"..."` literal was not closed.
    case unterminatedString
    /// A `/* ... */` block comment was not closed.
    case unterminatedBlockComment

    /// Human-readable description.
    public var description: String {
        switch self {
        case .unterminatedString: return "unterminated string literal"
        case .unterminatedBlockComment: return "unterminated block comment"
        }
    }
}

/// The tokenizer beneath ``SQLSafetyVerifier`` — small, exact, and built
/// for one reality rather than the whole SQL standard. Public on purpose,
/// so callers can sharpen their own verifiers on the same token stream.
public enum SQLTokenizer {
    /// Tokenizes `input` into a stream of ``SQLToken`` values.
    public static func tokenize(_ input: String) throws -> [SQLToken] {
        var tokens: [SQLToken] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            // Line comment
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            // Block comment
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                var closed = false
                while i + 1 < chars.count {
                    if chars[i] == "*", chars[i + 1] == "/" {
                        i += 2; closed = true; break
                    }
                    i += 1
                }
                if !closed { throw SQLParseError.unterminatedBlockComment }
                continue
            }
            // String literal '...'
            if c == "'" {
                var s = ""
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" {
                            s.append("'"); i += 2  // escaped quote
                        } else {
                            i += 1; closed = true; break
                        }
                    } else {
                        s.append(chars[i]); i += 1
                    }
                }
                if !closed { throw SQLParseError.unterminatedString }
                tokens.append(.string(s))
                continue
            }
            // Quoted identifier "..."
            if c == "\"" {
                var s = ""
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == "\"" { i += 1; closed = true; break }
                    s.append(chars[i]); i += 1
                }
                if !closed { throw SQLParseError.unterminatedString }
                tokens.append(.identifier(s))
                continue
            }
            // Number
            if c.isNumber {
                var s = ""
                while i < chars.count, (chars[i].isNumber || chars[i] == "." || chars[i] == "e" || chars[i] == "E" || chars[i] == "+" || chars[i] == "-") {
                    s.append(chars[i]); i += 1
                }
                tokens.append(.number(s))
                continue
            }
            // Identifier / keyword
            if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    s.append(chars[i]); i += 1
                }
                let lower = s.lowercased()
                if Self.keywords.contains(lower) {
                    tokens.append(.keyword(lower))
                } else {
                    tokens.append(.identifier(s))
                }
                continue
            }
            if c == ";" {
                tokens.append(.semicolon); i += 1; continue
            }
            // Operator / punctuation
            tokens.append(.op(String(c))); i += 1
        }
        return tokens
    }

    /// Splits a token stream on `;` into per-statement token lists.
    public static func statements(_ tokens: [SQLToken]) -> [[SQLToken]] {
        var out: [[SQLToken]] = []
        var cur: [SQLToken] = []
        for t in tokens {
            if t.isTerminator {
                if !cur.isEmpty { out.append(cur); cur = [] }
            } else {
                cur.append(t)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Returns the ``SQLStatementKind`` matching the first keyword in
    /// `statement`, or ``SQLStatementKind/unknown``.
    public static func classify(_ statement: [SQLToken]) -> SQLStatementKind {
        for token in statement {
            if case .keyword(let k) = token {
                return SQLStatementKind(rawValue: k) ?? .unknown
            }
        }
        return .unknown
    }

    /// `true` if `statement` contains the supplied (case-insensitive) keyword.
    public static func containsKeyword(_ keyword: String, in statement: [SQLToken]) -> Bool {
        let lower = keyword.lowercased()
        return statement.contains { token in
            if case .keyword(let k) = token { return k == lower }
            return false
        }
    }

    static let keywords: Set<String> = [
        "select", "from", "where", "and", "or", "not", "in", "exists", "between",
        "like", "is", "null", "as", "join", "inner", "outer", "left", "right",
        "full", "on", "group", "by", "having", "order", "asc", "desc", "limit",
        "offset", "fetch", "first", "next", "rows", "only",
        "with", "recursive", "union", "intersect", "except", "all", "distinct",
        "insert", "into", "values", "returning",
        "update", "set",
        "delete",
        "create", "table", "view", "index", "schema", "database", "if", "exists",
        "alter", "drop", "truncate", "rename", "to", "column", "constraint",
        "grant", "revoke", "privileges",
        "explain", "analyze",
        "begin", "commit", "rollback", "transaction",
        "case", "when", "then", "else", "end",
    ]
}
