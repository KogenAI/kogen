# Kogen

**Shape the feature. Leave the build to Kogen.**

Make the product and UX decisions that define the feature. Specify technical decisions when they matter. Kogen handles the implementation, checking, independent review, rework, and resulting commit.

Kogen is being built from a small core that can shape and build further changes
to Kogen itself. The aim is to grow the rest of the product through that loop:
shape the next feature, approve its Intent, and let Kogen carry out the Build.
The core is a starting point, not the finished product.

The core runs inside this repository through one pluggable harness interface
with two adapters: Claude Code (`harness: claude`) and Codex CLI
(`harness: codex`). `.kogen/config.yaml` names one or more routes, each pairing
a harness with role and helper profiles; a Shape or Build selects one route,
by default the configured `default_route`. This repository's `default_route`
is `claude`. Installing Kogen into arbitrary projects and other harnesses are
future work.
The broader design remains a longer-term direction, open to change as Kogen develops.

This repository is being opened quietly so the ongoing work and its history
can be inspected. Kogen is Almir Sarajčić’s personal engineering project.

## Get started

Use Elixir 1.20 with Erlang/OTP 29, Git, Make, and Python 3.11 or newer on macOS. Kogen manages the complete native runtime of each harness itself; personal Claude Code, personal Codex, and Node are not prerequisites. The pinned managed releases are Claude Code 2.1.280 and Codex 0.154.0. macOS arm64 is the live acceptance target; the official macOS x64 artifacts are selectable but have not been exercised on this host. Provider-backed work uses your selected Kogen login for the harness a route names, separate from any personal login. `mix kogen.build` also needs a macOS Keychain generic password for service `ai.typesafe.api` (the TypeSafe API key that Jev reads Developer notes with); add it with `security add-generic-password -s ai.typesafe.api -a <account> -w` before building, or Build stops before launching the Developer.

From a checkout whose `default_route` uses Claude Code:

```sh
mix deps.get
mix kogen.claude.install
mix kogen.claude.login
mix kogen.claude.status
make check
mix kogen.shape
```

