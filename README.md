# Kogen

**Shape the feature. Leave the build to Kogen.**

Make the product and UX decisions that define the feature. Specify technical decisions when they matter. Kogen handles the implementation, checking, independent review, rework, and resulting commit.

Kogen is being built from a small core that can shape and build further changes
to Kogen itself. The aim is to grow the rest of the product through that loop:
shape the next feature, approve its Intent, and let Kogen carry out the Build.
The core is a starting point, not the finished product.

The core currently uses Codex CLI and runs inside this repository. Installing
Kogen into arbitrary projects and using other model providers are future work.
The broader design remains a longer-term direction, open to change as Kogen develops.

This repository is being opened quietly so the ongoing work and its history
can be inspected. Kogen is Almir Sarajčić’s personal engineering project.

## Get started

Use Elixir 1.20 with Erlang/OTP 29, Git, Make, and Python 3.11 or newer on macOS. Kogen manages its own complete native Codex distribution; personal Codex and Node are not prerequisites. The pinned managed release is 0.154.0. macOS arm64 is the live acceptance target; the official macOS x64 artifact is selectable but has not been exercised on this host. Provider-backed work uses your selected Kogen login.

From a checkout:

```sh
mix deps.get
mix kogen.codex.install
mix kogen.codex.login
mix kogen.codex.status
make check
mix kogen.shape
```

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

Start Build on a clean branch with a commit at HEAD. Kogen implements the approved feature, runs verification, obtains an independent review, and commits the accepted result with its completed Intent and evidence. A stopped Build returns an error and keeps its work available for inspection. Review the error and working tree before starting again.

## The loop

- **Shaper** is the human who shapes the feature with Kogen and approves the Intent.
- **Intent** captures the shaped feature precisely enough for Kogen to build it autonomously.
- **Build** implements, checks, independently reviews, and reworks when necessary.
- **Commit** records the checked and accepted implementation of one Intent.

The Stop hook owns the complete verification settlement: `make check`, followed by each distinct target declared by the Approved Intent in first scenario occurrence order. `verification_retries` bounds failed Stop verification retries inside the same Developer conversation; those retries do not consume the outer allowance. A settled verification failure, invalid Developer handoff, failed declared target, or Review finding uses one outer resumption of the same Developer, when allowance remains, and a resumed attempt must settle a fresh Stop verification before handoff or Review. Handoff validation follows a passed Stop verification; a missing or invalid handoff never overrides a failed or exhausted verification. An exhausted verification or outer allowance stops the Build rather than claiming success.

Developers and their delegated helpers must not run `make check`, `make live`, any target declared by the selected Intent, or `.codex/hooks/check.sh`, including for early signal; focused non-gate tests remain allowed. A tracked PreToolUse hook blocks the explicit Make, command-list, and Stop-script forms before Bash dispatch. This bounded guard deliberately does not inspect indirect execution through non-gate Make dependencies, wrappers, shell expansion, `sh -c`, or later stdin; the Developer contract still forbids those routes. Existing configurations using legacy outer-resumption naming remain transition inputs; new documentation uses `verification_retries` for Stop verification and the outer allowance for Developer rework.

Every scenario's `verified_by` is a YAML list of Make target names, such as `[check]`. The real lifecycle fixture has a bounded check target; it never invokes the full live suite recursively.

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

After Stop verification settles, Build validates the final Developer message against a
controller-owned schema bound to the fresh attempt token, contract IDs, and
collection sizes. Fresh and resumed attempts each use a distinct private schema
and final-output file; Build retains their exact bytes before cleanup and never
falls back to an earlier file or intermediate message. The handoff covers every
scenario, supplied risk, and open finding with claims and existing file
references. Runtime checks still enforce unique coverage and safe references;
schema compliance is not evidence that a claim is true. Build attaches its owned
gate receipts; claims never count as gate results. A fresh Reviewer assesses every
scenario and explicitly closes or retains every open finding with inspected
counterevidence or repair evidence. Acceptance requires all scenarios satisfied
and no open blocking findings for the current Candidate. Invalid handoffs share
the outer allowance; malformed Review stops without partial closures.
Verification exhaustion takes precedence over handoff parsing, and
outer-allowance exhaustion takes precedence over another launch.

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

Edit the tracked `.kogen/config.yaml` to select the available model and effort
for each root role and required native helper profile. The defaults are
Sol-low for Shaping and Development, Terra-medium for Review;
Luna-low for read-only scouts; Luna-medium for bounded workers; and Sol-medium for a named consequential
expert question. Kogen passes each root profile directly to Codex and renders
the helper profiles into every role prompt; it does not silently inherit or
substitute a missing or unavailable profile. All three helper profiles are
required, though a role delegates only when bounded independent work justifies
the startup and integration cost.

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
through the Build-owned `live` target using the prerequisites below; inspect the
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

Kogen loads the tracked project hooks and launches Codex CLI with approval, sandbox, and hook-trust prompts bypassed so the Build can run autonomously.

Drafts, Approved Intents, Build locks, and raw runtime logs are local and ignored by Git. Complete Intents and concise verification evidence accompany successful commits. `KOGEN_HARNESS` remains an offline test override; ordinary work selects Kogen's pinned managed runtime, never PATH Codex.

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
make check     # Offline checks and the complete fake-harness lifecycle
make live      # Real public shaping, approval, build, review, and fixture commit
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

`make live` requires network access, Codex authentication, `expect`, and `rsync`. It creates a disposable fixture under this checkout, uses scripted approval only for that test fixture, and retains run evidence under `.kogen/runtime/`. It tests real failed-check correction in one Developer session and reviewer-directed rework with an exact Developer resume and a fresh accepting Reviewer. Its outer driver also runs the complete offline check in a disposable copy with an initially empty private build cache and installed dependencies. Set `KOGEN_LIVE_LOG_DIR` to retain that evidence elsewhere.

## Project and contact

Kogen continues work that began as Optimum Codegen. The retained history predates this core; commit `3f5af338` marks the **Start from clean slate** boundary. Earlier implementation instructions are historical; the fuller design remains a revisable direction for future features.

Read the [Origins](https://kogen.dev/origins/) for the story behind Kogen.

Questions and inquiries: [contact@kogen.dev](mailto:contact@kogen.dev).

Copyright 2026 Optimum Tech, LLC. Licensed under [Apache 2.0](LICENSE).
