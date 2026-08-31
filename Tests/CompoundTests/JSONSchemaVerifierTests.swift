import Foundation
import Testing
@testable import Compound

@Suite("JSONSchemaVerifier")
struct JSONSchemaVerifierTests {
    let userSchema: JSONSchema = .object(
        properties: [
            "name": .string(minLength: 1),
            "age": .integer(min: 0, max: 150),
            "email": .string(pattern: #".+@.+"#),
            "roles": .array(items: .literal([.string("admin"), .string("user")])),
        ],
        required: ["name", "age"]
    )

    @Test("schema passes on valid object")
    func passesValidObject() async throws {
        let v = JSONSchemaVerifier(schema: userSchema)
        let json = #"{"name":"Ada","age":36,"email":"ada@x.org","roles":["admin"]}"#
        #expect((try await v.verify(json, context: RunContext())).isPass)
    }

    @Test("schema repairs on missing required key")
    func repairsMissingRequired() async throws {
        let v = JSONSchemaVerifier(schema: userSchema)
        let json = #"{"name":"Ada"}"#
        let verdict = try await v.verify(json, context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("missing required key"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("schema repairs on wrong type")
    func repairsWrongType() async throws {
        let v = JSONSchemaVerifier(schema: userSchema)
        let json = #"{"name":"Ada","age":"old"}"#
        #expect((try await v.verify(json, context: RunContext())).isRepair)
    }

    @Test("schema enforces integer bounds")
    func enforcesIntBounds() async throws {
        let v = JSONSchemaVerifier(schema: userSchema)
        let json = #"{"name":"Ada","age":-1}"#
        #expect((try await v.verify(json, context: RunContext())).isRepair)
    }

    @Test("schema enforces string pattern")
    func enforcesStringPattern() async throws {
        let v = JSONSchemaVerifier(schema: userSchema)
        let json = #"{"name":"Ada","age":36,"email":"not-an-email"}"#
        #expect((try await v.verify(json, context: RunContext())).isRepair)
    }

    @Test("schema enforces literal values")
    func enforcesLiteralValues() async throws {
        let v = JSONSchemaVerifier(schema: userSchema)
        let json = #"{"name":"A","age":1,"roles":["root"]}"#
        #expect((try await v.verify(json, context: RunContext())).isRepair)
    }

    @Test("schema oneOf accepts matching alternative")
    func oneOfAccepts() async throws {
        let v = JSONSchemaVerifier(schema: .oneOf([.string(), .integer()]))
        #expect((try await v.verify("42", context: RunContext())).isPass)
        #expect((try await v.verify("\"hello\"", context: RunContext())).isPass)
        #expect((try await v.verify("true", context: RunContext())).isRepair)
    }

    @Test("schema rejects unexpected key when additionalProperties false")
    func rejectsUnexpectedKey() async throws {
        let schema: JSONSchema = .object(properties: ["a": .integer()], required: ["a"], additionalProperties: false)
        let v = JSONSchemaVerifier(schema: schema)
        let verdict = try await v.verify(#"{"a":1,"b":2}"#, context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("unexpected key"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("schema repairs on invalid JSON")
    func repairsInvalidJSON() async throws {
        let v = JSONSchemaVerifier(schema: .any)
        #expect((try await v.verify("not json", context: RunContext())).isRepair)
    }

    @Test("schema rejects deeply nested input past maxDepth")
    func rejectsDeeplyNested() async throws {
        var json = "0"
        for _ in 0..<100 {
            json = "{\"a\":\(json)}"
        }
        var schema: JSONSchema = .integer()
        for _ in 0..<100 {
            schema = .object(properties: ["a": schema], required: ["a"])
        }
        let v = JSONSchemaVerifier(schema: schema, maxDepth: 10)
        let verdict = try await v.verify(json, context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("depth budget"))
        } else {
            Issue.record("expected .repair for depth budget exceeded")
        }
    }

    @Test("schema fails closed on an uncompilable pattern")
    func failsClosedOnBadPattern() async throws {
        // An invalid regex used to be skipped (treated as no constraint),
        // so any string passed. It must now reject with an internal error.
        let schema: JSONSchema = .string(pattern: "(")
        let v = JSONSchemaVerifier(schema: schema)
        let verdict = try await v.verify("\"whatever\"", context: RunContext())
        if case .reject(let d) = verdict {
            #expect(d.message.contains("internal verifier error"))
        } else {
            Issue.record("expected .reject for uncompilable pattern, got \(verdict)")
        }
    }

    @Test("schema still enforces a valid nested pattern")
    func enforcesValidNestedPattern() async throws {
        let schema: JSONSchema = .object(properties: ["email": .string(pattern: #".+@.+"#)], required: ["email"])
        let v = JSONSchemaVerifier(schema: schema)
        #expect((try await v.verify(#"{"email":"a@b"}"#, context: RunContext())).isPass)
        #expect((try await v.verify(#"{"email":"nope"}"#, context: RunContext())).isRepair)
    }

    @Test("schema rejects when node budget exceeded")
    func rejectsNodeBudget() async throws {
        var parts: [String] = []
        for i in 0..<200 {
            parts.append("\"k\(i)\":\(i)")
        }
        let json = "{" + parts.joined(separator: ",") + "}"
        var properties: [String: JSONSchema] = [:]
        for i in 0..<200 {
            properties["k\(i)"] = .integer()
        }
        let recursingSchema: JSONSchema = .object(properties: properties, additionalProperties: true)
        let v = JSONSchemaVerifier(schema: recursingSchema, maxNodes: 5)
        let verdict = try await v.verify(json, context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("node budget"))
        } else {
            Issue.record("expected .repair for node budget exceeded")
        }
    }
}
