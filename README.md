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

Use Elixir 1.20 with Erlang/OTP 29, Git, Make, and an authenticated Codex CLI on your PATH. The current verification target is macOS; other platforms are unverified. Codex CLI 0.153.4 is the current verification target. Provider-backed work uses your Codex account.

From a checkout:

```sh
mix deps.get
make check
mix kogen.shape
```

Describe one feature. As the Shaper, discuss its behavior and tradeoffs with Kogen’s Shaping Controller, inspect the Draft it writes, and explicitly approve it in that conversation. Approval moves the Intent from `.kogen/intents/drafts/<slug>/` to `.kogen/intents/approved/<slug>/`.

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

Start Build on a clean branch with a commit at HEAD. Kogen implements the approved feature, runs checks, obtains an independent review, and commits the accepted result with its completed Intent and evidence. A stopped Build returns an error and keeps its work available for inspection. Review the error and working tree before starting again; automatic recovery is not implemented yet.

## The loop

- **Shaper** is the human who shapes the feature with Kogen and approves the Intent.
- **Intent** captures the shaped feature precisely enough for Kogen to build it autonomously.
- **Build** implements, checks, independently reviews, and reworks when necessary.
- **Commit** records the checked and accepted implementation of one Intent.

The Developer's Stop hook owns `make check`; the outer Build owns each distinct declared non-check target, in first scenario occurrence order, after matching Check settlement. Failed checks are corrected within the same conversation. A failed outer target or Review finding resumes the same Developer within the existing budget and requires a fresh Stop Check before the full non-check sequence starts again. An exhausted Build stops rather than claiming success.

Developers and their delegated helpers must not run `make check`, `make live`, any target declared by the selected Intent, or `.codex/hooks/check.sh`, including for early signal; focused non-gate tests remain allowed. A tracked PreToolUse hook blocks the explicit Make, command-list, and Stop-script forms before Bash dispatch. This bounded guard deliberately does not inspect indirect execution through non-gate Make dependencies, wrappers, shell expansion, `sh -c`, or later stdin; the Developer contract still forbids those routes.

Every scenario's `verified_by` is a YAML list of Make target names, such as `[check]`. The real lifecycle fixture has a bounded check target; it never invokes the full live suite recursively.

Build validates the full Approved scenario contract before launching a provider.
Each scenario needs a unique nonblank `id`, `given`, `when`, `then`,
`wrong_result`, `evidence`, and a nonempty `verified_by` list of existing targets.
Optional `risks.yaml` entries have unique `id`, `scenario_ids`, and `description`;
file-ownership entries describe existing-path behavior, immediate and later owners,
permitted mutation, validation, Git state, and upgrades. An absent risk file is
recorded as “not supplied.” Shaping leaves unresolved ownership decisions to the
Shaper, including when a protected seed becomes user-owned configuration.

After Stop Check settles, Build validates the final Developer message against a
fresh attempt token. The handoff covers every scenario, supplied risk, and open
finding with claims and existing file references. Build attaches its owned gate
receipts; claims never count as gate results. A fresh Reviewer assesses every
scenario and explicitly closes or retains every open finding with inspected
counterevidence or repair evidence. Acceptance requires all scenarios satisfied
and no open blocking findings for the current Candidate. Invalid handoffs share
the existing rework budget; malformed Review stops without partial closures.

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
Successful publication links a self-contained copy from Complete evidence,
including referenced bytes and concise attempt history; generated names never
replace supplied evidence. Failed publication restores the frozen Approved input.
Build refuses Git assume-unchanged and skip-worktree flags wherever it relies on
Candidate identity, including Stop and publication, without clearing those flags.


## Configuration and local data

Edit the tracked `.kogen/config.yaml` to select the available model and effort
for each root role and required native helper profile. The defaults are
Astra-low for Shaping, Sol-low for Development, Terra-medium for Review;
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

Kogen loads the tracked project hooks and launches Codex CLI with approval, sandbox, and hook-trust prompts bypassed so the Build can run autonomously.

Drafts, Approved Intents, Build locks, and raw runtime logs are local and ignored by Git. Complete Intents and concise verification evidence accompany successful commits. `KOGEN_HARNESS` can select an executable for testing; ordinary use resolves `codex` on PATH.

## Run the checks

```sh
make check     # Offline checks and the complete fake-harness lifecycle
make live      # Real public shaping, approval, build, review, and fixture commit
```

Fetch dependencies first. Python 3, `rsync`, and the macOS Command Line Tools (`xcrun clang`)
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
See [the check workflow](scripts/check/README.md) for maintenance and timing conditions.

`make live` requires network access, Codex authentication, `expect`, and `rsync`. It creates a disposable fixture under this checkout, uses scripted approval only for that test fixture, and retains run evidence under `.kogen/runtime/`. It tests real failed-check correction in one Developer session and reviewer-directed rework with an exact Developer resume and a fresh accepting Reviewer. Its outer driver also runs the complete offline check in a disposable copy with an initially empty private build cache and installed dependencies. Set `KOGEN_LIVE_LOG_DIR` to retain that evidence elsewhere.

## Project and contact

Kogen continues work that began as Optimum Codegen. The retained history predates this core; commit `3f5af338` marks the **Start from clean slate** boundary. Earlier implementation instructions are historical; the fuller design remains a revisable direction for future features.

Read the [Origins](https://kogen.dev/origins/) for the story behind Kogen.

Questions and inquiries: [contact@kogen.dev](mailto:contact@kogen.dev).

Copyright 2026 Optimum Tech, LLC. Licensed under [Apache 2.0](LICENSE).
