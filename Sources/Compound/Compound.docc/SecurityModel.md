# Security Model

The deterministic perimeter Compound applies to model output, tool arguments, file system access, network egress, and child processes.

## Overview

Compound assumes the model will try to misbehave — not out of malice, but because a fluent system that has read most of the internet can be talked into anything by a sufficiently clever input. So the perimeter that gates what reaches the device, the network, or the file system lives in deterministic Swift code, never in the prompt: schemes are allow-listed, hosts are resolved before they are fetched, paths are canonicalized before they are matched, shell commands are tokenized before they are checked, regex patterns are bounded, JSON inputs run against depth and node budgets. The framework does not rely on the model declining to misbehave. It refuses to give it the option.

## URL and host gating

A URL is the easiest piece of text to weaponize and the hardest to sanitize after the fact. ``URLSafetyVerifier`` is the first gate for any URL-shaped argument. It runs scheme allow-listing (HTTPS by default), host allow/block lists, and IP canonicalization — the model is not the thing that decides whether a URL is safe.

IP canonicalization goes through `inet_pton` for both IPv4 and IPv6 so that octal (`0177.0.0.1`), hex (`0x7f.0.0.1`), decimal-integer (`2130706433`), IPv4-mapped IPv6 (`::ffff:127.0.0.1`), CGNAT, NAT64, Teredo, ULA, link-local, and loopback all collapse to the same blocked space. The AWS metadata IP `169.254.169.254` is blocked by default. Non-ASCII hostnames are rejected outright to short-circuit IDN homograph attempts.

## SSRF pre-resolution in WebFetchTool

``WebFetchTool`` resolves the hostname itself through a ``HostResolver`` protocol (default ``SystemHostResolver``, backed by `getaddrinfo`) before issuing the request. Every A and AAAA record is validated against the same block list the URL verifier uses; if any resolved address falls into a blocked range the request is rejected before the socket opens. The response is read through `URLSession.bytes(for:)` so the byte cap is enforced mid-stream rather than after the full body is buffered. `CancellationError` is re-thrown rather than swallowed.

## Path safety

``PathSafetyVerifier`` percent-decodes the input, applies NFC normalization, then case-folds before checking the result is contained inside the configured workspace root. Symlinks are resolved before the containment check. ``PathDenyListVerifier`` carries a default deny list covering `.git`, `.env`, SSH keys, AWS credentials (`.aws/`, service-account JSON), `.kube/` and kubeconfig, `.docker/config.json`, gcloud, `.npmrc`, `.pypirc`, `hosts.yml`, `*.tfstate`, `.terraformrc`, `.netrc`, PEM, PFX, and keystore files.

## Shell safety

``ShellAllowListVerifier`` rejects every command whose first word is not in the allowlist. It also rejects inspection-escape interpreters (`bash`, `sh`, `zsh`, `python`, `node`, `env`, `xargs`, `nohup`, `setsid`, `time`, `ssh`, `timeout`) and `find -exec` / `find -delete` unless the caller opts in via `allowShellEscapes: true`.

``ShellDangerousFlagsVerifier`` matches `rm -rf` case-insensitively, catches the long-flag variants (`--recursive`, `--force`), and uses a broad target set that covers `/Users`, `/System`, `/Applications`, `/Library`, `/opt`, `/private`, `/tmp`, `/Volumes`, `/Network`, `/dev`, `/usr/local`, single-segment absolute paths, and `$HOME` / `${HOME}` / `$PWD` / `${PWD}` expansions. It also flags sudo, `git --no-verify` / `--force` / `reset --hard`, fork bombs, `dd` to raw devices, `mkfs`, `chmod 777`, `curl | sh`, and redirection into `/etc`, `/usr`, `/var`.

## Trace redaction

A trace that records a secret is a secret. ``RedactingTracer`` is a decorator that wraps any ``Tracer`` and runs reject reasons, diagnostic messages, and tool names through a chain of ``Redactor`` instances before they reach the inner tracer. The intended pattern is `RedactingTracer(inner: JSONLTracer(...), redactors: [...])` so persisted traces never carry raw credentials. ``OSLogTracer/PrivacyLevel`` controls whether free-form fields are marked `.private` to the unified log; the default is `.balanced`.

## Sanitized child process environment

``DefaultProcessRunner`` builds child processes with a sanitized environment by default: only `PATH`, `HOME`, `TMPDIR`, `LANG`, and `LC_ALL` are propagated. To inherit the parent's environment (for `swift build` against a developer toolchain, for example) pass `inheritEnvironment: true` at construction.

## Regex and schema bounds

Every pattern in ``SecretsVerifier`` and ``PIIVerifier`` has bounded quantifiers and an `inputSizeLimit` short-circuit so adversarial input cannot push the regex engine into superlinear time. ``JSONSchemaVerifier`` carries `maxDepth: 64` and `maxNodes: 10_000` budgets that reject pathologically nested or wide documents before the schema walker runs. `oneOf` short-circuits on the first matching branch.

## Tool argument verification

Every tool registered with the ``ToolRegistry`` passes its decoded arguments through a chain of ``Verifier`` instances before the tool's `call(arguments:)` method runs. Argument rejections surface as ``CompoundError/toolArgumentRejected(name:diagnostic:)`` so callers can route argument-time failures separately from output-time failures.

## Forward-compatible error routing

``CompoundError`` carries ``CompoundError/Severity`` and ``CompoundError/Layer`` accessors so dashboards and alert routing can branch without parsing the description string. ``CompoundError/cancelled`` is the framework-boundary wrapper for `CancellationError`; ``CompoundError/toolArgumentRejected(name:diagnostic:)`` is the distinct case for argument-time verifier failures.
