import Foundation
import FoundationModels
@testable import Compound

// Shared machinery for the golden eval suite (see GoldenSuite.swift).
//
// Everything here is deterministic and off-device: no clock readings, no
// UUIDs, and no `SystemLanguageModel` reach a golden transcript, so the
// stored baseline at Evals/baseline.json diffs only when framework
// behavior changes.

// MARK: - Transcript

/// Accumulates a scenario's observable behavior as `key=value` lines.
///
/// Every line is newline-terminated — including the last — so a predicate
/// asserting `"turns=1\n"` cannot be satisfied by `turns=10`. Build
/// predicates with ``GoldenPredicate/field(_:_:)`` rather than raw
/// substrings so that convention stays in one place.
struct GoldenTranscript: Sendable {
    private var lines: [String] = []

    /// Appends one `key=value` line.
    mutating func put(_ key: String, _ value: String) {
        lines.append("\(key)=\(value)")
    }

    /// Appends an integer-valued line.
    mutating func put(_ key: String, _ value: Int) {
        put(key, String(value))
    }

    /// Appends a boolean-valued line (`true` / `false`).
    mutating func put(_ key: String, _ value: Bool) {
        put(key, value ? "true" : "false")
    }

    /// Records a thrown error's *stable* attributes. Deliberately omits
    /// elapsed time and any usage field that a clock could perturb, so an
    /// error transcript is byte-identical across runs.
    mutating func put(error: any Error) {
        guard let compound = error as? CompoundError else {
            put("outcome", "error")
            put("detail", String(describing: error))
            return
        }
        switch compound {
        case .budgetExhausted(let kind, let usage):
            put("outcome", "budget-exhausted")
            put("kind", kind.rawValue)
            put("turns", usage.turns)
            put("repairs", usage.repairAttempts)
            put("tool-calls", usage.toolCalls)
        case .verifierRejected(let reason, _):
            put("outcome", "rejected")
            put("reason", reason)
        case .escalationRequired(let reason, _):
            put("outcome", "escalated")
            put("reason", reason)
        default:
            put("outcome", "error")
            put("detail", compound.description)
        }
        put("layer", compound.layer.rawValue)
        put("severity", compound.severity == .terminal ? "terminal" : "recoverable")
    }

    /// The rendered transcript: one newline-terminated line per field.
    var rendered: String {
        lines.map { $0 + "\n" }.joined()
    }
}

// MARK: - Predicates

/// Predicate constructors matching ``GoldenTranscript``'s line convention.
enum GoldenPredicate {
    /// Requires the transcript to contain exactly the line `key=value`.
    static func field(_ key: String, _ value: String) -> any EvalPredicate {
        ContainsPredicate("\(key)=\(value)\n")
    }

    /// Requires the transcript to contain the line `key=<int>`.
    static func field(_ key: String, _ value: Int) -> any EvalPredicate {
        field(key, String(value))
    }

    /// Requires the transcript to contain the line `key=true`/`key=false`.
    static func field(_ key: String, _ value: Bool) -> any EvalPredicate {
        field(key, value ? "true" : "false")
    }

    /// Requires `needle` to appear anywhere in the transcript. Use for
    /// diagnostic prose (rule ids, reject reasons) where the surrounding
    /// text is not part of the contract.
    static func mentions(_ needle: String) -> any EvalPredicate {
        ContainsPredicate(needle)
    }

    /// Requires `needle` to appear nowhere in the transcript. The workhorse
    /// of the redaction cases: a leaked secret is an absence assertion.
    static func absent(_ needle: String) -> any EvalPredicate {
        DoesNotContainPredicate(needle)
    }
}

// MARK: - Fakes

/// Model transport driven by a fixed script. Each `respond` consumes the
/// next step; the final step repeats once the script is exhausted, so a
/// scenario that loops until its budget trips does not need to enumerate
/// every turn.
///
/// Records every prompt it was handed, which is how the repair-prompt
/// cases assert on what the loop actually sent back to the model.
actor GoldenScriptedModel: ModelResponding {
    /// One scripted turn.
    enum Step: Sendable {
        /// Return this string.
        case reply(String)
        /// Throw this error.
        case fail(CompoundError)
    }

    private var steps: [Step]
    /// Prompts received, in order.
    private(set) var prompts: [String] = []
    /// Number of `respond` invocations (retries included).
    var calls: Int { prompts.count }

    init(_ steps: Step...) {
        self.steps = steps.isEmpty ? [.reply("")] : steps
    }

    func respond(to prompt: String, options _: GenerationOptions) async throws -> String {
        prompts.append(prompt)
        let step = steps.count > 1 ? steps.removeFirst() : steps[0]
        switch step {
        case .reply(let text): return text
        case .fail(let error): throw error
        }
    }

    func respondGenerating<T: Generable & Sendable>(
        _: T.Type,
        to _: String,
        options _: GenerationOptions
    ) async throws -> T {
        // The golden suite drives the typed loop through an injected
        // `extract` closure, never through guided generation — the macro
        // plugin and the on-device model are both off limits here.
        throw CompoundError.modelUnavailable(reason: "golden suite does not use guided generation")
    }
}

