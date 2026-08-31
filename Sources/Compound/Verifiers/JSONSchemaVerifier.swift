import Foundation

/// Validates model output against a pragmatic subset of JSON Schema:
/// typed objects with required keys, typed arrays with bounds, scalars
/// with bounds, fixed enumerations, and alternation.
///
/// The verifier surfaces structural mismatches as ``Verdict/repair(_:)``
/// so the control loop can ask the model to produce a corrected
/// document. Validation tracks depth and node count against
/// ``maxDepth`` and ``maxNodes`` to guard against adversarial inputs;
/// ``JSONSchema/oneOf(_:)`` short-circuits on the first matching
/// alternative rather than requiring strict "exactly one" semantics.
public struct JSONSchemaVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .schema
    /// Active schema.
    public let schema: JSONSchema
    /// Maximum recursion depth before validation aborts.
    public let maxDepth: Int
    /// Maximum visited node count before validation aborts.
    public let maxNodes: Int
    /// First `string(pattern:)` in ``schema`` that fails to compile, if
    /// any. Detected once at init so validation can fail closed instead
    /// of treating an uncompilable pattern as "no constraint".
    private let invalidPattern: String?

    /// Creates a verifier.
    public init(name: String = "json-schema",
                schema: JSONSchema,
                maxDepth: Int = 64,
                maxNodes: Int = 10_000) {
        self.name = name
        self.schema = schema
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.invalidPattern = Self.firstInvalidPattern(in: schema)
    }

    // Walks the schema tree once at init and returns the first regex
    // pattern that does not compile. A broken pattern used to be silently
    // skipped at validation time (`try? Regex(...)` -> nil -> no check),
    // so `{ "x": "\(anything)" }` would pass a schema whose author
    // intended a strict pattern. Surfacing it up front lets ``verify``
    // reject rather than pass.
    static func firstInvalidPattern(in schema: JSONSchema) -> String? {
        switch schema {
        case .string(_, _, let pattern):
            if let pattern, (try? Regex(pattern)) == nil { return pattern }
            return nil
        case .array(let items, _, _):
            return firstInvalidPattern(in: items)
        case .object(let properties, _, _):
            for child in properties.values {
                if let bad = firstInvalidPattern(in: child) { return bad }
            }
            return nil
        case .oneOf(let alternatives):
            for alt in alternatives {
                if let bad = firstInvalidPattern(in: alt) { return bad }
            }
            return nil
        case .number, .integer, .boolean, .null, .literal, .any:
            return nil
        }
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        // Fail closed on a schema whose pattern could not be compiled:
        // never report `.pass` for a constraint we were unable to check.
        if let invalidPattern {
            return .reject(Diagnostic(
                verifier: name,
                message: "internal verifier error: schema pattern failed to compile: \(invalidPattern)"
            ))
        }
        guard let data = input.data(using: .utf8) else {
            return .repair(Diagnostic(verifier: name, message: "output is not valid UTF-8"))
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .repair(Diagnostic(
                verifier: name,
                message: "invalid JSON: \(error.localizedDescription)",
                suggestion: "return only valid JSON with no surrounding prose"
            ))
        }
        let value = JSONValue.from(raw)
        var budget = ValidationBudget(maxDepth: maxDepth, maxNodes: maxNodes)
        if let issue = schema.validate(value, path: "$", depth: 0, budget: &budget) {
            return .repair(Diagnostic(
                verifier: name,
                message: issue,
                suggestion: "match the declared schema exactly"
            ))
        }
        return .pass
    }
}

// Mutable counter passed through every nested validate(...) call so we
// can stop early on adversarial input. Wrapped in its own type for
// clarity rather than threading two `inout Int`s by hand.
struct ValidationBudget {
    let maxDepth: Int
    let maxNodes: Int
    var nodes: Int = 0

    mutating func consumeNode() -> String? {
        nodes += 1
        if nodes > maxNodes {
            return "validation aborted: exceeded node budget (\(maxNodes))"
        }
        return nil
    }

    func checkDepth(_ depth: Int) -> String? {
        if depth > maxDepth {
            return "validation aborted: exceeded depth budget (\(maxDepth))"
        }
        return nil
    }
}

