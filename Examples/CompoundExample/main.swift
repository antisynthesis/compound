import Foundation
import FoundationModels
import Compound

// End-to-end demonstration of the Compound pattern wired against Apple's
// on-device Foundation Models.
//
// This file is NOT part of `swift build` because it uses the @Generable
// macro from FoundationModels, which requires the FoundationModelsMacros
// compiler plugin bundled only with full Xcode (not in CommandLineTools).
// To run: open the package in Xcode 26 and add this file as an executable
// target, or compile against the Apple Intelligence-enabled SDK there.

@Generable
struct CityArgs {
    @Guide(description: "Lowercased ASCII city name, e.g. 'paris'")
    let city: String
}

struct GetWeatherTool: Tool {
    let name = "get_weather"
    let description = "Look up the current weather for a city by name."

    func call(arguments: CityArgs) async throws -> String {
        let normalized = arguments.city.lowercased()
        let table: [String: String] = [
            "paris": "13°C, light rain",
            "tokyo": "22°C, clear",
            "san francisco": "16°C, foggy",
        ]
        return table[normalized] ?? "unknown city: \(normalized)"
    }
}

@main
struct Demo {
    static func main() async {
        let cityArgsVerifier = AnyVerifier<CityArgs>(
            name: "city-nonempty",
            cost: .schema
        ) { args, _ in
            if args.city.isEmpty {
                return .repair(Diagnostic(verifier: "city-nonempty", message: "city must not be empty"))
            }
            if args.city.count > 64 {
                return .repair(Diagnostic(verifier: "city-nonempty", message: "city name suspiciously long"))
            }
            return .pass
        }

        let outputChain = VerifierChain<String>(name: "answer-checks", [
            LengthVerifier(min: 1, max: 600).erased(),
            PredicateVerifier<String>(
                name: "on-topic",
                suggestion: "answer the user's weather question explicitly",
                failureMessage: "answer did not mention weather or a temperature",
                predicate: { text in
                    let lower = text.lowercased()
                    return lower.contains("weather") || lower.contains("°c") || lower.contains("°f")
                }
            ).erased(),
        ])

        var tools = ToolRegistry()
        tools.register(
            GetWeatherTool(),
            requiredScopes: ["weather.read"],
            argumentVerifiers: [cityArgsVerifier]
        )

        let assembler: any ContextAssembler
        do {
            assembler = DefaultContextAssembler(
                baseInstructions: """
                You are a concise weather assistant. When the user asks about \
                weather for a city, call get_weather with the city name. \
                Mention the word 'weather' in your final answer.
                """,
                retriever: EmptyRetriever(),
                redactors: [try CommonRedactors.email()],
                policy: ScopeRequirement()
            )
        } catch {
            print("failed to construct assembler: \(error)")
            return
        }

        let tracer = InMemoryTracer()

        let session = CompoundSession(
            .init(
                assembler: assembler,
                tools: tools,
                outputVerifier: outputChain,
                policy: ScopeRequirement(),
                tracer: tracer,
                budget: Budget(
                    maxTurns: 4,
                    maxToolCalls: 2,
                    maxRepairAttempts: 2,
                    wallClock: .seconds(45)
                )
            )
        )

        guard session.isAvailable() else {
            print("⚠️  Apple Foundation Models unavailable: \(session.availability())")
            print("    Try this demo on a device with Apple Intelligence enabled.")
            return
        }

        let auth = AuthContext(principal: "demo-user", scopes: ["weather.read"])

        do {
            let outcome = try await session.respond(
                to: "What's the weather in Paris?",
                auth: auth
            )
            print("---answer---")
            print(outcome.output)
            print("")
            print("---usage---")
            print("turns=\(outcome.usage.turns) tools=\(outcome.usage.toolCalls) repairs=\(outcome.usage.repairAttempts)")
        } catch {
            print("run failed: \(error)")
        }

        print("")
        print("---trace---")
        let events = await tracer.snapshot()
        for e in events {
            print("  \(e.label)")
        }
    }
}
