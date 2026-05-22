import Foundation

/// A prompt is code. Treating it as a loose string you paste in is a lie
/// waiting to happen — it ships unversioned, untested, and unaccountable.
/// This is the refusal of that: a typed template with explicit parameters,
/// versioned and swappable like the production artifact it always was.
///
/// A `PromptTemplate` pairs a body containing `{{name}}` placeholders
/// with a declared parameter list and a version string. Substitution is
/// deterministic and unforgiving: missing required parameters throw,
/// unknown placeholders throw, and unknown parameter names throw. Nothing
/// is allowed to fail quietly and pretend it worked.
public struct PromptTemplate: Sendable, Equatable, Hashable {
    /// Stable template name.
    public let name: String
    /// Version string. Convention: semver-style or a content hash.
    public let version: String
    /// Template body containing `{{placeholder}}` substitutions.
    public let body: String
    /// Declared parameters; missing requireds cause render-time errors.
    public let parameters: [Parameter]

    /// A declared input to a ``PromptTemplate`` — named, accounted for, and
    /// impossible to forget by accident.
    public struct Parameter: Sendable, Equatable, Hashable {
        /// Parameter name as it appears between `{{ }}`.
        public let name: String
        /// `true` if a value must be supplied at render time.
        public let required: Bool
        /// Default substituted when no value is provided.
        public let defaultValue: String?
        /// Human-readable description (for tooling and tests).
        public let description: String?

        /// Creates a parameter declaration.
        public init(name: String, required: Bool = true, defaultValue: String? = nil, description: String? = nil) {
            self.name = name
            self.required = required
            self.defaultValue = defaultValue
            self.description = description
        }
    }

    /// Creates a template.
    public init(name: String, version: String, body: String, parameters: [Parameter] = []) {
        self.name = name
        self.version = version
        self.body = body
        self.parameters = parameters
    }

    /// Resolves `values` into ``body`` and refuses to hand back anything
    /// half-rendered. Every declared required parameter must have a value,
    /// no unknown keys may be passed, and every placeholder must be
    /// substituted — a leaked `{{token}}` is a bug, not output.
    ///
    /// - Throws: ``PromptError/missingParameter(name:template:)`` if a
    ///   required parameter is omitted,
    ///   ``PromptError/unknownParameter(name:template:)`` if `values`
    ///   contains an undeclared key, or
    ///   ``PromptError/unsubstitutedPlaceholder(placeholder:template:)``
    ///   if a `{{...}}` token remains after substitution.
    public func render(_ values: [String: String] = [:]) throws -> String {
        var resolved: [String: String] = [:]
        for param in parameters {
            if let v = values[param.name] {
                resolved[param.name] = v
            } else if let d = param.defaultValue {
                resolved[param.name] = d
            } else if param.required {
                throw PromptError.missingParameter(name: param.name, template: "\(name)@\(version)")
            }
        }
        // Reject extra keys so a typo in a parameter name surfaces here, not
        // by silently failing to substitute.
        let declared = Set(parameters.map(\.name))
        for key in values.keys where !declared.contains(key) {
            throw PromptError.unknownParameter(name: key, template: "\(name)@\(version)")
        }

        // Substitute {{name}} placeholders. Verify no placeholders remain
        // unsubstituted after the pass; an unknown placeholder is a template
        // bug and surfaced as an error rather than silently leaked.
        var rendered = body
        for (k, v) in resolved {
            rendered = rendered.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        if let leftover = Self.findUnsubstituted(rendered) {
            throw PromptError.unsubstitutedPlaceholder(placeholder: leftover, template: "\(name)@\(version)")
        }
        return rendered
    }

    static func findUnsubstituted(_ text: String) -> String? {
        guard let openRange = text.range(of: "{{") else { return nil }
        let after = text[openRange.upperBound...]
        guard let closeRange = after.range(of: "}}") else { return nil }
        return String(after[..<closeRange.lowerBound])
    }
}

/// The ways a prompt can betray you, named explicitly so they surface loud
/// instead of leaking silently. Thrown by ``PromptTemplate`` and ``PromptRegistry``.
public enum PromptError: Error, Equatable, CustomStringConvertible {
    /// A required parameter had no caller-supplied value and no default.
    case missingParameter(name: String, template: String)
    /// `values` contained a key not declared in the template.
    case unknownParameter(name: String, template: String)
    /// A `{{...}}` token remained in the rendered output.
    case unsubstitutedPlaceholder(placeholder: String, template: String)
    /// Registry lookup failed: no template with this name.
    case unknownTemplate(name: String)
    /// Registry lookup failed: the named template exists but not at this version.
    case unknownVersion(name: String, version: String)

    /// Human-readable description for diagnostics.
    public var description: String {
        switch self {
        case .missingParameter(let n, let t): return "missing parameter '\(n)' for template \(t)"
        case .unknownParameter(let n, let t): return "unknown parameter '\(n)' for template \(t)"
        case .unsubstitutedPlaceholder(let p, let t): return "unsubstituted placeholder '\(p)' in template \(t)"
        case .unknownTemplate(let n): return "unknown template '\(n)'"
        case .unknownVersion(let n, let v): return "unknown version '\(v)' of template '\(n)'"
        }
    }
}
