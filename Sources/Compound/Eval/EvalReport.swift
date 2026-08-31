import Foundation
import FoundationModels

/// Summarizes a run of an ``EvalSuite``.
///
/// Each case has a `completed` result (model produced an output and
/// predicates were checked), an `errored` result (the run itself threw —
/// model unavailable, budget exhausted, etc.), or a `timedOut` result (the
/// runner's per-case deadline elapsed). All are surfaced; the harness never
/// swallows failures.
///
/// Reports are `Codable`: durations are encoded as integer nanoseconds and
/// dates encode with whatever strategy the encoder is configured with
/// (``jsonData(prettyPrinted:)`` uses ISO 8601), so a CI baseline can be
/// serialized, stored, and later compared with ``EvalGate``.
public struct EvalReport: Sendable, Codable {
    /// Suite name (from ``EvalSuite/name``).
    public let suiteName: String
    /// Wall-clock instant the run started.
    public let started: Date
    /// Wall-clock instant the run finished.
    public let finished: Date
    /// Per-case outcomes in evaluation order.
    public let cases: [CaseOutcome]
    /// Snapshot of the machine the run executed on, if recorded.
    public let environment: Environment?

    /// Snapshot of the execution environment, recorded so a stored
    /// baseline can be interpreted later ("was the model even available
    /// on that runner?").
    public struct Environment: Sendable, Codable, Equatable {
        /// Operating system version string of the host.
        public let osVersion: String
        /// Availability of the on-device `SystemLanguageModel` at run
        /// start ("available" or the unavailability reason).
        public let modelAvailability: String

        /// Creates an environment snapshot.
        public init(osVersion: String, modelAvailability: String) {
            self.osVersion = osVersion
            self.modelAvailability = modelAvailability
        }

        /// Captures the current host's environment.
        public static func current() -> Environment {
            let availability: String
            switch SystemLanguageModel.default.availability {
            case .available:
                availability = "available"
            case .unavailable(let reason):
                availability = "unavailable: \(reason)"
            }
            return Environment(
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                modelAvailability: availability
            )
        }
    }

    /// Outcome of evaluating a single ``EvalCase``.
    public struct CaseOutcome: Sendable, Codable {
        /// Identifier of the originating case.
        public let caseID: String
        /// Prompt used.
        public let prompt: String
        /// The ``RunContext/runID`` the case executed under, for
        /// correlating report rows with trace events.
        public let runID: UUID
        /// Outcome.
        public let result: Result

        /// Creates a case outcome.
        public init(caseID: String, prompt: String, runID: UUID, result: Result) {
            self.caseID = caseID
            self.prompt = prompt
            self.runID = runID
            self.result = result
        }

        /// A completed case with predicate checks, a run error, or a
        /// per-case deadline expiry.
        public enum Result: Sendable, Codable {
            /// The run produced `output`; `checks` are predicate outcomes.
            case completed(output: String, checks: [PredicateOutcome], elapsed: Duration)
            /// The run threw `reason` before producing an output.
            case errored(reason: String, elapsed: Duration)
            /// The runner's ``EvalRunner/caseTimeout`` elapsed before the
            /// target responded; the case was cancelled.
            case timedOut(elapsed: Duration)

            private enum CodingKeys: String, CodingKey {
                case kind, output, checks, reason, elapsedNanoseconds
            }

            private enum Kind: String, Codable {
                case completed, errored, timedOut
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let kind = try container.decode(Kind.self, forKey: .kind)
                let nanos = try container.decode(Int64.self, forKey: .elapsedNanoseconds)
                let elapsed = Duration.nanoseconds(nanos)
                switch kind {
                case .completed:
                    self = .completed(
                        output: try container.decode(String.self, forKey: .output),
                        checks: try container.decode([PredicateOutcome].self, forKey: .checks),
                        elapsed: elapsed
                    )
                case .errored:
                    self = .errored(
                        reason: try container.decode(String.self, forKey: .reason),
                        elapsed: elapsed
                    )
                case .timedOut:
                    self = .timedOut(elapsed: elapsed)
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .completed(let output, let checks, let elapsed):
                    try container.encode(Kind.completed, forKey: .kind)
                    try container.encode(output, forKey: .output)
                    try container.encode(checks, forKey: .checks)
                    try container.encode(Self.nanoseconds(of: elapsed), forKey: .elapsedNanoseconds)
                case .errored(let reason, let elapsed):
                    try container.encode(Kind.errored, forKey: .kind)
                    try container.encode(reason, forKey: .reason)
                    try container.encode(Self.nanoseconds(of: elapsed), forKey: .elapsedNanoseconds)
                case .timedOut(let elapsed):
                    try container.encode(Kind.timedOut, forKey: .kind)
                    try container.encode(Self.nanoseconds(of: elapsed), forKey: .elapsedNanoseconds)
                }
            }