/// Schema description for ``JSONSchemaVerifier``. Each case represents
/// a JSON type plus the bounds the verifier should enforce.
public indirect enum JSONSchema: Sendable, Equatable {
    /// String with optional length bounds and regex pattern.
    case string(minLength: Int? = nil, maxLength: Int? = nil, pattern: String? = nil)
    /// Number (integer or floating-point) with optional bounds.
    case number(min: Double? = nil, max: Double? = nil)
    /// Integer with optional bounds.
    case integer(min: Int? = nil, max: Int? = nil)
    /// Boolean.
    case boolean
    /// JSON `null`.
    case null
    /// Fixed enumeration of allowed values.
    case literal([JSONValue])
    /// Array of items conforming to a sub-schema, with optional cardinality bounds.
    case array(items: JSONSchema, minItems: Int? = nil, maxItems: Int? = nil)
    /// Object with per-key schemas, a required-key set, and a flag for
    /// additional properties.
    case object(properties: [String: JSONSchema], required: Set<String> = [], additionalProperties: Bool = true)
    /// Alternation: matches if any alternative matches.
    case oneOf([JSONSchema])
    /// Matches any value.
    case any

    func validate(_ value: JSONValue, path: String, depth: Int, budget: inout ValidationBudget) -> String? {
        if let issue = budget.checkDepth(depth) { return issue }
        if let issue = budget.consumeNode() { return issue }
        switch self {
        case .string(let minLength, let maxLength, let pattern):
            guard case .string(let s) = value else { return Self.typeError(path: path, expected: "string", got: value) }
            if let min = minLength, s.count < min { return "\(path) string too short: \(s.count) < \(min)" }
            if let max = maxLength, s.count > max { return "\(path) string too long: \(s.count) > \(max)" }
            if let pattern, let regex = try? Regex(pattern), (try? regex.firstMatch(in: s)) == nil {
                return "\(path) string does not match pattern \(pattern)"
            }
            return nil
        case .number(let min, let max):
            let n: Double
            switch value {
            case .double(let d): n = d
            case .integer(let i): n = Double(i)
            default: return Self.typeError(path: path, expected: "number", got: value)
            }
            if let min, n < min { return "\(path) number \(n) < \(min)" }
            if let max, n > max { return "\(path) number \(n) > \(max)" }
            return nil
        case .integer(let min, let max):
            guard case .integer(let i) = value else { return Self.typeError(path: path, expected: "integer", got: value) }
            if let min, i < min { return "\(path) integer \(i) < \(min)" }
            if let max, i > max { return "\(path) integer \(i) > \(max)" }
            return nil
        case .boolean:
            guard case .bool = value else { return Self.typeError(path: path, expected: "boolean", got: value) }
            return nil
        case .null:
            guard case .null = value else { return Self.typeError(path: path, expected: "null", got: value) }
            return nil
        case .literal(let allowed):
            if allowed.contains(value) { return nil }
            return "\(path) value \(value.describe) not in allowed set"
        case .array(let items, let minItems, let maxItems):
            guard case .array(let arr) = value else { return Self.typeError(path: path, expected: "array", got: value) }
            if let min = minItems, arr.count < min { return "\(path) array too short: \(arr.count) < \(min)" }
            if let max = maxItems, arr.count > max { return "\(path) array too long: \(arr.count) > \(max)" }
            for (i, element) in arr.enumerated() {
                if let issue = items.validate(element, path: "\(path)[\(i)]", depth: depth + 1, budget: &budget) {
                    return issue
                }
            }
            return nil
        case .object(let properties, let required, let additionalProperties):
            guard case .object(let obj) = value else { return Self.typeError(path: path, expected: "object", got: value) }
            for key in required where obj[key] == nil {
                return "\(path) missing required key '\(key)'"
            }
            for (key, child) in obj {
                if let propertySchema = properties[key] {
                    if let issue = propertySchema.validate(child, path: "\(path).\(key)", depth: depth + 1, budget: &budget) {
                        return issue
                    }
                } else if !additionalProperties {
                    return "\(path) has unexpected key '\(key)'"
                }
            }
            return nil
        case .oneOf(let alternatives):
            // Short-circuit on the first matching alternative. Strict
            // JSON Schema requires exactly one, but for a verifier the
            // extra scans across the remaining alternatives are wasted
            // work and an adversary could otherwise force quadratic
            // validation by stacking ambiguous schemas.
            for alt in alternatives {
                if alt.validate(value, path: path, depth: depth + 1, budget: &budget) == nil {
                    return nil
                }
            }
            return "\(path) does not match any of the alternatives"
        case .any:
            return nil
        }
    }

    private static func typeError(path: String, expected: String, got: JSONValue) -> String {
        "\(path) expected \(expected), got \(got.kind)"
    }
}

/// Discriminated union over the JSON value space. Constructed from
/// `Foundation`'s `JSONSerialization` output via ``from(_:)``.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Human-readable category name (`"string"`, `"integer"`, etc.).
    public var kind: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .double: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// Short, low-noise debug description.
    public var describe: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .integer(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .bool(let b): return "\(b)"
        case .null: return "null"
        case .array: return "[…]"
        case .object: return "{…}"
        }
    }

    static func from(_ raw: Any) -> JSONValue {
        if raw is NSNull { return .null }
        if let n = raw as? NSNumber {
            // CFBoolean is a subclass of NSNumber. Distinguish by objCType.
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" {
                return .bool(n.boolValue)
            }
            if Double(n.intValue) == n.doubleValue && !type.contains("d") && !type.contains("f") {
                return .integer(n.intValue)
            }
            return .double(n.doubleValue)
        }
        if let s = raw as? String { return .string(s) }
        if let a = raw as? [Any] { return .array(a.map(Self.from)) }
        if let o = raw as? [String: Any] {
            var result: [String: JSONValue] = [:]
            for (k, v) in o { result[k] = Self.from(v) }
            return .object(result)
        }
        return .null
    }
}
