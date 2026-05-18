import Foundation
import Testing
@testable import Compound

@Suite("Prompt")
struct PromptTests {
    @Test("template substitutes named parameters")
    func substitutesParameters() throws {
        let t = PromptTemplate(
            name: "greet",
            version: "1",
            body: "Hello, {{name}}!",
            parameters: [.init(name: "name")]
        )
        let out = try t.render(["name": "Ada"])
        #expect(out == "Hello, Ada!")
    }

    @Test("template fills defaults")
    func fillsDefaults() throws {
        let t = PromptTemplate(
            name: "greet",
            version: "1",
            body: "Hi {{name}}, you're {{role}}.",
            parameters: [
                .init(name: "name"),
                .init(name: "role", required: false, defaultValue: "anonymous"),
            ]
        )
        #expect(try t.render(["name": "Ada"]) == "Hi Ada, you're anonymous.")
    }

    @Test("template rejects missing required")
    func rejectsMissingRequired() {
        let t = PromptTemplate(
            name: "greet",
            version: "1",
            body: "Hi {{name}}",
            parameters: [.init(name: "name")]
        )
        do {
            _ = try t.render()
            Issue.record("expected missingParameter error")
        } catch let e as PromptError {
            if case .missingParameter = e {} else {
                Issue.record("expected missingParameter, got \(e)")
            }
        } catch {
            Issue.record("expected PromptError, got \(error)")
        }
    }

    @Test("template rejects unknown parameter")
    func rejectsUnknownParameter() {
        let t = PromptTemplate(
            name: "greet",
            version: "1",
            body: "Hi {{name}}",
            parameters: [.init(name: "name")]
        )
        do {
            _ = try t.render(["name": "Ada", "extra": "x"])
            Issue.record("expected unknownParameter error")
        } catch let e as PromptError {
            if case .unknownParameter = e {} else {
                Issue.record("expected unknownParameter, got \(e)")
            }
        } catch {
            Issue.record("expected PromptError, got \(error)")
        }
    }

    @Test("template flags unsubstituted placeholders")
    func flagsUnsubstituted() {
        let t = PromptTemplate(
            name: "greet",
            version: "1",
            body: "Hi {{name}} and {{stray}}",
            parameters: [.init(name: "name")]
        )
        do {
            _ = try t.render(["name": "Ada"])
            Issue.record("expected unsubstitutedPlaceholder error")
        } catch let e as PromptError {
            if case .unsubstitutedPlaceholder = e {} else {
                Issue.record("expected unsubstitutedPlaceholder, got \(e)")
            }
        } catch {
            Issue.record("expected PromptError, got \(error)")
        }
    }

    @Test("registry resolves pinned version")
    func registryResolvesPinned() throws {
        var reg = PromptRegistry()
        reg.register(PromptTemplate(name: "g", version: "1", body: "v1"), pinned: true)
        reg.register(PromptTemplate(name: "g", version: "2", body: "v2"), pinned: true)
        #expect(try reg.render(named: "g") == "v2")
        #expect(try reg.render(named: "g", version: "1") == "v1")
    }

    @Test("registry honors explicit pin")
    func registryHonorsExplicitPin() throws {
        var reg = PromptRegistry()
        reg.register(PromptTemplate(name: "g", version: "1", body: "v1"), pinned: true)
        reg.register(PromptTemplate(name: "g", version: "2", body: "v2"), pinned: true)
        try reg.pin("g", to: "1")
        #expect(try reg.render(named: "g") == "v1")
    }

    @Test("registry surfaces unknown template")
    func registryUnknownTemplate() {
        let reg = PromptRegistry()
        do {
            _ = try reg.template(named: "missing")
            Issue.record("expected unknownTemplate")
        } catch let e as PromptError {
            if case .unknownTemplate = e {} else {
                Issue.record("expected unknownTemplate, got \(e)")
            }
        } catch {
            Issue.record("expected PromptError, got \(error)")
        }
    }
}