/// Monotonic counter for scenarios whose behavior must differ between
/// the first and subsequent invocations (typed repair, mainly).
actor GoldenCounter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

/// Structured value produced by the typed-loop scenarios. `description`
/// is pinned because the loop renders extracted values with
/// `String(describing:)` when building a repair prompt.
struct GoldenTicket: Sendable, Equatable, CustomStringConvertible {
    let title: String
    let priority: Int
    var description: String { "ticket(title=\(title), priority=\(priority))" }
}

// MARK: - Scenario helpers

/// Verifier constructors used across several scenarios.
enum GoldenVerifiers {
    /// Always passes.
    static let alwaysPass = AnyVerifier<String>(name: "always-pass", cost: .parse) { _, _ in .pass }

    /// Passes when the output contains `needle`, otherwise asks for a repair.
    static func requires(_ needle: String, named name: String) -> AnyVerifier<String> {
        AnyVerifier<String>(name: name, cost: .parse) { output, _ in
            output.contains(needle)
                ? .pass
                : .repair(Diagnostic(
                    verifier: name,
                    message: "output must contain '\(needle)'",
                    suggestion: "include '\(needle)'"
                ))
        }
    }

    /// Always asks for a repair — drives the budget-exhaustion scenarios.
    static let alwaysRepairs = AnyVerifier<String>(name: "never-satisfied", cost: .parse) { _, _ in
        .repair(Diagnostic(verifier: "never-satisfied", message: "never satisfied"))
    }

    /// Chain wrapping a single member.
    static func chain(_ members: AnyVerifier<String>...) -> VerifierChain<String> {
        VerifierChain(name: "golden", members)
    }
}

/// Runs a control loop and renders its outcome into a transcript. Both the
/// success and failure paths land in the same shape so predicates can key
/// on `outcome=` uniformly.
enum GoldenLoop {
    static func run(
        _ loop: ControlLoop,
        model: any ModelResponding,
        prompt: String,
        context: RunContext = RunContext()
    ) async -> GoldenTranscript {
        var t = GoldenTranscript()
        do {
            let outcome = try await loop.run(prompt: prompt, modelClient: model, runContext: context)
            t.put("outcome", "ok")
            t.put("output", outcome.output)
            t.put("turns", outcome.usage.turns)
            t.put("repairs", outcome.usage.repairAttempts)
        } catch {
            t.put(error: error)
        }
        return t
    }

    /// Typed counterpart of ``run(_:model:prompt:context:)``.
    static func runTyped(
        _ loop: ControlLoop,
        model: any ModelResponding,
        prompt: String,
        mode: TypedRunMode,
        extract: @escaping @Sendable (String) async throws -> GoldenTicket,
        verifiers: VerifierChain<GoldenTicket> = .empty(),
        context: RunContext = RunContext()
    ) async -> GoldenTranscript {
        var t = GoldenTranscript()
        do {
            let outcome = try await loop.run(
                prompt: prompt,
                modelClient: model,
                runContext: context,
                mode: mode,
                extract: extract,
                verifiers: verifiers
            )
            t.put("outcome", "ok")
            t.put("value", outcome.value.description)
            t.put("reasoning", outcome.reasoning ?? "none")
            t.put("turns", outcome.usage.turns)
            t.put("repairs", outcome.usage.repairAttempts)
        } catch {
            t.put(error: error)
        }
        return t
    }
}

/// Renders a single verifier's verdict on one input. The red-team cases
/// are exactly this: a hostile string in, a pinned verdict out.
enum GoldenGateProbe {
    static func verdict<V: Verifier>(of verifier: V, on input: String) async -> GoldenTranscript
    where V.Input == String {
        var t = GoldenTranscript()
        t.put("verifier", verifier.name)
        do {
            switch try await verifier.verify(input, context: RunContext()) {
            case .pass:
                t.put("verdict", "pass")
            case .repair(let d):
                t.put("verdict", "repair")
                t.put("reason", d.message)
            case .reject(let d):
                t.put("verdict", "reject")
                t.put("reason", d.message)
            case .escalate(let d):
                t.put("verdict", "escalate")
                t.put("reason", d.message)
            }
        } catch {
            t.put("verdict", "threw")
            t.put("detail", String(describing: error))
        }
        return t
    }
}
