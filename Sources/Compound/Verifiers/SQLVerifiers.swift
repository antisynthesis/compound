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

/// Pragmatic SQL safety gate for text-to-SQL agents.
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

/// SQL tokenizer used by ``SQLSafetyVerifier``. Public so callers can
/// build their own verifiers on the same token stream.
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
            // Number. A leading sign is never consumed here (it is a
            // separate operator), and `+`/`-` are only absorbed as an
            // exponent sign immediately after `e`/`E`. Without this the
            // lexer would greedily swallow `1-2` into a single number
            // token and hide the `-` operator from downstream analysis.
            if c.isNumber {
                var s = ""
                while i < chars.count {
                    let ch = chars[i]
                    if ch.isNumber || ch == "." {
                        s.append(ch); i += 1
                    } else if ch == "e" || ch == "E" {
                        s.append(ch); i += 1
                        if i < chars.count, chars[i] == "+" || chars[i] == "-" {
                            s.append(chars[i]); i += 1
                        }
                    } else {
                        break
                    }
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

    /// Classifies `statement` by the **most privileged** verb keyword
    /// appearing at the top level (parenthesis depth 0). Keying on the
    /// first keyword alone let `WITH x AS (SELECT 1) DELETE FROM t` and
    /// `EXPLAIN ANALYZE DELETE FROM t` masquerade as harmless `with` /
    /// `explain` statements; scanning every top-level verb and returning
    /// the most destructive one closes that bypass. Keywords inside
    /// parentheses (subqueries, CTE bodies) are ignored so a nested
    /// `SELECT` never lowers the classification of the outer statement.
    public static func classify(_ statement: [SQLToken]) -> SQLStatementKind {
        var depth = 0
        var best: SQLStatementKind?
        var bestRank = Int.min
        for token in statement {
            switch token {
            case .op(let o):
                if o == "(" { depth += 1 } else if o == ")" { depth = max(0, depth - 1) }
            case .keyword(let k) where depth == 0:
                if let kind = SQLStatementKind(rawValue: k) {
                    let rank = privilegeRank[kind] ?? 0
                    if rank > bestRank { bestRank = rank; best = kind }
                }
            default:
                break
            }
        }
        return best ?? .unknown
    }

    /// Ordering used by ``classify(_:)`` — higher is more privileged, so
    /// the most destructive verb present wins. Only statement-verb
    /// keywords appear; other keywords (`from`, `where`, ...) never map
    /// to a ``SQLStatementKind`` and are ignored.
    static let privilegeRank: [SQLStatementKind: Int] = [
        .drop: 100, .truncate: 95,
        .delete: 90, .update: 85, .insert: 80,
        .alter: 75, .create: 70,
        .grant: 65, .revoke: 60,
        .set: 40,
        .select: 30,
        .with: 20, .explain: 15,
        .begin: 10, .commit: 10, .rollback: 10,
        .unknown: 0,
    ]

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
