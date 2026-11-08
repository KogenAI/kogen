# Overview

This repository is `kogen`, the command-line program that is Kogen's small core. It takes one requested feature through Shape, Build, Verify, Review and Commit in your own Git repository. For Kogen as a whole, see [kogen.dev](https://kogen.dev).

Kogen takes one requested feature through five steps in your own Git repository:

1. **Shape**: a model writes the feature as short prose, executable Gherkin with step definitions, and a Quint model when the change has meaningful state. It inspects the repository and settles material technical questions itself. It finds and retrieves current authoritative external documentation when a task depends on it. It keeps a native record of each documentation lookup. It asks you only about open UI/UX choices.
2. **Build**: after you approve the exact files, Kogen's own model/tool loop ([kogen-loop](../cli/third_party/kogen-loop/README.md)) implements it. Alternatively, an executor you select, such as Kogen's own pinned Claude Code, implements it ([executor contract](executor-contract.md)). Claude Code can likewise independently serve Shape (including Refine) and the independent Review, each as its own fresh session with explicit limitations; this is source capability, not live qualification. Either way, Kogen alone verifies, reviews and commits.
3. **Verify**: the acceptance scenarios run against the real code, with the model check and the project's checks; failures go back to the builder until everything passes.
4. **Review and fix**: an independent reviewer investigates and repairs concrete defects. Kogen verifies changed final files; failures stay with that reviewer. Maintenance preferences are notes. An unresolved substantive blocker stops with preserved work instead of restarting the builder/review loop. A review that ends without any valid verdict does not strand a green candidate: its rejected-verdict and prose-only allowances are separate and each sent back once (the request after a prose-only reminder requires `submit_review` through the provider's named tool selection on routes that support it, ChatGPT, SuperGrok and OpenCode Go; Anthropic's adaptive-thinking route, OpenAI-compatible hosts and external executors keep the text reminder, logged as `text_fallback`; the selection survives a working-window reset, and a text-only answer to the forced request is logged as a `provider_fault` with route and model and is only the ordinary no-tool turn), and the exact verified tree gets one automatic fresh review of the same kind after any verdictless ending, whatever its reason; if the invalid reviewer left uncommitted edits, the fresh review starts from the exact green candidate tree and the discarded paths are logged. If that one also fails the Build stops as `candidate/review_invalid` with a review-only checkpoint.
5. **Commit**: one commit of exactly the verified and reviewed contents, with your own Git configuration.

Reviews keep exact authority and check results in the working window, with complete candidate source/diff in private hash-bound parts when necessary, including when an initially fitting inline review later runs out of continuation room. The reviewer reads every part before approval; missing or changed custody stops safely. This preserves the current context ceiling rather than silently clipping source. An external reviewer (Claude Code) is held to the same ceiling: Kogen measures the exact first prompt of every review session, source included, against the inclusive 524288-byte ceiling before sending it. A prompt that fits is one review in one fresh session, as before. A larger one is reviewed in ordered parts of the exact source, each in its own fresh session whose complete prompt fits and carries the complete authority; only the last part's approval is the review's and a blocking verdict of any part stops the Build. Mandatory review material that leaves fewer than 6000 bytes for source stops as `candidate/context_budget_exceeded` before any review is sent, and Claude Code's own "Prompt is too long" refusal is that same context result, never an ordinary executor failure.

Shape may publish an optional sequential `## Stages` plan before approval when
coherent scoped milestones improve feedback. Its single fenced JSON object has
`version: 1` and an ordered `stages` array (at least two), each with unique slug
`id`, nonblank `title` and `goal`, and a nonempty ordered `checks` command array.
The approval card displays the complete plan; gate helpers belong in Acceptance
or project protection. No plan keeps the ordinary whole-gate route.

