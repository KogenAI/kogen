# Kogen

Kogen takes one requested feature through five steps in your own Git repository:

1. **Shape**: a model writes the feature as short prose, executable Gherkin with step definitions, and a Quint model when the change has meaningful state. It inspects the repository and settles material technical questions itself. It finds and retrieves current authoritative external documentation when a task depends on it. It keeps a native record of each documentation lookup. It asks you only about open UI/UX choices.
2. **Build**: after you approve the exact files, Kogen's own model/tool loop ([kogen-loop](cli/third_party/kogen-loop/README.md)) implements it. Alternatively, an executor you select, such as your installed Claude Code, implements it ([executor contract](docs/executor-contract.md)). Claude Code can likewise independently serve Shape (including Refine) and the independent Review, each as its own fresh session with explicit limitations; this is source capability, not live qualification. Either way, Kogen alone verifies, reviews and commits.
3. **Verify**: the acceptance scenarios run against the real code, with the model check and the project's checks; failures go back to the builder until everything passes.
4. **Review and fix**: an independent reviewer investigates and repairs concrete defects. Kogen verifies changed final files; failures stay with that reviewer. Maintenance preferences are notes. An unresolved substantive blocker stops with preserved work instead of restarting the builder/review loop.
5. **Commit**: one commit of exactly the verified and reviewed contents, with your own Git configuration.

Reviews keep exact authority and check results in the working window, with complete candidate source/diff in private hash-bound parts when necessary, including when an initially fitting inline review later runs out of continuation room. The reviewer reads every part before approval; missing or changed custody stops safely. This preserves the current context ceiling rather than silently clipping source.

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
Unsafe drift or uncertain executed tools/commits are refused without changing files,
index, HEAD or approval: inspect the named fact and correct it, or obtain fresh approval
for a new Build. A landed Build is an explicit successful no-op identifying its commit.
Resume is not automatic recovery or reapproval of a protected-contract blocker.

A builder that observes a contradiction in protected fixtures can report it and stop with `candidate/build_blocked`. The report is labelled builder-reported, with evidence retained alongside the candidate, original index and approval; it does not authorize edits or skip successful checks. Ordinary implementation failures continue through repair.

Kogen supports ChatGPT ("Sign in with ChatGPT", using your plan), SuperGrok subscription sign-in, explicitly selected OpenCode Go, Anthropic Claude via API key, and local or self-hosted OpenAI-compatible servers (Ollama, LM Studio, vLLM). Any nonempty `model` is accepted for every provider and sent unchanged, and so is any nonempty `effort` except where Kogen knows the route's list: Anthropic and the Claude Code executor accept `low`, `medium`, `high`, `xhigh` or `max`, SuperGrok `low`, `medium`, `high` or `xhigh`, and `ultra` is rejected on every route when `.kogen/project.yaml` is read; known models are only recommended defaults (`gpt-6.1-sol` for ChatGPT, `grok-4.7` for SuperGrok, `kimi-k3` for OpenCode Go, `claude-opus-5-5` or `claude-sonnet-5-5` for Anthropic). If a provider refuses the model or effort, Kogen says what it sent, does not retry, and tells you to set another model or effort for that role in `.kogen/project.yaml`. Save your own Go workspace key through stdin with `kogen provider login opencode-go`; local status is `key saved (not verified)`, not subscription eligibility. Omitted per-role `provider` keeps ChatGPT; `provider: supergrok` is recommended with `grok-4.7` and `low`, `medium`, `high` or `xhigh` effort. Sign in with `kogen provider login supergrok`: follow the printed HTTPS address and code; Kogen does not open a browser for this device flow. `provider: openai-compatible` needs a `base_url` per role, for example `'http://localhost:11434/v1'` for Ollama, and an optional key from `kogen provider login openai-compatible`. `kogen provider list` shows the saved local logins without network access. No API-key or paid-route fallback is used. See [provider configuration and qualification](docs/configuration.md#providers). Kogen is the small core the rest of Kogen is built with: further features can be built through Kogen or developed directly while the tool is being qualified.

