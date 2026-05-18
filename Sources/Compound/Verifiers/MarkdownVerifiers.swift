import Foundation

/// Structural sanity for Markdown output. Catches the common closing
/// mistakes — an extra fence line, an unterminated code block, a
/// half-written link — without requiring a full CommonMark parser.
public struct MarkdownStructureVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Verify every code fence is closed.
    public let balanceFences: Bool
    /// Verify every `[…](…)` link has balanced brackets and parens.
    public let balanceLinks: Bool
    /// Optional maximum heading level (`#` count) the document may use.
    public let maxHeadingLevel: Int?

    /// Creates a verifier.
    public init(
        name: String = "markdown-structure",
        balanceFences: Bool = true,
        balanceLinks: Bool = true,
        maxHeadingLevel: Int? = nil
    ) {
        self.name = name
        self.balanceFences = balanceFences
        self.balanceLinks = balanceLinks
        self.maxHeadingLevel = maxHeadingLevel
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        var fenceDepth = 0
        var lineNumber = 0
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            lineNumber += 1
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if balanceFences,
               trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenceDepth = fenceDepth == 0 ? 1 : 0
                continue
            }
            if fenceDepth > 0 { continue }
            if let max = maxHeadingLevel, trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level > max {
                    return .repair(Diagnostic(
                        verifier: name,
                        message: "heading at line \(lineNumber) has level \(level), max is \(max)"
                    ))
                }
            }
        }
        if balanceFences, fenceDepth != 0 {
            return .repair(Diagnostic(
                verifier: name,
                message: "unterminated code fence",
                suggestion: "close every ``` with a matching ```"
            ))
        }
        if balanceLinks, let issue = Self.linksWellFormed(input) {
            return .repair(Diagnostic(verifier: name, message: issue))
        }
        return .pass
    }

    // Verify that every `[text](url)` link has matched brackets and parens.
    // Brackets and parens *inside* a fenced code block are ignored by the
    // earlier loop, but for simplicity we use a pure scan here that
    // re-tracks fences. Mismatches inside inline code (single backticks)
    // are rare in practice and we accept them to keep the scanner tight.
    private static func linksWellFormed(_ input: String) -> String? {
        var inFence = false
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        var lineNumber = 0
        for line in lines {
            lineNumber += 1
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            // Walk the line: every `[` after which we eventually see `](` must
            // close out with `)`. Brackets without a following `(` are fine.
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == "\\" { i += 2; continue }
                if c == "[" {
                    // Find matching ]
                    var depth = 1
                    var j = i + 1
                    while j < chars.count {
                        if chars[j] == "\\" { j += 2; continue }
                        if chars[j] == "[" { depth += 1 }
                        if chars[j] == "]" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        j += 1
                    }
                    if depth != 0 {
                        return "unclosed '[' at line \(lineNumber)"
                    }
                    // After ]: is the next char `(` ? If so it's a link target.
                    let afterBracket = j + 1
                    if afterBracket < chars.count, chars[afterBracket] == "(" {
                        var pDepth = 1
                        var k = afterBracket + 1
                        while k < chars.count {
                            if chars[k] == "\\" { k += 2; continue }
                            if chars[k] == "(" { pDepth += 1 }
                            if chars[k] == ")" {
                                pDepth -= 1
                                if pDepth == 0 { break }
                            }
                            k += 1
                        }
                        if pDepth != 0 {
                            return "unclosed '(' in link target at line \(lineNumber)"
                        }
                        i = k + 1
                        continue
                    }
                    i = j + 1
                    continue
                }
                i += 1
            }
        }
        return nil
    }
}
