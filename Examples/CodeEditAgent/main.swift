// CodeEditAgent — a Claude-Code-style agent that proposes (oldString,
// newString) edits and only applies them when the verifier confirms the
// quotation is real.
//
// A model that edits files by paraphrasing what it remembers will corrupt
// them. This agent gives the model no such latitude: it proposes a
// ProposedEdit, ExactMatchEditVerifier confirms oldString occurs exactly once
// in the actual file before a byte is written, the edit is applied, and
// EditAppliedVerifier confirms the post-state. Path safety and the secret/path
// deny-lists decide what the model is even allowed to reach for.
//
// Open in Xcode 26 to run.

import Foundation
import Compound
import FoundationModels

@main
struct CodeEditAgent {
    static func main() async throws {
        // Workspace root: the only directory the agent is allowed to touch.
        let workspaceRoot = ProcessInfo.processInfo.environment["WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath

        // Argument verifier chain for the edit tool. Path safety first,
        // then deny-list, then the exact-match contract.
        let editArgVerifiers: [AnyVerifier<EditTool.Arguments>] = [
            AnyVerifier(PathSafetyVerifier(workspaceRoot: workspaceRoot)
                .contramap { (args: EditTool.Arguments) in args.path }),
            AnyVerifier(try PathDenyListVerifier()
                .contramap { (args: EditTool.Arguments) in args.path }),
            AnyVerifier(ExactMatchEditVerifier()
                .contramap { (args: EditTool.Arguments) in
                    ProposedEdit(path: args.path, oldString: args.oldString, newString: args.newString)
                }),
        ]

        var toolRegistry = ToolRegistry()
        toolRegistry.register(
            EditTool(),
            requiredScopes: ["files:edit"],
            argumentVerifiers: editArgVerifiers
        )

        let assembler = DefaultContextAssembler(
            baseInstructions: """
                You edit code by proposing (path, oldString, newString) tuples
                via the edit tool. oldString must be the exact text to replace,
                including whitespace. If you are not certain the quotation
                matches the file exactly, ask first.
                """
        )

        let session = CompoundSession(.init(
            assembler: assembler,
            tools: toolRegistry,
            outputVerifier: VerifierChain(name: "output", [
                AnyVerifier(EncodingVerifier()),
                AnyVerifier(SecretsVerifier()),
            ]),
            tracer: CompositeTracer([OSLogTracer(), SignpostTracer()]),
            budget: .default
        ))

        let auth = AuthContext(principal: "developer", scopes: ["files:edit"])
        let outcome = try await session.respond(
            to: "Rename the function `oldName` to `newName` in src/Foo.swift.",
            auth: auth
        )
        print(outcome.output)
    }
}

/// Toy edit tool. In a real app this would write to disk after verification.
/// Here we just echo the proposed edit to confirm wiring.
struct EditTool: Tool {
    typealias Output = String
    let name = "edit"
    let description = "Replace a string in a file. oldString must match exactly once."
    let parameters: GenerationSchema
    let includesSchemaInInstructions = true

    init() {
        let schema = DynamicGenerationSchema(
            name: "EditArguments",
            properties: [
                .init(name: "path", description: "Workspace-relative or absolute path", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "oldString", description: "Text to find", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "newString", description: "Replacement text", schema: DynamicGenerationSchema(type: String.self)),
            ]
        )
        self.parameters = try! GenerationSchema(root: schema, dependencies: [])
    }

    struct Arguments: ConvertibleFromGeneratedContent, Sendable {
        let path: String
        let oldString: String
        let newString: String
        init(_ content: GeneratedContent) throws {
            self.path = try content.value(String.self, forProperty: "path")
            self.oldString = try content.value(String.self, forProperty: "oldString")
            self.newString = try content.value(String.self, forProperty: "newString")
        }
    }

    func call(arguments: Arguments) async throws -> String {
        // In production: read, str-replace, write atomically, verify post-state.
        "applied edit to \(arguments.path)"
    }
}