Build keeps one approval and the same builder through scoped stages. Each finish
runs fixers, fresh scratch setup and the active stage gate; red repairs stay there.
Clean green milestones retain tree-bound historical evidence and durable
`stage_progress` in result/checkpoint/inspect. Explicit same-checkout Resume keeps
completed milestones without replay; incomplete gates rerun fresh setup. After the
last stage, complete whole-Intent acceptance/model/checks and fresh independent
review are still required before the single commit. Final red stays in finalization.
Stage progress is never delivery or proof for a later edited tree. Substantive plan
changes require ordinary Refine and fresh exact approval; drift refuses continuation.

To explicitly continue a stopped checkpoint-capable Build in the same checkout, run
`kogen intent resume <build-id> [--project <checkout>]`. Resume keeps the candidate and
saved builder or independent reviewer conversation, and reuses only exact completed
green evidence. Explicit resume of `candidate/review_blocked` instead runs fresh setup
and the complete verification gate, returning the original finding and actual results to
the same saved reviewer for a new decision. Earlier approval cannot clear that blocker;
unresolved retries stop until another explicit resume. Each attempt gets a new run with lineage and cumulative known usage;
prior failed results remain unchanged. Missing/legacy checkpoints are unsupported.
A definite `environment/commit_failed` stop with HEAD unchanged (for example a missing signing program) is finished by `kogen intent resume`, which commits the verified and reviewed candidate only: no builder round, review, check rerun or provider request. Unsafe drift or uncertain executed tools/commits (an interrupted or crashed commit, an undone hook commit) are refused without changing files,
index, HEAD or approval: inspect the named fact and correct it, or obtain fresh approval
for a new Build. A landed Build is an explicit successful no-op identifying its commit.
A `candidate/review_invalid` stop of a green candidate can be resumed the same way (an invalid ending of a green candidate stops with a review-only checkpoint of the green pass the review started from, whatever executor reviews, even when that review left uncommitted edits or had repaired, with the reviewer's uncommitted edits left in place; at the automatic retry they are discarded and logged as `review_edits_discarded`, and a reviewer that committed them moved HEAD and stays ineligible): Resume validates the checkpoint and that the checkout is exactly the stopped candidate, discards and logs the stopped reviewer's uncommitted edits, then starts one fresh review of the green candidate (never the old invalid conversation, no builder round, no rerun of completed checks); each explicit resume starts one more review and none restores the spent automatic retry. Resume is not automatic recovery or reapproval of a protected-contract blocker.

Claude Code has no session resume (`resume: none`), yet a Build whose candidate already passed every check is not discarded. A Claude Code builder that has finished no longer blocks resuming a review stage (`review`, `review_verify`, `review_retry_verify`, `review_only`): that resume proceeds as a native builder's does, and only the builder's own unfinished stages (`builder`, `builder_verify`) stay refused, except for an explicitly usage-limited round. An explicit resume of that safely checkpointed limit starts a clearly labelled fresh conversation at the same logical round with the preserved candidate and previous verification feedback; provider history is not restored, and historical results do not authorize a changed tree. There is no automatic retry or account switch. A stopped Claude Code reviewer is never revived: its checkpoints record `continuation.base`, the complete green pass the review started from, and resume discards the stopped session's uncommitted edits (logged as `review_edits_discarded`) and starts one fresh review of that green candidate, with no builder round and no rerun of its checks. A blocking verdict of that reviewer, and a checkpoint that records no complete green base (written before this was recorded), are refused with the exact work to redo and why.

A builder that observes a contradiction in protected fixtures can report it and stop with `candidate/build_blocked`. The report is labelled builder-reported, with evidence retained alongside the candidate, original index and approval; it does not authorize edits or skip successful checks. Ordinary implementation failures continue through repair.

Kogen supports ChatGPT ("Sign in with ChatGPT", using your plan), SuperGrok subscription sign-in, explicitly selected OpenCode Go, Anthropic Claude via API key, and local or self-hosted OpenAI-compatible servers (Ollama, LM Studio, vLLM). Any nonempty `model` is accepted for every provider and sent unchanged, and so is any nonempty `effort` except where Kogen knows the route's list: Anthropic and the Claude Code executor accept `low`, `medium`, `high`, `xhigh` or `max`, SuperGrok `low`, `medium`, `high` or `xhigh`, and `ultra` is rejected on every route when `.kogen/models.yaml` or `.kogen/local/models.yaml` is read; known models are only recommended defaults (`gpt-6.1-sol` for ChatGPT, `grok-4.7` for SuperGrok, `kimi-k3` for OpenCode Go, `claude-opus-5-5` or `claude-sonnet-5-5` for Anthropic). If a provider refuses the model or effort, Kogen says what it sent, does not retry, and tells you to set another model or effort for that role (the message's own text still names `.kogen/project.yaml`; the lineup is in `.kogen/models.yaml`). Save your own Go workspace key through stdin with `kogen provider login opencode-go`; local status is `key saved (not verified)`, not subscription eligibility. Omitted per-role `provider` keeps ChatGPT; `provider: supergrok` is recommended with `grok-4.7` and `low`, `medium`, `high` or `xhigh` effort. Sign in with `kogen provider login supergrok`: follow the printed HTTPS address and code; Kogen does not open a browser for this device flow. `provider: openai-compatible` needs a `base_url` per role, for example `'http://localhost:11434/v1'` for Ollama, and an optional key from `kogen provider login openai-compatible`, which reads the key's base URL line, then the key line, and binds the key to that HTTPS origin; a keyless local host needs no login. `kogen provider list` shows the saved local logins without network access. No API-key or paid-route fallback is used. See [provider configuration and qualification](docs/configuration.md#providers). Kogen is the small core the rest of Kogen is built with: further features can be built through Kogen or developed directly while the tool is being qualified.

