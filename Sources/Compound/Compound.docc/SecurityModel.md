# Security Model

The deterministic perimeter Compound applies to model output, tool arguments, file system access, network egress, and child processes.

## Overview

Compound treats the model as an untrusted proposer. The perimeter that gates what reaches the device, the network, or the file system lives in deterministic Swift code: schemes are allow-listed, hosts are resolved before they are fetched, paths are canonicalized before they are matched, shell commands are tokenized before they are checked, regex patterns are bounded, and JSON inputs run against depth and node budgets. The framework does not rely on the model declining to misbehave.

## URL and host gating

``URLSafetyVerifier`` is the first gate for any URL-shaped argument. It runs scheme allow-listing (HTTPS by default), host allow/block lists, and IP canonicalization.

IP canonicalization goes through `inet_pton` for both IPv4 and IPv6 so that octal (`0177.0.0.1`), hex (`0x7f.0.0.1`), decimal-integer (`2130706433`), IPv4-mapped IPv6 (`::ffff:127.0.0.1`), CGNAT, NAT64, Teredo, ULA, link-local, and loopback all collapse to the same blocked space. The AWS metadata IP `169.254.169.254` is blocked by default. Non-ASCII hostnames are rejected outright to short-circuit IDN homograph attempts.

## SSRF pre-resolution in WebFetchTool

``WebFetchTool`` resolves the hostname itself through a ``HostResolver`` protocol (default ``SystemHostResolver``, backed by `getaddrinfo`) before issuing the request. Every A and AAAA record is validated against the same block list the URL verifier uses; if any resolved address falls into a blocked range the request is rejected before the socket opens. The response is read through `URLSession.bytes(for:)` so the byte cap is enforced mid-stream rather than after the full body is buffered. `CancellationError` is re-thrown rather than swallowed.

## Path safety

``PathSafetyVerifier`` percent-decodes the input, applies NFC normalization, then case-folds before checking the result is contained inside the configured workspace root. Symlinks are resolved before the containment check. ``PathDenyListVerifier`` carries a default deny list covering `.git`, `.env`, SSH keys, AWS credentials (`.aws/`, service-account JSON), `.kube/` and kubeconfig, `.docker/config.json`, gcloud, `.npmrc`, `.pypirc`, `hosts.yml`, `*.tfstate`, `.terraformrc`, `.netrc`, PEM, PFX, and keystore files.

## Shell safety

``ShellAllowListVerifier`` rejects every command whose first word is not in the allowlist. It also rejects inspection-escape interpreters (`bash`, `sh`, `zsh`, `python`, `node`, `env`, `xargs`, `nohup`, `setsid`, `time`, `ssh`, `timeout`) and `find -exec` / `find -delete` unless the caller opts in via `allowShellEscapes: true`.

``ShellDangerousFlagsVerifier`` matches `rm -rf` case-insensitively, catches the long-flag variants (`--recursive`, `--force`), and uses a broad target set that covers `/Users`, `/System`, `/Applications`, `/Library`, `/opt`, `/private`, `/tmp`, `/Volumes`, `/Network`, `/dev`, `/usr/local`, single-segment absolute paths, and `$HOME` / `${HOME}` / `$PWD` / `${PWD}` expansions. It also flags sudo, `git --no-verify` / `--force` / `reset --hard`, fork bombs, `dd` to raw devices, `mkfs`, `chmod 777`, `curl | sh`, and redirection into `/etc`, `/usr`, `/var`.

## Trace redaction

``RedactingTracer`` is a decorator that wraps any ``Tracer`` and runs reject reasons, diagnostic messages, and tool names through a chain of ``Redactor`` instances before they reach the inner tracer. The intended pattern is `RedactingTracer(inner: JSONLTracer(...), redactors: [...])` so persisted traces never carry raw secrets. ``OSLogTracer/PrivacyLevel`` controls whether free-form fields are marked `.private` to the unified log; the default is `.balanced`.

