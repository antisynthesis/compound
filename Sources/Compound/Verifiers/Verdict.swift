import Foundation

/// Deterministic judgment returned by a ``Verifier``. The four cases mirror
/// the pattern's vocabulary: `pass` (move on), `repair` (retry with
/// diagnostic), `reject` (give up cleanly), `escalate` (defer to a human).
/// The control loop reacts to each.
public enum Verdict: Sendable, Equatable, Codable {
    /// Verification succeeded.
    case pass
    /// Verification failed but is worth retrying with the supplied
    /// diagnostic threaded into the next prompt.
    case repair(Diagnostic)
    /// Verification failed terminally; the run should fail with the
    /// diagnostic surfaced.
    case reject(Diagnostic)
    /// Verification cannot be resolved by the framework; defer to a
    /// human operator.
    case escalate(Diagnostic)

    /// `true` if this is ``pass``.
    public var isPass: Bool {
        if case .pass = self { return true }
        return false
    }

    /// The diagnostic carried by a non-``pass`` verdict, or `nil` for
    /// ``pass``.
    public var diagnostic: Diagnostic? {
        switch self {
        case .pass: return nil
        case .repair(let d), .reject(let d), .escalate(let d): return d
        }
    }
}

extension Verdict {
    /// Convenience factory: build a `.reject` verdict from a free-form
    /// reason string. The diagnostic is synthesized with verifier name
    /// `"reject"` so existing call sites that pass a string keep compiling.
    public static func reject(_ reason: String) -> Verdict {
        .reject(Diagnostic(verifier: "reject", message: reason))
    }

    /// Convenience factory: build an `.escalate` verdict from a free-form
    /// reason string.
    public static func escalate(_ reason: String) -> Verdict {
        .escalate(Diagnostic(verifier: "escalate", message: reason))
    }
}

// MARK: - Codable

extension Verdict {
    /// Wire keys for the hand-written ``Codable`` conformance. The
    /// synthesized enum conformance would nest payloads under `_0`; a
    /// stable `type` discriminator plus a named `diagnostic` keeps the
    /// JSONL trace format readable, greppable, and safe to walk
    /// structurally (see ``RedactingTracer``).
    enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case diagnostic
    }

    /// Stable discriminator string for this verdict's case.
    var wireType: String {
        switch self {
        case .pass: return "pass"
        case .repair: return "repair"
        case .reject: return "reject"
        case .escalate: return "escalate"
        }
    }

    /// Encodes as `{"type": "...", "diagnostic": {...}}`; `pass` carries
    /// no diagnostic.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireType, forKey: .type)
        if let diagnostic {
            try container.encode(diagnostic, forKey: .diagnostic)
        }
    }

    /// Decodes the `type`/`diagnostic` pair written by ``encode(to:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pass":
            self = .pass
        case "repair":
            self = .repair(try container.decode(Diagnostic.self, forKey: .diagnostic))
        case "reject":
            self = .reject(try container.decode(Diagnostic.self, forKey: .diagnostic))
        case "escalate":
            self = .escalate(try container.decode(Diagnostic.self, forKey: .diagnostic))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown verdict type \"\(type)\""
            )
        }
    }
}

/// Structured failure description carried by ``Verdict/repair(_:)``,
/// ``Verdict/reject(_:)``, and ``Verdict/escalate(_:)``. Pairs a
/// verifier-identified message with an optional repair suggestion and
/// source location so consumers can render actionable diagnostics.
public struct Diagnostic: Sendable, Equatable, Hashable, Codable {
    /// Name of the originating verifier.
    public let verifier: String
    /// What went wrong.
    public let message: String
    /// Optional repair suggestion; used by the control loop when crafting
    /// the next prompt.
    public let suggestion: String?
    /// Optional offset range pointing into the verified input.
    public let location: SourceRange?

    /// Creates a diagnostic.
    public init(verifier: String, message: String, suggestion: String? = nil, location: SourceRange? = nil) {
        self.verifier = verifier
        self.message = message
        self.suggestion = suggestion
        self.location = location
    }

    /// Folds several diagnostics into one. A single-element list returns
    /// its element unchanged; multiple elements produce a diagnostic
    /// attributed to `verifier` (default `"chain"`) whose message is the
    /// count plus each member's ``summary``. Used by
    /// ``VerifierChain/Mode/collectAll(maxDiagnostics:)`` when a chain must
    /// surface several accumulated failures through a single-``Diagnostic``
    /// ``Verdict`` payload.
    public static func combined(_ diagnostics: [Diagnostic], verifier: String = "chain") -> Diagnostic {
        guard let first = diagnostics.first else {
            return Diagnostic(verifier: verifier, message: "verification failed")
        }
        guard diagnostics.count > 1 else { return first }
        let joined = diagnostics.map(\.summary).joined(separator: "; ")
        return Diagnostic(
            verifier: verifier,
            message: "\(diagnostics.count) verifiers failed: \(joined)"
        )
    }

    /// Single-line summary suitable for logs and UI.
    public var summary: String {
        var out = "[\(verifier)] \(message)"
        if let suggestion { out += " (try: \(suggestion))" }
        if let location { out += " at \(location.start)..\(location.end)" }
        return out
    }
}

extension Diagnostic {
    /// Wire keys for the synthesized ``Codable`` conformance, spelled out
    /// so the trace layer can enumerate every structural key it must not
    /// rewrite while redacting (see ``RedactingTracer``).
    enum CodingKeys: String, CodingKey, CaseIterable {
        case verifier
        case message
        case suggestion
        case location
    }
}

/// Half-open `[start, end)` byte/character offset range used by
/// ``Diagnostic`` to point at a span of input.
public struct SourceRange: Sendable, Equatable, Hashable, Codable {
    /// Inclusive start offset.
    public let start: Int
    /// Exclusive end offset.
    public let end: Int
    /// Creates a range.
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

extension SourceRange {
    /// Wire keys for the synthesized ``Codable`` conformance; enumerated
    /// for the same reason as ``Diagnostic/CodingKeys``.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case start
        case end
    }
}

/// Cost hint used by ``VerifierChain`` to order verifiers cheapest-first.
/// Numeric values are deliberate — chains sort ascending. The names mirror
/// the ladder in the pattern doc: parse, schema, types, lint, unit,
/// integration, proof, human.
public enum VerifierCost: Int, Sendable, Comparable, Codable {
    /// Free or near-free structural checks (encoding, parse-ability).
    case parse = 0
    /// Schema/shape conformance.
    case schema = 10
    /// Type-level checks (e.g. compile-style).
    case types = 20
    /// Lint and style checks.
    case lint = 30
    /// Unit-level execution checks.
    case unitTest = 40
    /// Integration-level execution checks.
    case integrationTest = 50
    /// Formal proof or other expensive verification.
    case proof = 60
    /// Human-in-the-loop review.
    case human = 70

    public static func < (lhs: VerifierCost, rhs: VerifierCost) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