Official text/tool compatibility is exact, not provider-wide: Sol 6.1 Shape/high,
Build/medium and Review/high, plus Sonnet 5.5 Review/medium on their normal routes.
Other selections remain experimental and are not blocked. `kogen provider list --json`
publishes the offline profile/limits/settings catalog and row-level evidence. See
[qualified model-family profiles](model-family-qualification.md) for the
separate historical evidence scopes, current wire policy and experimental remainder;
recommended defaults and saved logins do not establish qualification.

Kogen runs its own pinned Claude Code `2.1.318`, never the `claude` on your `PATH`: the first Claude Code role installs it under `~/.kogen/claude-code/` (a download checked against a pinned SHA-256), with its own configuration directory and updates disabled, so your own Claude Code install, settings, plugins, skills, hooks, memory and credentials neither affect it nor are changed by it; `kogen provider list` shows `claude-code runtime: ...` and `kogen uninstall` removes it. It signs in with a long-lived subscription token: make one with `claude setup-token` (without an own Claude Code: `CLAUDE_CONFIG_DIR="$HOME/.kogen/claude-code/config" "$HOME/.kogen/claude-code/2.1.318/claude" setup-token`), then save it with `kogen provider login claude-code` (stdin or echo-suppressed terminal; `kogen provider list` shows `claude-code: token saved (not verified)`). It is kept privately in `~/.kogen/credentials/claude-code.json`, passed to Claude Code on an inherited pipe at fd 3 (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3`) only from that file, is how Kogen's runtime signs in, and an inherited environment token is still ignored. Remove it with `rm -f ~/.kogen/credentials/claude-code.json ~/.kogen/credentials/claude-code.lock`. See [the Claude Code executor](configuration.md).

Claude uses separate API billing, not a consumer Claude/Max subscription. Save a key
privately with `kogen provider login anthropic` (stdin or echo-suppressed terminal).
`~/.kogen/credentials/anthropic.json` is private; offline status is
`anthropic: key saved (not verified)`, not a claim of access. Claude can independently
occupy Shape (including Refine), Build or independent Review.
The model lineup lives in `.kogen/models.yaml` (committed; `kogen init` writes it), with an optional host-local `.kogen/local/models.yaml` that wins per role. For example, in `.kogen/models.yaml`:

```yaml
models:
  shape: {provider: anthropic, model: claude-opus-5-5, effort: high}
  build: {provider: opencode-go, model: kimi-k3, effort: high}
  review: {provider: supergrok, model: grok-4.7, effort: high}
```

Claude typed image input is unsupported: use external image preparation and a
pixel-review handoff; paths/text are not native pixels. Deterministic synthetic
local tests establish plumbing only. Live installed qualification needs separate
human consent/private login and exact model/effort/tool/replay/Review evidence;
no paid sweeps or fallback. Linux and release real-use gates remain separate.

## Status
Kogen is in active development. Development prereleases are published at https://github.com/KogenAI/kogen/releases and `packaging/install-kogen.sh` installs them; you can also build the release archive from this repository. It runs on macOS on Apple Silicon and on Linux x86-64 with glibc. Release qualification requires the deterministic suite on both platforms and real use: the installed candidate builds a feature in the example app in `examples/` and a change to Kogen itself. Uncommitted local builds remain development candidates until those gates pass.

## Specification
[spec/](../spec/README.md) is the specification this repository implements: prose chapters with numbered requirements, Gherkin scenarios for every requirement, and Quint models of the state machines.

## Folder map
| Path | What |
| --- | --- |
| `cli/` | the `kogen` program (Go: the standard library, the component modules below and the in-tree kogen-loop module, which use only the standard library): the command line, the `kogen init` readiness report, usage and local facts, and the assembly of the component modules that `cli/go.mod` pins at exact versions |
| component modules | [kogen-coordinator](https://github.com/KogenAI/kogen-coordinator) (configuration, Intents and Git), [kogen-executor](https://github.com/KogenAI/kogen-executor) (executor contract), [kogen-verification](https://github.com/KogenAI/kogen-verification) (verification and evidence), [kogen-setup](https://github.com/KogenAI/kogen-setup) (init), [kogen-shaping](https://github.com/KogenAI/kogen-shaping) (Shape, Refine, approval), [kogen-build](https://github.com/KogenAI/kogen-build) (Build, commit, resume and recovery), and [kogen-review](https://github.com/KogenAI/kogen-review) (independent Review); each carries its own tests |
| `cli/third_party/kogen-loop/` | the pinned copy of kogen-loop: providers and sign-in, tools, the round engine and process custody. Written only by `packaging/sync-kogen-loop.sh`; `cli/loop-pin.json` holds its digest |
| `docs/executor-contract.md` | the [executor contract](executor-contract.md), implemented in `kogen-executor` |
| `packaging/` | `package.sh`, `install.sh`, `sync-kogen-loop.sh`, the release README, the pinned Quint and Cucumber packages, third-party licences |
| `spec/` | prose, Gherkin and Quint specification, and its checks |
| `docs/` | `configuration.md`, `testing-rules.md` (the test-selection rules Kogen gives its models and follows itself), `testing-strategy.md` (Kogen's own test layers and gates) |
| `examples/` | the example app for real-use tests, with the qualification of its checks |
| `test/acceptance/` | the deterministic scenario suite: step definitions, the fake ChatGPT server, fixtures |
| `test/live/` | release acceptance (real use), the product export and its checks |

## Contact
contact@kogen.dev


For a **fresh** Build only, optional operator diagnostic data can be supplied with
`kogen intent build <slug> [--project <checkout>] --context <file>`. The file is
caller-relative (not project-relative), readable and regular, nonblank valid UTF-8,
and at most 262144 original bytes. It is read once and preserved exactly in private
local run custody (0700 directory, 0600 `diagnostic-context.json`), separate from
approval and commits. Do not put credentials in it; this is not a credential store.
The labelled lower-authority message does not replace the approved Intent or native
protection, checks, review or commit rules. Old candidate observations are untrusted
data, not automatic reuse, import or proof. After a demonstrated protected fixture
correction, obtain new exact approval before a fresh Build. `intent resume` accepts
no `--context`: it uses its saved conversation even if the source changes or vanishes.

## License
Copyright 2026 Optimum Tech, LLC. Licensed under [Apache 2.0](LICENSE); see [NOTICE](NOTICE). The release archive bundles third-party software under their own licences: [packaging/licenses/](../packaging/licenses/README.md).