## Memory is user data

Memory persists what a user said, so it gets treated as user data on both directions of travel. See <doc:MemoryModel> for the full model.

**Redaction runs on the way in, not only on the way out.** If any configured ``Redactor`` *changes* a candidate fact's text, the candidate is **rejected outright** rather than stored in redacted form. Two reasons: a redacted span is no longer a verbatim span, so the extractive write path's invariant would be void; and a fact that contains a secret should not be persisted at all. The rejection is counted and traced as `event=rejected reason=redactionFired`.

**Claims are extractive, never authored.** A fact's text must be a literal substring of a message the record *names* as its evidence — a span found elsewhere in the transcript does not count, because accepting it would make the provenance pointer decorative. This is the highest-value guard available for a small on-device writer: syntactic validity is not evidence of correctness, so an extractive-only write path eliminates hallucinated memories at essentially zero cost. The same rule binds the optional model hooks, which can only select among pre-computed spans or pick an index into a supplied list — never supply text, never name an id they were not given.

**Recalled memory is as inert as a retrieved document.** Facts and archived rounds enter assembly as `RetrievedSource`s, pass through the same single `.retrievedSources` redaction pass, and are fenced by the same ``PromptFrame``. Fence-shaped text inside a stored fact is escaped, not parsed. There is deliberately no `.memory` bit on ``RedactionScope``: memory is already covered by `.retrievedSources`, and adding a bit would change what `.all` means for every existing caller while buying nothing.

**Provenance is defense in depth, not a mitigation.** Every record carries a ``MemoryOrigin`` trust rank, and non-user-stated origins must clear a higher confidence bar to be admitted. Be precise about what that is worth: reported memory-poisoning success rates run 34–67%, and the most vulnerable configuration was the one that auto-injects memory into the prompt. Provenance binding aids debuggability and raises the cost of a poisoning write; it is **not** a validated defense and is not a reason to relax any other control.

**Destructive deletion is a separate path.** Invalidation (bi-temporal, recoverable) and purge (destructive, compliance-shaped) never share code. ``PurgePredicate`` matches on exact normalized subject only — no substring, no prefix, no similarity — because substring matching is precisely the prefix-collision failure mode, and semantic similarity is the wrong primitive for a deletion someone is legally entitled to. Consolidation and the forgetting sweep can never reach the purge path; a spy store asserts that in the test suite.

## Sanitized child process environment

``DefaultProcessRunner`` builds child processes with a sanitized environment by default: only `PATH`, `HOME`, `TMPDIR`, `LANG`, and `LC_ALL` are propagated. To inherit the parent's environment (for `swift build` against a developer toolchain, for example) pass `inheritEnvironment: true` at construction.

## Regex and schema bounds

Every pattern in ``SecretsVerifier`` and ``PIIVerifier`` has bounded quantifiers and an `inputSizeLimit` short-circuit so adversarial input cannot push the regex engine into superlinear time. ``JSONSchemaVerifier`` carries `maxDepth: 64` and `maxNodes: 10_000` budgets that reject pathologically nested or wide documents before the schema walker runs. `oneOf` short-circuits on the first matching branch.

## Tool argument verification

Every tool registered with the ``ToolRegistry`` passes its decoded arguments through a chain of ``Verifier`` instances before the tool's `call(arguments:)` method runs. Argument rejections surface as ``CompoundError/toolArgumentRejected(name:diagnostic:)`` so callers can route argument-time failures separately from output-time failures.

## Forward-compatible error routing

``CompoundError`` carries ``CompoundError/Severity`` and ``CompoundError/Layer`` accessors so dashboards and alert routing can branch without parsing the description string. ``CompoundError/cancelled`` is the framework-boundary wrapper for `CancellationError`; ``CompoundError/toolArgumentRejected(name:diagnostic:)`` is the distinct case for argument-time verifier failures.
