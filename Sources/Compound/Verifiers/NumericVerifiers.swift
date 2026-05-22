import Foundation

// Numeric invariants that refuse to fold into JSONSchemaVerifier — the
// model emits a single bare number, probabilities need a 0...1 bound, or
// line-items must sum to a declared total within a tolerance. Arithmetic
// is one place a confident lie has nowhere to hide; these hold it there.

/// Holds a `Double` inside optional `min`/`max` bounds. Numbers are where
/// fluency runs out of room to bluff.
public struct NumericRangeVerifier: Verifier {
    public typealias Input = Double
    public let name: String
    public let cost: VerifierCost = .parse
    /// Lower bound.
    public let min: Double?
    /// Upper bound.
    public let max: Double?
    /// `true` for inclusive comparison.
    public let inclusive: Bool

    /// Creates a verifier. At least one bound must be supplied.
    public init(name: String = "numeric-range", min: Double? = nil, max: Double? = nil, inclusive: Bool = true) {
        precondition(min != nil || max != nil, "NumericRangeVerifier needs at least one bound")
        self.name = name
        self.min = min
        self.max = max
        self.inclusive = inclusive
    }

    public func verify(_ input: Double, context _: RunContext) async throws -> Verdict {
        if let min {
            let ok = inclusive ? input >= min : input > min
            if !ok {
                return .repair(Diagnostic(
                    verifier: name,
                    message: "value \(input) violates lower bound \(min) (inclusive=\(inclusive))"
                ))
            }
        }
        if let max {
            let ok = inclusive ? input <= max : input < max
            if !ok {
                return .repair(Diagnostic(
                    verifier: name,
                    message: "value \(input) violates upper bound \(max) (inclusive=\(inclusive))"
                ))
            }
        }
        return .pass
    }
}

/// Insists a probability actually be one: a value in `[0, 1]`, and not
/// `NaN`. The model says "0.97 confidence" — this checks the number is
/// even a number.
public struct ProbabilityVerifier: Verifier {
    public typealias Input = Double
    public let name: String
    public let cost: VerifierCost = .parse

    /// Creates a verifier.
    public init(name: String = "probability") { self.name = name }

    public func verify(_ input: Double, context _: RunContext) async throws -> Verdict {
        if input.isNaN || input < 0 || input > 1 {
            return .repair(Diagnostic(
                verifier: name,
                message: "value \(input) is not a probability in [0, 1]"
            ))
        }
        return .pass
    }
}

/// Pairing of a declared total with its component parts and an absolute
/// tolerance, supplied to ``SumVerifier``.
public struct SumCheck: Sendable {
    /// Declared total.
    public let total: Double
    /// Component values.
    public let parts: [Double]
    /// Absolute tolerance permitted between `total` and `parts.sum()`.
    public let tolerance: Double

    /// Creates a check.
    public init(total: Double, parts: [Double], tolerance: Double = 0.005) {
        self.total = total
        self.parts = parts
        self.tolerance = tolerance
    }
}

/// Validates that ``SumCheck/parts`` sum to ``SumCheck/total`` within
/// ``SumCheck/tolerance``. Models routinely produce arithmetic-
/// inconsistent invoices or score breakdowns; this catches the
/// structural error before the output reaches a system of record.
public struct SumVerifier: Verifier {
    public typealias Input = SumCheck
    public let name: String
    public let cost: VerifierCost = .parse

    /// Creates a verifier.
    public init(name: String = "sum") { self.name = name }

    public func verify(_ input: SumCheck, context _: RunContext) async throws -> Verdict {
        let sum = input.parts.reduce(0, +)
        let diff = abs(sum - input.total)
        if diff <= input.tolerance { return .pass }
        return .repair(Diagnostic(
            verifier: name,
            message: "parts sum to \(sum) but total is \(input.total) (diff \(diff) > tolerance \(input.tolerance))",
            suggestion: "either recompute the total from the parts, or adjust the parts to match"
        ))
    }
}

/// Demands a sequence keep moving the way it claims to — monotonic in the
/// requested direction. The instrument for time-series, paging cursors,
/// and version numbers, where one value out of order is a quiet
/// corruption the model will never confess to.
public struct MonotonicVerifier<Value: Comparable & Sendable>: Verifier {
    public typealias Input = [Value]
    public let name: String
    public let cost: VerifierCost = .parse
    /// Required direction.
    public let direction: Direction
    /// `true` requires strict monotonicity (no equal adjacent values).
    public let strict: Bool

    /// Direction the sequence must move.
    public enum Direction: Sendable {
        case ascending, descending
    }

    /// Creates a verifier.
    public init(name: String = "monotonic", direction: Direction = .ascending, strict: Bool = false) {
        self.name = name
        self.direction = direction
        self.strict = strict
    }

    public func verify(_ input: [Value], context _: RunContext) async throws -> Verdict {
        guard input.count >= 2 else { return .pass }
        for i in 1..<input.count {
            let prev = input[i - 1], cur = input[i]
            let ok: Bool
            switch (direction, strict) {
            case (.ascending, true): ok = cur > prev
            case (.ascending, false): ok = cur >= prev
            case (.descending, true): ok = cur < prev
            case (.descending, false): ok = cur <= prev
            }
            if !ok {
                return .repair(Diagnostic(
                    verifier: name,
                    message: "sequence is not \(strict ? "strictly " : "")\(direction == .ascending ? "ascending" : "descending") at index \(i)"
                ))
            }
        }
        return .pass
    }
}
