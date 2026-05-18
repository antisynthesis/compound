import Foundation

/// One `str_replace`-style edit proposed by the model. The system
/// refuses to apply the edit unless ``oldString`` matches exactly once
/// in the target file, which rejects hallucinated quotations by
/// construction.
public struct ProposedEdit: Sendable, Equatable, Hashable {
    /// Target file path.
    public let path: String
    /// Text being replaced.
    public let oldString: String
    /// Replacement text.
    public let newString: String

    /// Creates a proposed edit.
    public init(path: String, oldString: String, newString: String) {
        self.path = path
        self.oldString = oldString
        self.newString = newString
    }
}

/// Closure that reads file content as UTF-8 text. Pluggable so tests
/// and sandboxed environments can fake the filesystem.
public typealias FileContentReader = @Sendable (String) throws -> String

/// Default ``FileContentReader`` implementation backed by
/// `String(contentsOfFile:encoding:)`.
public enum DefaultFileContentReader {
    /// Reads the file as UTF-8.
    public static let value: FileContentReader = { path in
        try String(contentsOfFile: path, encoding: .utf8)
    }
}

/// Validates that a ``ProposedEdit``'s ``ProposedEdit/oldString`` is
/// non-empty and matches exactly once in the target file. Multiple
/// matches require the model to add surrounding context to make the
/// match unique.
public struct ExactMatchEditVerifier: Verifier {
    public typealias Input = ProposedEdit
    public let name: String
    public let cost: VerifierCost = .parse
    private let reader: FileContentReader

    /// Creates a verifier.
    public init(name: String = "exact-match-edit", reader: @escaping FileContentReader = DefaultFileContentReader.value) {
        self.name = name
        self.reader = reader
    }

    public func verify(_ edit: ProposedEdit, context _: RunContext) async throws -> Verdict {
        if edit.oldString.isEmpty {
            return .repair(Diagnostic(
                verifier: name,
                message: "oldString is empty",
                suggestion: "quote the exact text to replace, including surrounding context"
            ))
        }
        if edit.oldString == edit.newString {
            return .repair(Diagnostic(
                verifier: name,
                message: "oldString equals newString — edit is a no-op"
            ))
        }
        let content: String
        do {
            content = try reader(edit.path)
        } catch {
            return .reject("could not read '\(edit.path)': \(error.localizedDescription)")
        }
        let occurrences = Self.countOccurrences(of: edit.oldString, in: content)
        switch occurrences {
        case 0:
            return .repair(Diagnostic(
                verifier: name,
                message: "oldString not found in '\(edit.path)'",
                suggestion: "quote the text exactly, including whitespace and line endings"
            ))
        case 1:
            return .pass
        default:
            return .repair(Diagnostic(
                verifier: name,
                message: "oldString matches \(occurrences) places in '\(edit.path)' — must be unique",
                suggestion: "include more surrounding context so the match is unique"
            ))
        }
    }

    static func countOccurrences(of needle: String, in haystack: String) -> Int {
        if needle.isEmpty { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = r.upperBound..<haystack.endIndex
        }
        return count
    }
}

/// Confirms an edit is non-trivial: ``ProposedEdit/oldString`` and
/// ``ProposedEdit/newString`` differ. Useful as a cheap pre-filter
/// before invoking ``ExactMatchEditVerifier``.
public struct NoOpEditVerifier: Verifier {
    public typealias Input = ProposedEdit
    public let name: String
    public let cost: VerifierCost = .parse

    /// Creates a verifier.
    public init(name: String = "no-op-edit") {
        self.name = name
    }

    public func verify(_ edit: ProposedEdit, context _: RunContext) async throws -> Verdict {
        if edit.oldString == edit.newString {
            return .repair(Diagnostic(verifier: name, message: "edit is a no-op"))
        }
        return .pass
    }
}

/// Runs after the edit has been applied to confirm the file actually
/// changed as proposed. Catches edge cases where the apply step
/// silently no-ops (e.g. permission errors swallowed upstream).
public struct EditAppliedVerifier: Verifier {
    public typealias Input = ProposedEdit
    public let name: String
    public let cost: VerifierCost = .parse
    private let reader: FileContentReader

    /// Creates a verifier.
    public init(name: String = "edit-applied", reader: @escaping FileContentReader = DefaultFileContentReader.value) {
        self.name = name
        self.reader = reader
    }

    public func verify(_ edit: ProposedEdit, context _: RunContext) async throws -> Verdict {
        let content: String
        do {
            content = try reader(edit.path)
        } catch {
            return .reject("could not read '\(edit.path)': \(error.localizedDescription)")
        }
        if content.contains(edit.oldString) {
            return .repair(Diagnostic(
                verifier: name,
                message: "oldString still present in '\(edit.path)' after apply"
            ))
        }
        if !content.contains(edit.newString) {
            return .repair(Diagnostic(
                verifier: name,
                message: "newString not found in '\(edit.path)' after apply"
            ))
        }
        return .pass
    }
}
