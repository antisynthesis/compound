import Foundation
import FoundationModels

/// A side-effect-free arithmetic evaluator the model can call when it needs
/// to compute a number rather than approximate one. The expression is
/// sandboxed to arithmetic characters before it reaches `NSExpression`, so
/// the tool cannot be abused to invoke arbitrary key-paths or functions.
///
/// The result is returned as a string ("42", "3.14159…") so the caller can
/// embed it back into prose. For multi-step calculations the model is
/// expected to call the tool repeatedly rather than chain in one
/// expression — that keeps each call independently auditable.
public struct CalculatorTool: Tool {
    public typealias Output = String

    public let name: String = "calculator"
    public let description: String = "Evaluate a simple arithmetic expression (numbers, parentheses, + - * /)."
    public let parameters: GenerationSchema
    public let includesSchemaInInstructions: Bool = true

    /// Creates a calculator tool with its argument schema.
    public init() {
        let schema = DynamicGenerationSchema(
            name: "CalculatorArguments",
            description: "Arguments for the calculator tool",
            properties: [
                .init(
                    name: "expression",
                    description: "Arithmetic expression. Allowed characters: digits, decimal points, parentheses, + - * / and whitespace.",
                    schema: DynamicGenerationSchema(type: String.self)
                )
            ]
        )
        // Force-unwrap: the schema is a constant we author; a failure here
        // would be a programmer error, not user input.
        self.parameters = try! GenerationSchema(root: schema, dependencies: [])
    }

    /// Decoded arguments for ``CalculatorTool``.
    public struct Arguments: ConvertibleFromGeneratedContent, Sendable {
        /// Arithmetic expression to evaluate.
        public let expression: String
        /// Decodes `content` into ``Arguments``.
        public init(_ content: GeneratedContent) throws {
            self.expression = try content.value(String.self, forProperty: "expression")
        }
    }

    /// Cap on raw expression length. `NSExpression` parses arbitrarily
    /// deep arithmetic, so unbounded input is a cheap CPU-pinning vector.
    static let maxExpressionLength = 256
    /// Cap on nested parenthesis depth, defending against the same vector
    /// at a lower constant factor than the length cap alone.
    static let maxParenDepth = 32

    /// Evaluates the supplied expression. Returns the numeric result as
    /// a string on success, or a string starting with `"error:"` on any
    /// validation or evaluation failure. Does not throw.
    public func call(arguments: Arguments) async throws -> String {
        let trimmed = arguments.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "error: expression is empty"
        }
        if trimmed.count > Self.maxExpressionLength {
            return "error: expression exceeds \(Self.maxExpressionLength) characters"
        }
        // Reject `NSExpression`'s power operator outright. The allowed-char
        // filter below would catch `**` via the second `*`, but checking
        // explicitly keeps the error message accurate.
        if trimmed.contains("**") {
            return "error: '**' is not supported"
        }
        let allowed = Set("0123456789+-*/.() \t")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else {
            return "error: expression contains disallowed characters"
        }
        // Walk the string once to bound parenthesis depth.
        var depth = 0
        var maxDepth = 0
        for c in trimmed {
            if c == "(" {
                depth += 1
                if depth > maxDepth { maxDepth = depth }
            } else if c == ")" {
                depth -= 1
                if depth < 0 {
                    return "error: unbalanced parentheses"
                }
            }
        }
        if depth != 0 {
            return "error: unbalanced parentheses"
        }
        if maxDepth > Self.maxParenDepth {
            return "error: parenthesis nesting exceeds \(Self.maxParenDepth)"
        }
        let expression = NSExpression(format: trimmed)
        let result = expression.expressionValue(with: nil, context: nil)
        if let number = result as? NSNumber {
            // Render integers without trailing ".0".
            let asDouble = number.doubleValue
            if asDouble.rounded() == asDouble && abs(asDouble) < 1e15 {
                return String(Int64(asDouble))
            }
            return String(asDouble)
        }
        return "error: could not evaluate expression"
    }
}