For a route with `harness: codex`, use `mix kogen.codex.install`,
`mix kogen.codex.login` and `mix kogen.codex.status` instead — pass
`--route <name>` to `mix kogen.shape`/`mix kogen.build` to run a session on
that route, or set it as `default_route`. See
[Choosing a route](#choosing-a-route).

Describe one feature. As the Shaper, discuss its behavior and tradeoffs with Kogen’s Shaping Controller, inspect the Draft it writes, and explicitly approve it in that conversation. Approval moves the Intent from `.kogen/intents/drafts/<slug>/` to `.kogen/intents/approved/<slug>/`.
The controller may also reconcile narrow current approval bookkeeping inside the
package at that point. It preserves agreed requirements, identity, provenance and
historical evidence; a legacy `status: draft` field is harmless once the package is
selected from `approved/`, but a genuine current pending-approval contradiction is not.

To continue a saved Draft in a fresh conversation, run:

```sh
mix kogen.shape <draft-slug>
```

Kogen uses current shaping instructions and configured profiles, preserving the
Draft’s identity and original provenance. The controller reads its saved context,
summarizes unresolved work, and asks where to continue. Continued saves record a
separate shaping visit; changed Git baselines require discussion. Approval must
be explicit in this new conversation. Only drafts can be continued.

Exit the shaping conversation, then build its chosen slug:

```sh
mix kogen.build <slug>
```

Start Build on a clean branch with a commit at HEAD. Kogen implements the approved feature, runs verification, obtains an independent review, and commits the accepted result with its completed Intent and evidence. A stopped Build returns an error and keeps its work available for inspection. Review the error and working tree before starting again. `mix kogen.build` needs a macOS Keychain generic password for service `ai.typesafe.api`, the TypeSafe API key Jev uses to read the Developer's handoff notes; add it with `security add-generic-password -s ai.typesafe.api -a <account> -w`. Without it, Build stops before launching the Developer. Once running, Build sends the Developer's notes and the contract's scenario, risk, and finding IDs to TypeSafe; it never sends the diff or Candidate files, although the notes themselves may quote code.

## The loop

- **Shaper** is the human who shapes the feature with Kogen and approves the Intent.
- **Intent** captures the shaped feature precisely enough for Kogen to build it autonomously.
- **Build** implements, checks, independently reviews, and reworks when necessary.
- **Commit** records the checked and accepted implementation of one Intent.

The Stop hook owns the complete verification settlement: `make check`, followed by selected narrow catalog targets in dependency-valid cost order. `verification_retries` bounds failed Stop verification retries inside the same Developer conversation; those retries do not consume the outer allowance. After Stop settles, controller code builds the handoff report itself, so no handoff can be malformed or invalid; a declared proof selector still missing from the Candidate is unfinished work, decided by code, and uses one outer resumption. Jev (`jev-1.13.0`) reads the Developer's free prose once per handoff; an objection at 0.85 confidence or higher stops the Build immediately and returns it to Shaping, quoting the Developer's words and Jev's confidence. Otherwise, a settled verification failure, a failed declared target, or a Review finding uses one outer resumption of the same Developer, when allowance remains, and a resumed attempt must settle a fresh Stop verification before the next handoff or Review. An exhausted verification or outer allowance stops the Build rather than claiming success.

Developers and their delegated helpers must not run `make check`, any target declared by the selected Intent, or `.codex/hooks/check.sh`, including for early signal; focused non-gate tests remain allowed. A tracked PreToolUse hook blocks the explicit Make, command-list, and Stop-script forms before Bash dispatch. This bounded guard deliberately does not inspect indirect execution through non-gate Make dependencies, wrappers, shell expansion, `sh -c`, or later stdin; the Developer contract still forbids those routes. Existing configurations using legacy outer-resumption naming remain transition inputs; new documentation uses `verification_retries` for Stop verification and the outer allowance for Developer rework.

Every scenario's `verified_by` is a YAML list of Make target names, such as
`[check]`, and its required `proof` map names focused offline selectors,
optionally one causally justified narrow paid target, and all affected
implementation/assertion/fixture paths. Use `offline-sufficient: ...` when no
paid evidence is needed; provider-backed proof must name the exact
provider-only observation and why offline rehearsal cannot establish it.
`verified_by` is `[check]` plus that one selected target, never an automatic
all-paid selection. The real lifecycle fixture has a bounded check target; it
never invokes the full live suite recursively.

An opted-in isolated test can require forwarding of target evidence with
`target_evidence: :required`. A declared target may emit one
`KOGEN_TARGET_EVIDENCE_MANIFEST<TAB>{...}` line naming a repository-relative,
SHA-256-bound manifest. Build validates and snapshots that manifest and every
required artifact in the target receipt before Review. These controller-owned
snapshots preserve uncited required bytes; Reviewer citations remain separate
evidence of semantic inspection. Targets without a frame keep their existing
behavior.

Build validates the full Approved scenario contract before launching a provider.
Each scenario needs a unique nonblank `id`, `given`, `when`, `then`,
`wrong_result`, `evidence`, and a nonempty `verified_by` list of existing targets.
Optional `risks.yaml` entries have unique `id`, `scenario_ids`, and `description`;
file-ownership entries describe existing-path behavior, immediate and later owners,
permitted mutation, validation, Git state, and upgrades. An absent risk file is
recorded as “not supplied.” Shaping leaves unresolved ownership decisions to the
Shaper, including when a protected seed becomes user-owned configuration.

Role launches carry concise file and identity locators rather than task bodies.
Shaping starts from this README and maintained relevant context; Developer and
Reviewer read the complete selected Approved package and selected current fields
from the authoritative scenario-tracking record in their actual child working
directory. Rework names its failure category and record location while full
verdicts, findings, receipts, source snapshots, and historical exact bytes stay
in that record. Missing or conflicting required evidence is an integrity failure;
unfinished optional Draft files remain valid shaping work.

After Stop verification settles, controller code deterministically builds the
handoff report, bound to the fresh attempt token and the Candidate, from the
Approved contract, the Candidate's Git changes relative to HEAD, the declared
proof selectors, and Kogen's own receipts, so the report's format cannot fail.
The Developer's final message is free prose; Kogen code never parses it. Build
records it byte for byte as the Developer's notes and sends it, with the
controller-listed scenario, risk, and finding IDs, to TypeSafe Jev
(`jev-1.13.0`) once per handoff. Jev reports what the Developer says about
each item — unfinished, done, pending external verification, resolved or
historical, unclear — and whether the Developer objects that the approved
contract cannot be met. An objection at 0.85 confidence or higher stops the
Build immediately, without Review, and returns it to Shaping, quoting the
Developer's words and Jev's confidence. Every other Jev reading, including a
confident "unfinished" answer, and any runtime Jev failure, reaches the
Reviewer only as a labelled advisory note; a confident "unfinished" answer
never routes rework by itself, and the Reviewer alone decides acceptance or
rework. A fresh Reviewer assesses every scenario and explicitly closes or
retains every open finding with inspected counterevidence or repair evidence.
Acceptance requires all scenarios satisfied and no open blocking findings for
the current Candidate. A declared proof selector still missing from the
Candidate is unfinished work decided by code; it uses one outer resumption of
the same Developer, and the next attempt needs a fresh Stop verification.
Verification exhaustion and a Jev cannot-comply stop both take precedence
over ordinary Review routing, and outer-allowance exhaustion takes precedence
over another launch. Malformed Review still stops without partial closures.

To inspect a stopped Build, start with the record path and unresolved scenario IDs
in its error. Read `.kogen/runtime/scenario-tracking/<build-id>/record.json`:
`scenarios` and `risks` preserve requirements, `attempts` separate claims, receipts,
and verdicts, and `findings` retain stable IDs, origins, and dispositions. Each
Build gets a new versioned record even with raw logging disabled. Records are
inspection evidence, not restart checkpoints; review the worktree and Approved
package before any new Build. Do not edit these controller-owned records.
Citations retain separate Developer and Reviewer versions of the exact inspected
bytes in each attempt's `developer_reference_snapshots` and
`reviewer_reference_snapshots`; a later citation cannot replace an earlier role's
version. Subsequent controller updates
are checked against Build's latest owned bytes. External edits still stop Build.
Successful publication links concise Complete evidence to the bound local full
record; generated names never replace supplied evidence. Failed publication
restores the frozen Approved input.
Build refuses Git assume-unchanged and skip-worktree flags wherever it relies on
Candidate identity, including Stop and publication, without clearing those flags.

New Complete packages commit a versioned `build-summary*.json`, not the full
scenario-tracking record. The exact record remains in its ignored
`.kogen/runtime/scenario-tracking/<build-id>/record.json`; `evidence.md` explains
how to resolve it from the checkout root and verify its SHA-256 and byte count.
A clone retains the contract and concise result, but not those exact local bytes.
If the archive has been cleaned up, report it unavailable—do not substitute a
summary or another Build's record.

Immediately before commit, Build measures every added or modified staged
destination relative to the starting `HEAD` by its full uncompressed Git blob
length. The fixed limit is 5 MiB (5,242,880 bytes) per path and 10 MiB
(10,485,760 bytes) in aggregate; equality is allowed, deletions and unchanged
historical blobs cost zero, and there is no override. Added or modified staged
paths under `.kogen/runtime/` are always rejected, including force-staged ignored
files. An Approved package already unable to meet these limits stops before a
provider launch and must return to Shaping.


## Configuration and local data

Edit the tracked `.kogen/config.yaml` to define named **routes** and a
`default_route`. Each route pairs one `harness` (`claude` or `codex`) with the
model and effort for `shaping`, `developer`, `reviewer` and each required
helper profile (`helpers.scout`, `helpers.worker`, `helpers.expert`);
`outer_resumptions` and `verification_retries` stay top-level, shared by every
route:

```yaml
default_route: claude
routes:
  claude:
    harness: claude
    shaping:   {model: claude-opus-5-5, effort: medium}
    developer: {model: claude-opus-5-5, effort: medium}
    reviewer:  {model: claude-opus-5-5, effort: medium}
    helpers:
      scout:  {model: claude-sonnet-5, effort: low}
      worker: {model: claude-sonnet-5, effort: medium}
      expert: {model: claude-opus-5-5, effort: high}
  codex:
    harness: codex
    shaping:   {model: gpt-5.6-sol, effort: low}
    developer: {model: gpt-5.6-sol, effort: low}
    reviewer:  {model: gpt-5.6-terra, effort: medium}
    helpers:
      scout:  {model: gpt-5.6-luna, effort: low}
      worker: {model: gpt-5.6-luna, effort: medium}
      expert: {model: gpt-5.6-sol, effort: medium}
outer_resumptions: 2
verification_retries: 2
```

This repository's own `.kogen/config.yaml` matches the shape above. A `--route
<name>` flag on `mix kogen.shape` or `mix kogen.build` selects the route for
that session; without it, the session uses `default_route`. An unknown route
name fails before any harness open or provider launch, naming the unknown
route and listing the available route names in sorted order. Only the
selected route's harness and models are validated for support and readiness;
another route may name an unsupported or unready harness without blocking a
session on a different route. A config still using the old flat shape
(top-level `harness:` and roles, no `routes`) is refused before launch, with a
message naming `default_route` and `routes` as the replacement — there is no
compatibility reader or migration.

Kogen passes each root profile directly to the selected route's harness and
renders the helper profiles into every role prompt; it does not silently
inherit or substitute a missing or unavailable profile. All three helper
profiles are required on every route, though a role delegates only when
bounded independent work justifies the startup and integration cost.

Shaping records the selected route in the Draft (`shaping.route`, alongside
`harness`/`model`/`effort`/`started`), and each continuation records the
route used for that visit; the Draft's original `shaping` block is never
rewritten, and Drafts saved before routes existed remain continuable. A Build
resolves its route once and freezes it — name, harness and every resolved
role/helper profile — in its scenario-tracking record; later edits to
`.kogen/config.yaml`, including changing `default_route`, do not affect a
Build already in progress. The committed `build-summary.json` and
`evidence.md` name the Build's route and harness.

[Shared execution guidance](priv/kogen/prompts/execution-policy.md) has one
[renderer](lib/kogen/execution_policy.ex), expanded by fresh/continued Shape
and the Developer/Reviewer launch routes. Role templates retain approval, gate,
Candidate and output authority. Maintain profile values in config and shared
guidance in that source; update public-route regressions when changing either.
The [live native-helper fixture](test/kogen/native_helper_live_test.exs) checks
transport and deterministic facts, not model quality or savings; historical
measurements remain workload-specific. Its
[receipt controls](test/kogen/native_helper_fixture_test.exs) reject missing or
contradictory native evidence. The existing live lifecycle also audits actual
[root session profiles](test/support/root_profile_audit.ex). Regenerate evidence
through the Build-owned provider-backed targets using the prerequisites below; inspect the
new run’s retained receipts and raw snapshots on failure, without substituting
a prior passing run.

The connected Shape-to-Commit and Build-only Reviewer-rework live cases are
separate async modules, allowing their private ordered lifecycle chains to
overlap when scheduler capacity permits. Both audit their own current native
streams; the former three-call primitive probe is consolidated into those
owners and offline corruption controls. Semantic Review, native-helper, and
cold-offline proof remain separate cases.

Shaping quality is also exercised by a maintained
[five-case evaluation](test/support/shaping_evaluation/README.md): flawed and complete
CSV/availability pairs plus a frozen-seed continuation run as isolated concurrent
public Shape sessions. Its offline rehearsal covers the real orchestration and
consumer route; the live owner emits one required-artifact manifest, while ordinary
independent Review assesses the retained conversation and Draft semantics. Target
selection follows affected workflows and evidence sufficiency, not whether a live
test file changed.

### Verification target selection

Every Build starts with `check`, the complete provider-denied offline gate. Select
additional targets by affected behavior and preservation risk, not by edited filenames:

| Target | Select when | Classification and prerequisites |
| --- | --- | --- |
| `check` | Offline sufficiency covers the behavior and failure controls; a later Intent may use check only. | Offline; installed dependencies and the tools below. Provider dispatch is denied. |
| `live-shape-to-build`, `live-reviewer-rework`, `live-general` | The corresponding configured-default lifecycle or Review workflow (on `default_route`) can change. | Provider-backed on `default_route`'s harness; network, its installed runtime and Kogen login, `expect`, and `rsync`. |
| `live-shaping-quality` | Shaping prompts, continuation, Draft quality, evaluation cases, prerequisites, or its evidence manifest can change. | Provider-backed; network, configured Codex authentication, and maintained evaluation sources. |
| `live-native` | The authenticated native boundary, managed runtime/login/discovery, compatibility runner, helper routing, profiles, or native receipts can change. | Provider-backed; installed pinned Codex runtime and configured authentication. |
| `cold-offline` | Cold-cache behavior, the offline recipe, dependency copying, toolchain setup, containment, or cold cleanup can change. | Offline, though expensive; installed dependency sources, `rsync`, and the offline toolchain. Provider dispatch is denied. |

Use check only when deterministic offline evidence is sufficient. Select one
narrow paid target per scenario only when its proof names a provider-only
observation that offline rehearsal cannot establish. The controller deduplicates
and orders selected targets by catalog dependency and cost rank, not scenario
order, and there is no aggregate target. Multiple scenarios may collectively
select multiple boundaries. Offline rehearsal proves recipes and evidence
consumers, not real provider access. For multiple affected boundaries, select
each relevant target through its own scenario proof and causal reason.

Build validates every selected target against the catalog and Makefile before
Developer launch. Stop preserves Candidate/session/attempt binding, verification
retries, required artifacts, receipts, and the fresh-Review boundary.

Kogen loads the tracked project hooks and launches the selected route's harness with approval, sandbox, and hook-trust prompts bypassed so the Build can run autonomously: Codex CLI with its bypass flags, Claude Code with `--dangerously-skip-permissions` (no permission prompts and no sandbox) for every role, including interactive Shaping and login.

Drafts, Approved Intents, Build locks, and raw runtime logs are local and ignored by Git. Complete Intents and concise verification evidence accompany successful commits. `KOGEN_HARNESS` remains an offline test override; ordinary work selects Kogen's pinned managed runtime, never a `claude` or `codex` from PATH.

## Choosing a route

Each route's `harness` in `.kogen/config.yaml` is `claude` or `codex`; any
other name is rejected with that list, but only for the route a session
selects — an unselected route may name an unsupported harness without
blocking other routes. Build, Shape and provider-outcome handling call one
harness interface; the selected route's adapter supplies install and login
readiness, launch context, fresh and exactly resumed Developer turns, Reviewer
verdicts and the interactive Shaper. The Stop hook, Check and verification
records are shared and harness-independent. Both adapters' offline suites run
in every `make check`.

Switching provider means either passing `--route <name>` for one session or
changing `default_route` for future ones, after that route's harness install
and login. The general provider-backed lifecycle targets (`live-general`,
`live-reviewer-rework`, `live-shape-to-build`) run on `default_route`, while
the Codex-only `live-native` owners always resolve the one route whose harness
is `codex` (and fail, listing the candidates, when there is none or several).
Re-proving a harness therefore means running those general targets with
`default_route` naming a route on that harness (plus `live-native` for Codex)
before relying on it; another route's earlier paid evidence does not carry
over. Codex remains a supported adapter; its documentation below still
applies when a route names `harness: codex`. Harness setup commands
(`mix kogen.{claude,codex}.{install,login,status}`) never select, require or
validate a route — they operate on their own harness regardless of which
route is `default_route`.

## Managed Claude Code runtime and login

`mix kogen.claude.install` installs the exact Claude Code release pinned by this
checkout (2.1.280) from the official npm registry into Kogen's managed root,
checking the pinned per-platform sha512 integrity, staging privately and
publishing atomically. It never resolves latest, never uses a `claude` on PATH,
and never writes to personal Claude Code locations such as `~/.local/share/claude`.
Repeating it reuses an intact installation; a failed download, integrity check or
extraction preserves any working runtime and every login. Every Kogen launch sets
`DISABLE_AUTOUPDATER=1`, so the managed runtime never updates itself. Pin changes
follow the [Claude Code runtime upgrade workflow](workflows/claude-code-runtime-upgrade.md).

Kogen's Claude Code login is separate from personal Claude Code, so Kogen can use a
different account or subscription. `mix kogen.claude.login` opens the managed
interactive `claude` in Kogen's shared scope; complete Claude Code's own first-run
flow there, choosing either a Claude subscription or Anthropic Console (API
billing) login, then exit. `--project` does the same in this project's private
scope, selected first so cancellation never falls back to the shared login;
`--use-default` switches the project back to the shared scope and keeps retained
project logins. Arguments after `--` are forwarded unchanged to `claude`:

```sh
mix kogen.claude.login
mix kogen.claude.login --project
mix kogen.claude.login --use-default
mix kogen.claude.login -- --help
```

`mix kogen.claude.status` reports the pin, installation, effective scope and the
`loggedIn` and `authMethod` metadata of `claude auth status`, never credential
values or remaining quota. Fresh and continued Shaping and Build stop before any
model launch and name the fix when the pinned runtime, the selected login, or a
proven model is missing.

Runtimes, scopes and selectors live under `~/Library/Application Support/Kogen/claude`.
Each scope (`accounts/shared`, `accounts/projects/<project-id>`) is a private
`CLAUDE_CONFIG_DIR` holding Claude Code's own config and sessions. Claude Code keeps
each scope's login in the macOS Keychain keyed by the scope path, so never move or
rename a scope directory: that loses its login. Kogen never reads, copies or prints
credentials and never touches personal `~/.claude`. Role launches load only project
settings plus Kogen's hook settings (`--setting-sources project`), no MCP servers or
cached account connectors (`--strict-mcp-config`), and remove inherited provider
variables such as `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, base URLs and
Bedrock/Vertex switches.

Interactive Claude Code asks once per new repository whether to trust it (the
default answer exits), even in bypass mode. Answer it for your own repositories;
Kogen never answers it.

### Proven Claude Code models

Configured Claude Code models must appear in the model picker
[`priv/kogen/claude_code/models.yaml`](priv/kogen/claude_code/models.yaml), which
lists only models with retained evidence: `claude-opus-5-5` and `claude-sonnet-5`,
each at efforts low, medium, high and xhigh. Haiku 4.5 is excluded because it does
not support the per-role effort Kogen configures. Kogen launches the exact
configured model and effort, never a fallback model, and does not intercept
provider requests. It records the model each response came from, including
helper responses linked to their parent, and fails a turn whose root response came
from another model. Opus 5.5 for every root role consumes a subscription quickly;
limits surface as provider errors, never as model substitution.

Each role gets its own Claude Code agents, `kogen-scout`, `kogen-worker` and
`kogen-expert`, carrying the global helper profiles but only that role's authority:
Developer scouts are read-only, workers may edit their assigned paths, and experts
are read-only with Bash; every Reviewer and Shaper helper is read-only. Built-in
Claude Code agents are denied to every role. The Developer's final message carries
no schema; Kogen never validates or parses it, and controller code builds the
handoff report on its own. The Reviewer still returns its verdict through
`--json-schema`.

## Managed Codex runtime and login

`mix kogen.codex.install` installs and validates the exact official native runtime pinned by this Kogen checkout. Repeating it verifies and reuses an intact installation. Failed staging preserves existing runtimes, accounts, and sessions.

`mix kogen.codex.login` delegates browser login to native Codex in the shared Kogen scope. Kogen scope options precede `--`; native arguments follow it unchanged:

```sh
mix kogen.codex.login -- --device-auth
mix kogen.codex.login --project -- --device-auth
printenv OPENAI_API_KEY | mix kogen.codex.login -- --with-api-key
printenv OPENAI_API_KEY | mix kogen.codex.login --project -- --with-api-key
mix kogen.codex.login -- --help
```

Device authorization still requires a human. `--project` selects a private project scope before login, so cancellation never falls back to shared credentials. `mix kogen.codex.login --use-default` explicitly reselects shared login without authenticating or deleting retained project credentials. Native Codex owns credential formats and refresh; Kogen never imports personal credentials.

`mix kogen.codex.status` reports the checkout pin, installation and actual active-use records, effective scope, and native local login state. It does not install, authenticate, call a model, expose secrets, or claim remote entitlement. Fresh/continued Shaping and Build stop before provider work when the pinned runtime or selected login is missing.

Managed distributions, accounts, selectors, settings generations, sessions, and compatibility evidence live under `~/Library/Application Support/Kogen/codex`. Per-launch discovery homes exclude personal Codex settings while project guidance and tracked hooks remain available. Shell tools and hooks retain the caller's HOME and exact set/unset XDG semantics. Active operations retain their concrete runtime and session across Review and exact resume; new checkouts select their own pin.

When upgrading Kogen's pinned Codex runtime, follow the [Codex runtime upgrade workflow](workflows/codex-runtime-upgrade.md).

## Run the checks

```sh
make check                 # Complete provider-denied offline gate
make live-shape-to-build  # Connected Shape-to-Build lifecycle acceptance
make live-reviewer-rework # Build-only Reviewer rework acceptance
make live-general         # Independent semantic Reviewer acceptance
make live-shaping-quality # Provider-backed maintained Shaping evaluation
make live-native          # Provider-backed native/runtime/helper compatibility
make cold-offline          # Offline gate from an empty private build cache
```

Fetch dependencies first. Python 3.11 or newer, `rsync`, and the macOS Command Line Tools (`xcrun clang`)
are also required for the offline gate and bounded subprocess probes.
`make check` runs formatting, forced warnings-as-errors compilation,
strict Credo, Boundary enforcement (including its compiler negative control), ordinary
tests, and the complete fake lifecycle without provider requests. No dependency
fetching or cached test results are used. The recipe reports each stage and the
whole gate's elapsed time, including failures; roughly ten seconds is a warm-cache
guideline, with no elapsed-time failure cutoff.

All test modules run asynchronously. Cases that mutate cwd or environment execute
in private OS processes using the current compiled application and dependency code;
fixtures, temporary roots, and writable build caches stay private. The fake public
Shape/Build fixture uses a small real check through the tracked Stop hook, including
failed Check correction and independent Reviewer rework. It never nests this suite.
Readiness-aware process probes give startup and post-readiness behavior separate
monotonic bounds, reject stale markers, and settle owned descendants before cleanup.
Dependency fixtures reject destination collisions and materialize linked sources
instead of retaining writable aliases to installed dependencies.
See [the check workflow](scripts/check/README.md) for maintenance and timing conditions.

The provider-backed lifecycle targets are narrow owner routes, not a complete suite. They
run on `default_route`'s harness only and require network access, its installed runtime
and Kogen login, `expect`, and `rsync`; create disposable
fixtures; and retains evidence under `.kogen/runtime/`. It covers real failed-check
correction, exact Developer resume, reviewer-directed rework, and fresh independent
Review. Separately selected `make cold-offline` owns the empty-cache offline run. Set
`KOGEN_LIVE_LOG_DIR` to retain lifecycle or cold evidence elsewhere.

## Project and contact

Kogen continues work that began as Optimum Codegen. The retained history predates this core; commit `3f5af338` marks the **Start from clean slate** boundary. Earlier implementation instructions are historical; the fuller design remains a revisable direction for future features.

Read the [Origins](https://kogen.dev/origins/) for the story behind Kogen.

Questions and inquiries: [contact@kogen.dev](mailto:contact@kogen.dev).

Copyright 2026 Optimum Tech, LLC. Licensed under [Apache 2.0](LICENSE).
