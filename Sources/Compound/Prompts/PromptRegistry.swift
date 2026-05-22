import Foundation

/// The system of record for production prompts — because a prompt you can't
/// name a version of is a prompt you can't trust, reproduce, or roll back.
///
/// `PromptRegistry` holds every named template at every released
/// version, so an older version stays reachable for A/B comparison,
/// rollback, or replay against a fixed eval set. History is not optional.
/// Templates are immutable once registered; updates land as new versions,
/// never as edits in place.
///
/// Each template has a *pinned* version that ``template(named:version:)``
/// resolves to when no explicit version is requested.
public struct PromptRegistry: Sendable {
    private var byName: [String: [String: PromptTemplate]] = [:]
    private var pinnedVersion: [String: String] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Registers a template version. When `pinned` is `true` (or the
    /// template is new), the pinned-version pointer is set to this
    /// version.
    public mutating func register(_ template: PromptTemplate, pinned: Bool = true) {
        byName[template.name, default: [:]][template.version] = template
        if pinned || pinnedVersion[template.name] == nil {
            pinnedVersion[template.name] = template.version
        }
    }

    /// Resolves a template by name and optional version.
    ///
    /// - Throws: ``PromptError/unknownTemplate(name:)`` if no template
    ///   with `name` is registered, or ``PromptError/unknownVersion(name:version:)``
    ///   if `version` is supplied but not registered.
    public func template(named name: String, version: String? = nil) throws -> PromptTemplate {
        guard let versions = byName[name] else { throw PromptError.unknownTemplate(name: name) }
        let resolvedVersion = version ?? pinnedVersion[name]
        guard let v = resolvedVersion, let template = versions[v] else {
            if let version { throw PromptError.unknownVersion(name: name, version: version) }
            throw PromptError.unknownTemplate(name: name)
        }
        return template
    }

    /// Convenience: resolves a template and renders it with `values`.
    public func render(named name: String, version: String? = nil, values: [String: String] = [:]) throws -> String {
        try template(named: name, version: version).render(values)
    }

    /// Returns the sorted list of versions registered for `name`.
    public func versions(of name: String) -> [String] {
        guard let versions = byName[name] else { return [] }
        return Array(versions.keys).sorted()
    }

    /// Sorted list of registered template names.
    public var names: [String] {
        Array(byName.keys).sorted()
    }

    /// Repoints the pinned version of `name` to `version`.
    ///
    /// - Throws: ``PromptError/unknownVersion(name:version:)`` if no such
    ///   version is registered.
    public mutating func pin(_ name: String, to version: String) throws {
        guard let versions = byName[name], versions[version] != nil else {
            throw PromptError.unknownVersion(name: name, version: version)
        }
        pinnedVersion[name] = version
    }

    /// Returns the currently pinned version for `name`, if any.
    public func pinnedVersion(of name: String) -> String? {
        pinnedVersion[name]
    }
}
