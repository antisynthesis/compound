# Security Policy

## Supported versions

This project is in active development. Only the latest tagged release receives security fixes. The `main` branch is treated as the next release and is patched first.

| Version | Status |
| --- | --- |
| `main`  | Patched |
| Latest tag | Patched |
| Older tags | Best effort, no guarantee |

## Reporting a vulnerability

Do **not** open a public GitHub issue for vulnerabilities. Email the maintainers (see the address in the repository's `git log` or repo profile) with:

- A description of the issue and its impact.
- A minimal reproducer if available.
- The version (commit hash) you observed it on.
- Any suggested remediation.

We'll acknowledge receipt within five business days and aim to publish a fix or mitigation within thirty. We coordinate disclosure with the reporter; we will not name you publicly unless you ask us to.

## Scope

In-scope: vulnerabilities in the framework code shipped under `Sources/Compound/`. Examples include:

- A verifier that returns `.pass` for an input it should reject (gate-bypass).
- A control-loop bug that bypasses budget enforcement.
- A path verifier that allows escape from a workspace root.
- A secret pattern that fails to detect a published credential format.
- An information leak through `Tracer`, `JSONLTracer`, or trace event payloads.
- A redactor that allows redacted content to reach the model.

Out-of-scope: vulnerabilities in dependencies (file with the dependency), vulnerabilities in Apple's `FoundationModels` or other Apple frameworks (file with Apple Security), and theoretical attacks that require an attacker already in possession of full device access.

## Threat model

The **model** is treated as a beautiful liar — fluent, confident, and at any moment willing to be talked into the wrong thing by a sufficiently clever input. Its output is **untrusted**. Every public interface that crosses the deterministic boundary — `Verifier`, `Tool`, `Policy`, `Redactor` — is in scope for misuse-resistance review. If you can make one of them pass something it should have refused, that is a bug we want to hear about.

The framework treats the **device** and the **host process** as trusted. We do not protect against an attacker who can already execute arbitrary code inside the app's process; that is a defense-in-depth concern of the embedding application, not this library's perimeter.
