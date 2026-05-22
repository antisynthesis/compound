import Foundation

/// A patch is a confident claim about lines that may not exist. This
/// verifies a unified diff is actually well-formed: every hunk header
/// parses, every hunk's line counts match its header, and the total number
/// of changed lines stays under an optional cap. It catches the patch
/// hallucinations the model states with a straight face — wrong line
/// numbers, truncated hunks, missing headers.
public struct UnifiedDiffParseVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Optional cap on `+`/`-` line count.
    public let maxChangedLines: Int?
    /// When `true`, the diff must contain `---` and `+++` headers.
    public let requireFileHeaders: Bool

    /// Creates a verifier.
    public init(name: String = "unified-diff",
                maxChangedLines: Int? = nil,
                requireFileHeaders: Bool = true) {
        self.name = name
        self.maxChangedLines = maxChangedLines
        self.requireFileHeaders = requireFileHeaders
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        var sawFileHeaders = (false, false)  // ---, +++
        var inHunk = false
        var expectedOld = 0
        var expectedNew = 0
        var seenOld = 0
        var seenNew = 0
        var changedLines = 0
        var lineNumber = 0

        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            lineNumber += 1
            let s = String(line)
            if s.hasPrefix("--- ") {
                if inHunk, !Self.hunkCountsAgree(seenOld: seenOld, expectedOld: expectedOld, seenNew: seenNew, expectedNew: expectedNew) {
                    return .repair(Self.countsDiag(name: name, line: lineNumber, seenOld: seenOld, expectedOld: expectedOld, seenNew: seenNew, expectedNew: expectedNew))
                }
                inHunk = false
                sawFileHeaders.0 = true
                continue
            }
            if s.hasPrefix("+++ ") {
                sawFileHeaders.1 = true
                continue
            }
            if s.hasPrefix("@@") {
                if inHunk, !Self.hunkCountsAgree(seenOld: seenOld, expectedOld: expectedOld, seenNew: seenNew, expectedNew: expectedNew) {
                    return .repair(Self.countsDiag(name: name, line: lineNumber, seenOld: seenOld, expectedOld: expectedOld, seenNew: seenNew, expectedNew: expectedNew))
                }
                guard let parsed = Self.parseHunkHeader(s) else {
                    return .repair(Diagnostic(
                        verifier: name,
                        message: "malformed hunk header at line \(lineNumber): \(s.prefix(60))",
                        suggestion: "use the form @@ -<oldStart>,<oldCount> +<newStart>,<newCount> @@"
                    ))
                }
                expectedOld = parsed.oldCount
                expectedNew = parsed.newCount
                seenOld = 0
                seenNew = 0
                inHunk = true
                continue
            }
            if !inHunk { continue }
            if s.hasPrefix("-") {
                seenOld += 1
                changedLines += 1
            } else if s.hasPrefix("+") {
                seenNew += 1
                changedLines += 1
            } else if s.hasPrefix(" ") || s.isEmpty {
                seenOld += 1
                seenNew += 1
            } else if s.hasPrefix("\\") {
                continue  // "\ No newline at end of file"
            } else {
                return .repair(Diagnostic(
                    verifier: name,
                    message: "unexpected diff line at \(lineNumber): \(s.prefix(40))"
                ))
            }
        }
        if inHunk, !Self.hunkCountsAgree(seenOld: seenOld, expectedOld: expectedOld, seenNew: seenNew, expectedNew: expectedNew) {
            return .repair(Self.countsDiag(name: name, line: lineNumber, seenOld: seenOld, expectedOld: expectedOld, seenNew: seenNew, expectedNew: expectedNew))
        }
        if requireFileHeaders && !(sawFileHeaders.0 && sawFileHeaders.1) {
            return .repair(Diagnostic(
                verifier: name,
                message: "missing --- / +++ file headers",
                suggestion: "begin every file's section with --- a/<path> and +++ b/<path>"
            ))
        }
        if let limit = maxChangedLines, changedLines > limit {
            return .repair(Diagnostic(
                verifier: name,
                message: "patch is too large: \(changedLines) changed lines > \(limit)",
                suggestion: "split this change into smaller patches"
            ))
        }
        return .pass
    }

    private static func hunkCountsAgree(seenOld: Int, expectedOld: Int, seenNew: Int, expectedNew: Int) -> Bool {
        seenOld == expectedOld && seenNew == expectedNew
    }

    private static func countsDiag(name: String, line: Int, seenOld: Int, expectedOld: Int, seenNew: Int, expectedNew: Int) -> Diagnostic {
        Diagnostic(
            verifier: name,
            message: "hunk line counts disagree near line \(line): old \(seenOld) of \(expectedOld), new \(seenNew) of \(expectedNew)",
            suggestion: "recount lines so they match the @@ header"
        )
    }

    static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        // @@ -<oldStart>[,<oldCount>] +<newStart>[,<newCount>] @@ [context]
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        guard scanner.scanString("@@") != nil else { return nil }
        _ = scanner.scanCharacters(from: .whitespaces)
        guard scanner.scanString("-") != nil else { return nil }
        guard let oldStart = scanner.scanInt() else { return nil }
        var oldCount = 1
        if scanner.scanString(",") != nil {
            guard let n = scanner.scanInt() else { return nil }
            oldCount = n
        }
        _ = scanner.scanCharacters(from: .whitespaces)
        guard scanner.scanString("+") != nil else { return nil }
        guard let newStart = scanner.scanInt() else { return nil }
        var newCount = 1
        if scanner.scanString(",") != nil {
            guard let n = scanner.scanInt() else { return nil }
            newCount = n
        }
        return (oldStart, oldCount, newStart, newCount)
    }
}
