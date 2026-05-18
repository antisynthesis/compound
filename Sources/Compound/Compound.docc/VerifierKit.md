# Verifier Kit

The deterministic disposers shipped with Compound, organized by what they gate.

## Overview

A ``Verifier`` is a deterministic function from a model output (plus context) to a ``Verdict``. The system's reliability bound is the verifier's reliability bound, so verifiers are first-class with their own protocol, cost metadata, and chain composition. Verifiers in a ``VerifierChain`` run cheapest-first and short-circuit on the first non-pass.

The cardinal rule: a verifier must be more reliable than the model on the property being checked, otherwise it adds nothing and may add false confidence. A verifier that itself depends on a model judging another model's output is not a verifier — it is a second sample.

## Edit flow

Gates `str_replace`-style edits — the load-bearing case in code-editing agents.

- ``ProposedEdit`` — `(path, oldString, newString)`
- ``ExactMatchEditVerifier`` — `oldString` must occur exactly once in the file
- ``NoOpEditVerifier`` — `oldString != newString`
- ``EditAppliedVerifier`` — post-edit invariant: `oldString` gone, `newString` present

## Paths

- ``PathSafetyVerifier`` — percent-decodes, NFC-normalizes, and case-folds the input before checking it resolves inside the workspace root after symlink resolution
- ``PathDenyListVerifier`` — defaults block `.git`, `.env`, SSH keys, AWS creds (`.aws/`, service-account JSON), `.kube/` and kubeconfig, `.docker/config.json`, gcloud, `.npmrc`, `.pypirc`, `hosts.yml`, `*.tfstate`, `.terraformrc`, `.netrc`, PEM, PFX, keystores

## Shell

- ``ShellTokenizer`` — pragmatic POSIX-flavored tokenizer (handles quoting, escapes, sequence and redirection operators)
- ``ShellAllowListVerifier`` — first word of each pipeline segment must be in the allowlist. Inspection escapes (`bash`, `sh`, `zsh`, `python`, `node`, `env`, `xargs`, `nohup`, `setsid`, `time`, `ssh`, `timeout`) and `find -exec` / `find -delete` are rejected by default; opt in via `allowShellEscapes: true`.
- ``ShellDangerousFlagsVerifier`` — case-insensitive `rm -rf` with long-flag variants (`--recursive`, `--force`), expanded target set (`/Users`, `/System`, `/Applications`, `/Library`, `/opt`, `/private`, `/tmp`, `/Volumes`, `/Network`, `/dev`, `/usr/local`, single-segment absolute paths, `$HOME`/`${HOME}`/`$PWD`/`${PWD}`), `sudo`, `git --no-verify` / `--force` / `reset --hard`, fork bombs, `dd` to raw devices, `mkfs`, `chmod 777`, `curl | sh`, redirection to `/etc`/`/usr`/`/var`/...

## Patches

- ``UnifiedDiffParseVerifier`` — well-formed headers, hunk counts agree, optional changed-line cap

## Structure

- ``EncodingVerifier`` — NUL bytes, U+FFFD, optional CRLF
- ``BalancedBracketsVerifier`` — tracks brackets through strings and comments
- ``LineCountVerifier`` — min/max line bounds

## Typed JSON

- ``JSONSchemaVerifier`` — pragmatic subset (string / number / integer / boolean / null / literal / array / object / oneOf / any) with bounds, patterns, required keys, `additionalProperties`. Carries `maxDepth: 64` and `maxNodes: 10_000` budgets; `oneOf` short-circuits on the first matching branch.

## URLs

- ``URLSafetyVerifier`` — scheme allow-list, host allow/block lists. Hosts are canonicalized through `inet_pton` for both IPv4 and IPv6, catching octal/hex/decimal-integer IP forms, IPv4-mapped IPv6, CGNAT, NAT64, Teredo, ULA, link-local, and loopback. Default-blocks the AWS metadata IP `169.254.169.254`. Non-ASCII hostnames (IDN homograph attempts) are rejected.

