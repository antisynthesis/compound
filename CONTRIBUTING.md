# Contributing to Compound

Compound is built as a precise instrument, not a kitchen sink. Contributions are welcome — and held to that standard. This document explains the workflow for filing issues, proposing changes, and getting them merged.

## Code of conduct

By participating in this project you agree to abide by the [Contributor Covenant Code of Conduct](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Report unacceptable behavior to the maintainers.

## Discussion before code

For non-trivial changes — new layers, new verifier categories, breaking API edits, dependencies — open an issue first to discuss the design. The public API surface is deliberately small; every new public type is a promise we have to keep forever, so the bar to add one is high. "We might need it later" is not a reason. Show the specific reality that requires it.

## Workflow

1. Fork the repo.
2. Create a topic branch off `main`.
3. Make your change with tests.
4. Run `swift run CompoundTestRunner` and confirm the full suite passes.
5. Open a pull request describing **why** the change is needed and **what** it changes.

## Coding standards

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/). Naming, fluency, brevity, clarity at point of use.
- Public types and members have triple-slash doc comments. Internal types do not need them but benefit from the same care.
- Concurrency: every public type that crosses task boundaries must conform to `Sendable`. Use `@unchecked Sendable` only when the type is actually safe (immutable value semantics or external synchronization) and add a comment explaining why.
- No external dependencies in the core library. Apple platform frameworks (FoundationModels, NaturalLanguage, CryptoKit, OSLog, MetricKit, etc.) are encouraged where they add quality. New dependencies require a strong justification and explicit approval.
- Availability annotations on every type that pulls in a newer-than-base SDK API.

## Commit messages

Compound uses [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). The format is:

```
type(scope): short imperative summary

Optional body explaining why, with paragraphs separated by blank lines.

Co-Authored-By: <if applicable>
```

Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `perf`. Scopes mirror the project structure: `streaming`, `verifiers`, `retrieval`, `eval`, `prompts`, `tools`, `conversation`, `apple`, `core`, `metrics`, etc.

Group changes into commits that represent **units of work** — a verifier and its tests in one commit, not split across two.

## Testing

The test harness is in `Tests/CompoundTestRunner/`. It is a small assertion runner so the package builds on toolchains without XCTest or `swift-testing`. New tests register themselves through the harness:

```swift
enum MyFeatureTests {
    static func register() {
        test("does the thing") {
            // …
        }
    }
}
```

Then add `MyFeatureTests.register()` to `Tests/CompoundTestRunner/Main.swift`.

All tests must pass before a PR is merged. Don't commit failing tests with a "I'll fix it later" plan.

## Verifier contributions

A new verifier is the most common contribution — and a verifier is a load-bearing part of the system, not a stylistic choice. Each one must:

1. Live in `Sources/Compound/Verifiers/`.
2. Conform to `Verifier<Input>` with a `cost` matching the realistic ladder rung. Lying about cost breaks chain ordering for everyone.
3. Be **deterministic**. Two calls on the same input must return the same verdict — or it is a coin, not a verifier.
4. Be **cheaper than the failure it prevents**. A 10-second verifier guarding a 100ms call is a regression.
5. Be **independent of the model**. A verifier that uses a model to judge another model's output is not a verifier — it is a second sample dressed as a guard, and PRs framing it as a verifier will be sent back.
6. Ship with tests that cover the positive case, at least one failure mode per code path, and edge cases (empty input, very long input, mixed content). Coverage you didn't test is indistinguishable from coverage that doesn't exist.

## Documentation

Public API changes update:

- DocC catalog at `Sources/Compound/Compound.docc/`
- Topic entries in `Compound.md`
- An article entry in `GettingStarted.md` if the change is part of the canonical path
- The verifier kit entry in `VerifierKit.md` for new verifiers
- `CHANGELOG.md` under `[Unreleased]`

## License

By contributing you agree that your contributions are licensed under the project's Apache 2.0 license.