Official text/tool compatibility is exact, not provider-wide: Sol 6.1 Shape/high,
Build/medium and Review/high, plus Sonnet 5.5 Review/medium on their normal routes.
Other selections remain experimental and are not blocked. `kogen provider list --json`
publishes the offline profile/limits/settings catalog and row-level evidence. See
[qualified model-family profiles](docs/model-family-qualification.md) for the
separate historical evidence scopes, current wire policy and experimental remainder
of KOGEN-057; recommended defaults and saved logins do not establish qualification.

The Claude Code executor can use a long-lived subscription token instead of an interactive `claude auth login`: make one with `claude setup-token`, then save it with `kogen provider login claude-code` (stdin or echo-suppressed terminal; `kogen provider list` shows `claude-code: token saved (not verified)`). It is kept privately in `~/.kogen/credentials/claude-code.json`, passed to Claude Code on an inherited pipe at fd 3 (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3`) only from that file, takes precedence over a stored `claude auth login`, and an inherited environment token is still ignored. Remove it with `rm -f ~/.kogen/credentials/claude-code.json ~/.kogen/credentials/claude-code.lock`. See [the Claude Code executor](docs/configuration.md).

Claude uses separate API billing, not a consumer Claude/Max subscription. Save a key
privately with `kogen provider login anthropic` (stdin or echo-suppressed terminal).
`~/.kogen/credentials/anthropic.json` is private; offline status is
`anthropic: key saved (not verified)`, not a claim of access. Claude can independently
occupy Shape (including Refine and enabled workers), Build or independent Review.
For example:

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

Kogen is in active development. There is no published release yet: you build the release archive from this repository. It runs on macOS on Apple Silicon and on Linux x86-64 with glibc. Release qualification requires the deterministic suite on both platforms and real use: the installed candidate builds a feature in the example app in `examples/` and a change to Kogen itself. Uncommitted local builds remain development candidates until those gates pass.

## Getting started

Kogen is one Go program. You need Git, a supported subscription (bare `kogen init` discovery requires ChatGPT; see [configuration-first bootstrap](docs/configuration.md#opencode-go-and-role-presets)), and to build it Go 1.27 and Node 24 (for Quint and Cucumber); no Erlang or Elixir. The toolchain is in `.tool-versions`, for example with [mise](https://mise.jdx.dev): `mise install` (it also lists Elixir for the Elixir fixture project and the Tiny Tasks example, which are projects Kogen builds, not part of Kogen).

```sh
sh packaging/package.sh                        # builds dist/kogen-<version>-<platform>.tar.gz
tar -xzf dist/kogen-*.tar.gz -C /tmp
sh /tmp/kogen-*/install.sh                     # installs into ~/.local; needs no administrator rights
export PATH="$HOME/.local/bin:$PATH"           # if install.sh says ~/.local/bin is not on your PATH
kogen provider login chatgpt                   # signs in through your browser
```

Then, in a Git repository of your own with at least one commit (a Build needs a clean working tree, so keep the request file outside the repository, or commit it):

```sh
kogen init                                     # finds and checks the project's commands, commits .kogen/project.yaml
kogen intent shape my-feature ../request.md    # the request, kept outside the repository; answer questions on stdin: printf '1: a\n' | kogen intent shape my-feature -
kogen intent approve my-feature                # shows the card; approve with the hash it prints
kogen intent build my-feature                  # builds, verifies, reviews and commits
```

To correct an existing **ready** package without regenerating it, take the full SHA-256 from `kogen intent approve <slug>` and run `kogen intent refine <slug> <sha256> ../correction.md`. It changes existing owned files only, checks the merged package in scratch and preserves the original on refusal/failure. Within a run, retries retain earlier well-formed proposals and may submit only corrections for edits; publication requires the complete accumulated package to be ready. New/deleted files, shared step edits, changed acceptance paths and model addition/removal need a new shaping request. For an approved package with a stopped protected blocker, use `intent recover` below to preserve and clear its implementation first; only the normal Build-clean paths are allowed. Only a matching approved-current marker imposes these Build-clean restrictions. A nonmatching marker is unrelated stale authority, including historical receipt-less legacy approval; it does not block correction of the ready unapproved current package. A successful correction archives and revokes that approval; failure retains it. Refinement never approves; review and approve its resulting package normally. Refinement audit evidence stays under `.kogen/local/refinements/`. Successful stable shaping, published refinement and card checks supply readiness evidence under `.kogen/local/readiness/`; unchanged cards and hash approval reuse it only for the same complete protected baseline hash, HEAD and Snapshot candidate tree. Missing or invalid evidence runs normal readiness. This does not reuse Build verification or review. Refinement also uses a valid complete version3 record for its exact original-ready precondition, including projects with nonempty setup. A hit skips only the fresh original setup/model/acceptance execution; it is retained evidence, not proof of current environment readiness. Missing, malformed, stale or invalid evidence follows the normal mutation-guarded original scratch check. Every changed complete candidate runs fresh configured setup and normal readiness, even after a hit; environment drift can fail it. After inspecting legitimate missing-feature red, submit the smallest eligible owned artifact with its exact current candidate whole body, including previously proposed corrections. The files array must be nonempty; if only one eligible large artifact exists, submit its entire body. Omitted well-formed proposals remain retained: do not retransmit large unchanged prose/helpers or restore original disk bytes for acknowledgment. Publication and acknowledgment still concern the exact complete package. Exact unchanged acknowledgment does not repeat that gate. Raw index checks remain operation safety; exact candidate tree identity also controls reuse. See [optional Shape workers](docs/configuration.md#optional-native-shape-workers) for the opt-in trial and context/evidence guidance.

Within a shaping conversation, corrective file submissions retain earlier well-formed proposals; omitted paths are kept. Previously declared proposed JavaScript steps and a proposed model must stay declared. To discard an earlier new artifact, preserve and park the partial package and its exclusively owned new step files, remove the empty Intent directory, then shape again with the same slug or a new one. Failed shaping does not provide a cross-invocation proposal resume.

For a generated project, commit the runnable scaffold first; `kogen init` then makes a separate `Add Kogen configuration` commit. A truly empty Git worktree can instead start with a configuration-only `Initial commit`; uncommitted application files must be committed before initialization. An uncommitted request belongs outside the repository.

`kogen init` keeps only the checks that pass on your committed tree, and sets up acceptance with the Cucumber Kogen ships, or with the project's own; [docs/configuration.md](docs/configuration.md) explains `.kogen/project.yaml`. Dependency manifests and lockfiles (such as `mix.exs`, `package.json`, `go.mod` and their lockfiles) are editable inputs when they only describe project/dependency metadata. Dedicated formatter, linter and suppression settings remain protected. A combined manifest that defines a configured check, such as an npm check script or a Mix check alias, may be protected whole-file; it then has no dependency-only edit exception. If shaping reports a genuine conflict, revise the request, or review and commit `.kogen/project.yaml` outside Build and shape again. This manual review changes the approval baseline; it is not approval to edit a protected file in Build. Preserve checks and their actual configuration. `kogen doctor [--project <dir>] [--quick] [--json]` reports what is ready for a first feature and the exact fix for each problem (`kogen init` ends with `doctor --quick`); it makes no model call and leaves the checkout unchanged. `kogen help` lists every command, and `kogen uninstall` removes the program.

## Specification

[spec/](spec/README.md) is the specification this repository implements: prose chapters with numbered requirements, Gherkin scenarios for every requirement, and Quint models of the state machines.

## Development

Set up once, with the toolchain from `.tool-versions` on `PATH`:

```sh
(cd spec && npm ci)
(cd test/acceptance && npm ci)
```

Checks for an ordinary change, as [docs/testing-strategy.md](docs/testing-strategy.md) describes (the tests a change needs follow [docs/testing-rules.md](docs/testing-rules.md)):

```sh
(cd cli && go test -race ./...)                # Go tests: unit and integration, against real git in temp repos
(cd spec && sh check.sh)                       # the specification's own checks
sh packaging/package.sh                        # the release the scenarios install (they use the newest in dist/)
(cd test/acceptance && npx cucumber-js --strict --tags "not @live" --require "steps/*.js" --require "support/*.js" ../../spec/features/04-building.feature)   # the chapter you changed
```

Release checks:

```sh
sh test/suite.sh                               # every deterministic layer and scenario; run on macOS and Linux
sh test/live/real-use.sh example file://$PWD/dist/<archive>   # real use on the example app (REL-1)
sh test/live/self-repo.sh /tmp/kogen-self && KOGEN_SELF_REPO=/tmp/kogen-self sh test/live/real-use.sh kogen file://$PWD/dist/<archive>   # installed self-hosting qualification attempt (REL-1)
sh test/live/self-build-check.sh <run folder>/project      # REL-3 on what that run landed; real-use.sh prints the run folder
sh examples/tiny_tasks-qualification/qualify.sh               # qualifies the example app's own checks
```

During development, fix Kogen directly with an external coding agent when needed. Self-hosting is a qualification path, not a prerequisite for repairing the tool. Preserve failed-attempt evidence and verify the candidate independently. An uncommitted development build is not a qualified release; the release checks above still apply.

The scenarios run Python from `.tool-versions`; set `KOGEN_TEST_PYTHON_BIN` to use another Python 3.13. Read `sh test/suite.sh` layer timings for the actual scope and host load. The
24 October migration candidate took 516.8 seconds for that complete deterministic
layer under concurrent local work; focused checks remain the development loop.

## Folder map

| Path | What |
| --- | --- |
| `cli/` | the `kogen` program (Go, standard library plus the in-tree kogen-loop module, also standard library only): the command line, shaping, the Build, executors, verification, review and commit, project commands in process groups under a watchdog; its packages sit beside `main` and carry their own tests |
| `cli/third_party/kogen-loop/` | the pinned copy of kogen-loop: providers and sign-in, tools, the round engine and process custody. Written only by `packaging/sync-kogen-loop.sh`; `cli/loop-pin.json` holds its digest |
| `cli/executor/` | the [executor contract](docs/executor-contract.md), its conformance scripts and the Claude Code executor |
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

Copyright 2026 Optimum Tech, LLC. Licensed under [Apache 2.0](LICENSE); see [NOTICE](NOTICE). The release archive bundles third-party software under their own licences: [packaging/licenses/](packaging/licenses/README.md).

## Clean final readiness

Final readiness uses a fresh disposable directory materialized from `Snapshot.tree`, with exact tracked (including ignored tracked) bytes, executable modes, additions/deletions and synthetic local Git. It runs verbatim declared setup before model/acceptance; ignored untracked dependency/build outputs are neither copied nor linked. Caller environment, installed tools and declared services remain available: this is not hermeticity. Raw scratch mutations, including staged additions, reject proof. Source identity is rechecked around execution and publication, including approval. Disposable directories are removed on success, failure and interruption. Exploratory probes remain warm.

Readiness record version 3 adds `candidate_tree` to the complete baseline/hash, HEAD, declarations and actual model/scenario/exit evidence. Only exact unchanged clean evidence is reusable; version 2 and older are normal misses, never migrated. Ignored untracked warmth does not affect identity; nonignored changes, deletions, executable modes, tracked ignored changes, HEAD, protected baseline and declarations do. Retaining original-precondition evidence skips only original setup/model/acceptance, not fresh changed-candidate proof, and is not current-environment proof. Refine tests and publishes its complete accumulated formatted proposals; Shape tests its final formatted files. Accounted red remains inspectable and exact unchanged acknowledgment reuses the same clean observation. Evidence also retains actual final-attempt skipped Gherkin steps, including Backgrounds and expanded Outline rows; cards and Shape/Refine feedback summarize their count before failure details and list their source locations. Skipped steps are unexercised: readiness proves neither their behavior nor fixture validity. Version 3 records missing valid skipped-step metadata are ordinary misses, not silently empty observations. Build verification, review and explicit caller approval remain separate.

## Checkout facts and completion

Use `kogen context` for JSON checkout activity and last-started Build facts,
`kogen intent list`, `kogen intent inspect <run-id>` and
`kogen intent preflight <slug>` for discovery and read-only investigation.
The latter three accept `--json`; all four accept `--project <checkout>`.
Context and completion are local reads that need no login, provider or network. See
[the version 1 contract and standalone Zsh installation](docs/checkout-facts.md).
Preflight is not authorization: Build still performs its normal safety checks.

## Prompt reuse and retained usage

`kogen intent usage [RUN-ID] [--lineage] [--project DIR] [--json]` explains
local retained transport evidence without credentials or inference. It reports
weighted cache ratios, nullable writes/lifetimes, unknown/inconsistent counts,
failures and provenance; totals cover selected evidence, not just displayed rows.
This is not account or weekly usage. Every model conversation has one cache identity (at most 64 characters, kept across retries, resets and resume, never shared with another conversation). ChatGPT sends it as body `prompt_cache_key` and underscore headers `session_id` and `conversation_id`, SuperGrok as `prompt_cache_key` (with one bounded refusal retry), OpenCode Go as `x-opencode-session`, and Anthropic marks ephemeral `cache_control` breakpoints on the last tool, last system block and newest message (at most four); OpenAI-compatible hosts get no vendor field or header (a host with prefix caching still benefits from the frozen front and append-only history). Kogen keeps full stateless encrypted replay, independent reviewers and fresh safety/verification gates, and the usage report shows the cached share from each provider's raw cache fields. Cache acceptance is
not proof of a hit, effective lifetime or live account qualification. See
[usage scope, filters and uncertainty](docs/usage.md).

## Private working continuity and source provenance

All native model-facing text tool results (Shape, Refine, Build, independent Review
and optional Shape workers), including errors and control feedback, share a 16384
UTF-8 byte bound **including** the omission marker. Fitting text is unchanged.
Oversized displays preserve the first 4096 bytes and a suffix, backing off incomplete
characters, with `\n[... N bytes omitted ...]\n` counting actual original bytes absent.
Conservative marker reservation may leave a few bytes unused. The display is
idempotent and retained exactly with its tool call for replay, not recut on resets.
Line ranges do not bound bytes: explicitly selected ignored custody remains readable,
but large reads are visibly incomplete. Private originals, archives, structured
documentation records, native probe evidence, complete authority and required complete
pinned Review source delivery are unchanged. Typed images pass unchanged under their
existing limits. This does not make arbitrary authority, arguments or batches fit.

Build and its independent reviewer preflight the **complete rendered next JSON request**
against a fixed **524288 UTF-8 byte** ceiling (equality fits), with **131072 tokens**
reserved for output/reasoning. This is a conservative byte proxy, not observed usage,
a provider rejection threshold or a total-Build limit. No provider/model/effort or
stateless transport capability changes. Completed safe boundaries can start an explicitly
labelled local working window; authority and current unfinished work/findings remain,
while full ordered replay is retained privately under
`.kogen/local/runs/<id>/working-context/<owner>/` with SHA-256 links. Opaque reasoning,
assistant phase and complete tool batches are preserved. Irreducible requests stop as
`candidate/context_budget_exceeded` before inference, naming retained custody and ordinary
Refine/new-approval guidance. Provider context errors below the proxy remain honest failures.

Version 3 checkpoints retain the active owner/window, archives, findings and source binding;
version 2 and older are explicitly unsupported, inspectable and refused without changes.
Resume requires the user's index to record exactly the saved staging. A plain `git status` that
only refreshed entries' stat cache (timestamps, inode, size) after the stop is not a change and is
reported; any staged path, mode, object, stage, flag or extension change (including Git's
cache-tree, so even restaging identical content refuses), a version 4 or split index, or a
damaged index still refuses (Studio Build 543748f1). Fail closed means setups whose `git status`
also rewrites an extension (untracked cache, fsmonitor) or that write index version 4 or a zero
checksum (`feature.manyFiles`, `index.skipHash`) still refuse after a status. `kogen intent recover`
keeps exact index byte equality.
Missing, altered or unsafe bound custody is a refusal, not a new Build. Editing makes old
green evidence stale, and a reviewer reset neither clears blockers nor starts a new critique.

Native Shape supplies `Context navigation: <JSON>` as a single-line dynamic block,
with exactly `root`, `revision` (`head` and `tree`) and `retrieval`. The resolved
checkout root and candidate revision replace the generated repository inventory;
retrieval is `read_file exact bytes and line ranges; list_files directories; search_text exact signatures`.
Descriptor size does not grow with repository cardinality. Shape must still inspect
relevant files and establish documentation evidence through native tools. Exact
request/Q&A, README, testing rules, commands and protection/automatic baseline stay
complete; caller-supplied inventories are not stripped. Refine retains its frozen-original
context index and explicit excerpts. This is not a guarantee that every request fits.

At a completed Review boundary, an oversized next request can relocate the exact
original inline source/diff to the same private ordered source parts and try one
smaller window. Small fitting continuations are unchanged; pinned source is not
re-pinned on every reset. Supported version-3 inline checkpoints use their exact
saved blocks, including explicit resume after a provider failure, without restarting
Review or Build. Older source without an established tree binding is labelled
historical, never reconstructed from an edited checkout. Every newly pinned part
must reach the reviewer through a complete matching read_file output, or a Kogen native
source-data message carrying that exact text, in a completed continuation before approval. Each Review reset handoff carries `review_delivery`: the
pinned-part tree and whether it is current, delivered count and unread part numbers, and
every image this review was given, as of its newest delivery (path, SHA-256, read candidate,
current, pixels still in the next window). A reviewer that could not tell what it already
received rebuilt it in every window (Studio Build 543748f1); these facts are not findings or
approval. Native current-tree checks alone determine eligibility.

Native Refine also preflights complete rendered requests within one invocation.
At completed response/tool-batch boundaries it archives oversized input under
`.kogen/local/refinements/<attempt-id>/working-context/<n>.json` and tries one
deterministic smaller window. Version-1 archives retain owner `refine`, exact input
and the previous path/hash (null first); new custody directories are 0700, files
0600, and hashes cover complete bytes. Every window keeps exact initial correction,
owned originals, README, testing rules, commands/protection and source-provenance
binding, plus the newest complete exchange, current complete proposal manifest,
ownership, readiness observations/identity, invalid count and assistant observations.
Documentation remains complete in native state and private snapshots, not inline bodies. Cumulative native proposals remain authoritative;
handoffs are diagnostic, not model-authored substitutes or approval. Old manifests
remain in exact history. Linked custody is validated before subsequent inference,
tool effects and publication; missing, altered, symlinked or unsafe custody stops as
`candidate/context_custody_invalid`, preserving package and approval.

Refine emits `working_context_reset` events and progress with measured before/after
bytes and retained custody. A reduced request must be both smaller and within the
unchanged inclusive ceiling. Irreducible input is retained exactly unsent in the
same chain with `working_context_stop`, measured/mandatory bytes and limits; it
stops before inference as `candidate/context_budget_exceeded`. An identical fresh
retry is not recovery: Refine has no persistent resume or automatic retry. Ordinary
scope/correction changes may be needed. Publication, exact red acknowledgment and
new exact approval requirements remain unchanged.

Native Shape can continue across bounded local working windows within one invocation.
At a completed provider/tool boundary it preflights the complete next request, archives
oversized active input privately under
`.kogen/local/shaping/<slug>/working-context/<attempt-id>/` (0700 new directories,
0600 files, SHA-256 links), and tries one deterministic smaller window. It keeps exact
initial authority and request/Q&A, cumulative proposals, discovery/documentation state,
readiness identity, invalid count, assistant observations and the newest complete exchange.
Handoffs and archives confer no approval or discovery authority. Missing, altered or
unsafe linked custody refuses further inference/publication. Irreducible input is retained
exactly unsent with `candidate/context_budget_exceeded`: a fresh identical retry is not
recovery; correct the request/scope or prepare images externally. There is no summarizer,
automatic splitting or persistent Shape resume, and not every large request fits.

Shape and Refine reset handoffs carry only `history: {head: {path, sha256}, count}`
and `documentation: {path, sha256, count, format: "ndjson"}` evidence references.
Each numbered version-1 archive binds its immutable sibling `<n>-documentation.ndjson`
before hashing. Snapshots preserve every native record in order, including duplicate
and failed lookups, one JSON object and final newline per record (empty state is
empty bytes). Follow archive `previous` links for complete ordered replay; retrieve
one-based documentation lines with `read_file` `start_line`/`end_line`. Both owners
validate every bound snapshot alongside linked archives even for fitting continuations,
before inference, tool effects or publication. New custody uses 0700 directories and
exclusive regular non-symlink 0600 files. These references are diagnostic, never new
authority; native history and documentation lists remain complete and unchanged.

Successful Shape keeps exact request/Q&A and source identity privately at
`.kogen/local/provenance/<slug>/current.json` (0600 files, 0700 custody directories).
Successful Refine archives the previous receipt, retains originals and appends the exact
correction/prior contract identity. Failed/refused attempts leave successful custody and
approval unchanged. The shaper's bounded `## Source comparison` and approval card identify
addressed, omitted, conflicting and superseded behaviors/non-secret literals. Native Shape
and Refine require a nonempty report of at most 8192 UTF-8 bytes and return missing or
oversized reports for correction rather than clipping them. This mapping
is an aid, never proof of semantic completeness. Cards show the receipt path/hash and
contract binding; Build and fresh independent review can retrieve originals with native
read tools. Originals are diagnostic data, **not authority** to add omitted scope. Such
changes require ordinary Refine and new exact approval. Legacy projects explicitly report
`Source provenance: unavailable (legacy)`; originals are never reconstructed from Intent prose.
Do not place credentials in these private receipts or handoffs.

For a stopped `candidate/build_blocked` Build, explicitly run:

```sh
kogen intent recover <build-id> --output ../new-private-archive [--project <checkout>]
```

`--output` is required and caller-relative: it must name a NEW directory outside the
resolved checkout, with no symlinked custody. Recovery takes the normal Build lock,
validates a complete version-3 checkpoint, retained BUILDER-REPORTED blocker/result,
checkout/HEAD/index/protected baseline/configuration/approval/candidate and bound
working-context/image/source custody. Missing/legacy checkpoints are
`candidate/recovery_unsupported`; other unsafe facts are `candidate/recovery_refused`
(exit 1). Unsupported arguments (including `--context`) are usage errors (exit 2).
This is a completed native protected stop, not permission to resume uncertain tools.
Other provider, login, resource and interrupt stops keep their ordinary explicit
resume behavior. Ordinary implementation failures still return to the builder.

Before removing any implementation bytes, recovery publishes a private archive
(0700 directories, 0600 regular files) with exact before/candidate data and Git modes,
a hashed `manifest.json`, unchanged approval/index/checkpoint/result, retained blocker,
and bounded `correction.md`/`context.md` handoffs. Symlinks are regular archive data,
not followed. The printed absolute manifest path and SHA-256 identify preservation.
Only the recorded implementation delta is restored to start-tree bytes/modes; recorded
additions are removed. Protected files, other Intents, ignored outputs, HEAD, original
index, approval and prior run evidence stay unchanged. No stash, commit, provider call
or project command runs. Inspect `.kogen/local/recoveries/<build-id>.json` for archive
path/hash and `preserved` or `cleaned`: an incomplete cleanup is NOT success. Never
retry over an archive or guess reconciliation after a partial cleanup.

Run the printed Refine command with the ORIGINAL full contract hash and correction.md.
Refine must independently investigate this builder-reported, unproven claim and pass its
normal readiness gate; successful correction revokes the old approval. Review and freshly
approve the exact corrected package, then start a production-clean FRESH Build with the
generated `--context context.md`. Archived production is lower-authority diagnostic data,
not authority or current proof. Selective tool inspection is allowed, but there is no
automatic stash/patch/tree import, protected-byte replay, approval transfer or reuse of old
green/model/reviewer results. Full normal setup, checks, acceptance/model, independent
review and final changed-tree verification apply; landing consumes the new approval.
Recovery invokes none of these next commands. Read-only `context` and `intent inspect`
are the observation path for long work; no scheduler, polling or automatic retries are added.

## Selected native image evidence

Shape, Build and fresh independent Review share `view_image(path)`, one read-only
selected local image resolved like read_file (repository-relative or explicitly
selected absolute path). Only static non-interlaced 8-bit RGB PNG is supported:
**1..131072 original bytes**, width/height **1..2048**. Unsupported, missing or
expired artifacts need ordinary external preparation/export/capture and reselection.
There is no scanning, capture, transcoding, hosted service, Files API or image generation.
Shell/read_file remain text-only, even when printing paths or base64.

Success freezes exact original bytes as ordered typed Responses content plus metadata.
The read-time repository candidate is recorded when established; capture candidate,
route, viewport and fixture state remain `UNKNOWN` without separately established
provenance. Filenames/hashes/current checkout do not prove the intended candidate was
served. Provider preprocessing may change resolution; no detail guarantee is added.

Successful read, completed pixel delivery, explicit fallible visual observations,
DOM/action/accessibility/layout checks and human/designer decisions are separate.
Name pages, states and viewports actually inspected and retain final candidate-bound
evidence. Fresh Review obtains its own pixels; builder judgments are not inspection.
When provenance is stale/unknown or native input is refused, retain an honest outside
capture/pixel-review handoff. Unrelated work needs no image invocation.

Frozen outputs survive changed/deleted paths in private ordered replay, Build/Review
archives and version-3 checkpoints (0700 directories/0600 files). Missing, altered or
unsafe custody refuses resume before inference/mutation. Complete serialized JSON,
including base64, envelopes, policy, tools, cache controls and replay, retains the
524288-byte inclusive ceiling and 131072-token reserve. Build/Review and Shape keep completed
safe working windows; Shape has no persistent resume. Irreducible requests stop before sending with retained custody and external
image preparation or ordinary Refine/new-approval guidance. Images cannot change
approval, protected contracts, failed/stale/unknown checks, blockers or exact-final-tree
commit eligibility. Local scripted-provider tests establish plumbing/custody, not
actual visual interpretation or automatic design approval.

## Recovering stale approval cards

`kogen intent approve <slug>` checks current readiness and prints the full lowercase
64-character SHA-256 and an approval command containing that full hash (exit 5).
It never approves or starts Build. Existing 6–64-character hash prefixes remain
supported. A wrong prefix names the full current hash and the usable card command.
A nonmatching marker is labelled **Stale approval**, with its full old hash: it
cannot authorize the current package or Build.

An intact receipt with an older contract binding is historical diagnostic source,
not custody corruption or current readiness proof. The card shows both full contract
hashes and explicitly states that Shape has not run again, alongside actual readiness,
source comparison/path/hash/binding, protected files and the complete ordered staged
plan. Intrinsic invalid content still reports its parse/lint cause. Cards change
neither approval nor successful source history. After ordinary readiness, explicit
current-hash approval can refresh the receipt binding while preserving exact request,
Q&A, origin and corrections. The prior receipt is retained byte-for-byte in native
hash-named history, linked with prior/current contract identities; this is not another
Shape. Superseded marker bytes are privately archived and the inspectable path printed.

After fresh same-slug Shape, a stale marker's displaced current.json reference resolves
only through its exact pinned digest in safe native receipt history. A matching approval
still requires its exact current custody. Missing, changed or unsafe receipts refuse:
restore the named exact receipt from preserved history before running the card; if it
cannot be restored, stop. Fresh approval is not a cure for broken custody. Genuine
receipt-less legacy packages remain supported.

`kogen intent refine <slug> <full-current-sha256> <correction-file>` can correct a ready
unapproved current package despite stale authority, without Build-clean restrictions
solely from that marker. Normal ownership/shared-file limits, original readiness,
authentication, scratch checks and full-hash requirements remain. Refine freezes marker
bytes and current/resolved pinned custody; only success archives/revokes the marker.
Failure/cancellation preserves package, successful source, approval, HEAD and index,
and rollback never overwrites concurrent external edits. Refine never approves.
Matching approved-current Refine retains normal clean-path and explicit protected-blocker
recovery requirements. No approval transfer, automatic continuation or old Build proof
is imported: approve the corrected full current hash and start a fresh verified,
independently reviewed Build. Read-only `context` / `intent inspect` remain the
observation route, not an automatic scheduler or polling loop.