## Build / test gates

- ``ProcessRunner`` — protocol; ``DefaultProcessRunner`` on macOS/Linux, ``StubProcessRunner`` everywhere
- ``SwiftCommandVerifier`` — `swift build` / `swift test`
- ``SwiftSnippetTypecheckVerifier`` — `swiftc -typecheck` against a temp file

## Credentials

``SecretsVerifier`` ships with 21 default rules:

- AWS access keys, session tokens
- GitHub PATs (classic, fine-grained, OAuth, app, user, plus the `ghr_` runner key form)
- Slack tokens and webhooks
- Anthropic API keys (including the `sk-ant-admin01-` admin form), OpenAI keys (including `sk-svcacct-`), Google API keys
- Stripe live and restricted keys
- npm tokens
- SendGrid, Twilio API keys
- JWT-shaped strings
- PEM, OpenSSH, PuTTY private key blocks

Configurable rule list and rejection mode (`.reject` default, `.repair` optional). Every quantifier is bounded and the verifier short-circuits past a configurable `inputSizeLimit` so it stays linear under adversarial input.

## PII

- ``PIIVerifier`` — SSN (skipping dummy 000/666/9xx), credit cards (Luhn-validated), email, US phone, IPv4. Bounded quantifiers and `inputSizeLimit` short-circuit.
- ``NSDataDetectorPIIVerifier`` — Apple-native; phone numbers, addresses, dates, links, transit info (broader recall, higher false-positive on dates)

## Format

- ``UUIDVerifier``, ``ISO8601DateVerifier``, ``SemVerVerifier``
- ``EmailVerifier``, ``PhoneE164Verifier``
- ``HexStringVerifier`` (optional byte-length), ``Base64Verifier`` (standard / URL-safe, padded / unpadded)

## Numeric

- ``NumericRangeVerifier`` (inclusive/exclusive bounds)
- ``ProbabilityVerifier`` (0…1)
- ``SumVerifier`` — parts sum to total within tolerance
- ``MonotonicVerifier`` — strictly / non-strictly ascending or descending

## SQL agents

- ``SQLTokenizer`` — strings, identifiers, keywords, comments, semicolons
- ``SQLSafetyVerifier`` — statement allow-list, multi-statement rejection, WHERE-required on UPDATE/DELETE
- ``SQLStatementKind``

## Markdown

- ``MarkdownStructureVerifier`` — balanced code fences, balanced `[text](url)` brackets and parens, optional max heading level

## Content policy

- ``ProhibitedTermsVerifier`` — exact / case-insensitive / whole-word matches
- ``RequiredTermsVerifier`` — all-required or any-of
- ``ImplicationVerifier`` — cross-field if-then invariants
- ``UniqueElementsVerifier`` — collection elements distinct
- ``CitationVerifier`` — every emitted `[source-id]` is in the retrieved set

## Language

- ``LanguageVerifier`` — `NLLanguageRecognizer`-backed allow-list

## Hash

- ``SHA256HashVerifier`` with `cryptoKit()` factory

## General-purpose

- ``RegexVerifier``, ``LengthVerifier``, ``JSONParseVerifier``, ``PredicateVerifier``

## Combinators

- `Verifier.contramap` — reuse a `Verifier<String>` on a field of a richer input type (e.g. apply ``EncodingVerifier`` to `ProposedEdit.newString`)
- `Verifier.erased()` — to ``AnyVerifier`` for use in ``VerifierChain``

## Building your own

Verifiers should be:

1. Deterministic. Two calls on the same input must return the same verdict.
2. Cheaper than the failure they prevent. A 100ms verifier that prevents a 10-second tool call is excellent. A 10-second verifier that prevents a 100ms one is a regression.
3. Independent of the model. A verifier that uses a model to judge another model's output is not a verifier — it is a second sample.
4. Coverage-aware. A verifier that catches the errors you tested for and not the errors you did not is indistinguishable from a working verifier until production.