            private static func nanoseconds(of duration: Duration) -> Int64 {
                let (seconds, attoseconds) = duration.components
                return seconds * 1_000_000_000 &+ attoseconds / 1_000_000_000
            }
        }

        /// One predicate's contribution to a `completed` outcome.
        public struct PredicateOutcome: Sendable, Codable {
            /// Predicate name.
            public let name: String
            /// Result of the predicate.
            public let check: EvalCheck

            /// Creates a predicate outcome.
            public init(name: String, check: EvalCheck) {
                self.name = name
                self.check = check
            }
        }

        /// `true` if the case completed and every predicate passed.
        public var passed: Bool {
            switch result {
            case .completed(_, let checks, _):
                return checks.allSatisfy { $0.check.passed }
            case .errored, .timedOut:
                return false
            }
        }
    }

    /// Number of passing cases.
    public var passed: Int { cases.filter(\.passed).count }
    /// Number of failing cases.
    public var failed: Int { cases.count - passed }
    /// Passing fraction in `[0.0, 1.0]`.
    public var passRate: Double { cases.isEmpty ? 0 : Double(passed) / Double(cases.count) }
    /// Wall-clock duration of the run.
    public var elapsed: Duration { .seconds(finished.timeIntervalSince(started)) }

    /// Creates a report.
    public init(
        suiteName: String,
        started: Date,
        finished: Date,
        cases: [CaseOutcome],
        environment: Environment? = nil
    ) {
        self.suiteName = suiteName
        self.started = started
        self.finished = finished
        self.cases = cases
        self.environment = environment
    }

    /// Encodes the report as JSON with ISO 8601 dates and sorted keys, so
    /// stored baselines diff cleanly.
    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Returns a copy with every wall-clock-dependent field neutralized:
    /// ``started`` and ``finished`` collapse to the Unix epoch, each
    /// outcome's ``CaseOutcome/runID`` becomes the all-zero UUID, and every
    /// `elapsed` duration becomes `.zero`. Outputs, checks, prompts, case
    /// ids, and ``environment`` are preserved verbatim.
    ///
    /// This is what makes a *committed* baseline reviewable. A report
    /// encoded straight from a run differs on every field that touches a
    /// clock or a UUID generator, so regenerating it would produce a diff
    /// with no signal in it; normalizing first means the only lines that
    /// move are the ones describing behavior that actually changed.
    ///
    /// ``environment`` is deliberately kept — a baseline should record
    /// which OS and model availability produced it — and is equally
    /// deliberately *not* consulted by ``EvalGate/compare(baseline:candidate:)``,
    /// which compares only pass rates and per-case verdicts. A baseline
    /// generated on a machine without the on-device model still gates a
    /// run on a machine that has it.
    public func normalizedForBaseline() -> EvalReport {
        let epoch = Date(timeIntervalSince1970: 0)
        let zeroID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        return EvalReport(
            suiteName: suiteName,
            started: epoch,
            finished: epoch,
            cases: cases.map { c in
                let result: CaseOutcome.Result
                switch c.result {
                case .completed(let output, let checks, _):
                    result = .completed(output: output, checks: checks, elapsed: .zero)
                case .errored(let reason, _):
                    result = .errored(reason: reason, elapsed: .zero)
                case .timedOut:
                    result = .timedOut(elapsed: .zero)
                }
                return CaseOutcome(caseID: c.caseID, prompt: c.prompt, runID: zeroID, result: result)
            },
            environment: environment
        )
    }

    /// Decodes a report previously produced by ``jsonData(prettyPrinted:)``.
    public init(jsonData: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(EvalReport.self, from: jsonData)
    }

    /// Human-readable single-line summary suitable for CI logs.
    /// Programs should inspect the structured ``cases`` array instead.
    public func summary() -> String {
        let rate = (passRate * 100).rounded()
        return "[\(suiteName)] \(passed)/\(cases.count) passed (\(Int(rate))%)"
    }

    /// Verbose multi-line report listing every case and its checks.
    /// Useful when investigating a regression locally; CI typically
    /// prefers a JSON encoding.
    public func detailedReport() -> String {
        var out = summary() + "\n"
        for c in cases {
            switch c.result {
            case .completed(_, let checks, _):
                let mark = c.passed ? "ok" : "FAIL"
                out += "  \(mark) \(c.caseID)\n"
                if !c.passed {
                    for p in checks where !p.check.passed {
                        out += "    - \(p.name): \(p.check.message ?? "failed")\n"
                    }
                }
            case .errored(let reason, _):
                out += "  ERR \(c.caseID): \(reason)\n"
            case .timedOut(let elapsed):
                out += "  TIMEOUT \(c.caseID) after \(elapsed)\n"
            }
        }
        return out
    }
}
