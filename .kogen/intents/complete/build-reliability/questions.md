# Questions

## Ask the Shaper

None open. The Shaper's question window closed before Q1-Q3 could be asked
("it's over why are you asking me now at the end? You have 5 minutes budget for
questions and you blew it", 2026-09-26). The Shaping Controller resolved them with
its recommendations, recorded under "Resolved by the Shaping Controller" below.
Any of them can still be overruled before approval.

## Resolved by the Shaping Controller (the window for questions had closed)

**Q1. `offline_retries: 4`.** It is a required top-level key with no default,
allowing five offline cycles per attempt. Offline cycles cost about 3-5 min, and
the worst offline-only runs in the mining (ZJDgU9wo, hAOGGjSC) needed 3.
Undo: change the value in `.kogen/config.yaml` and in scenario
`offline-failures-own-budget`.

**Q2. Two paid targets.** *(Revised after the Shaper's external review,
2026-09-26, point 6. It superseded the earlier three-target resolution.)*
`prepare` exists only where the mined setup defects occurred, and where the setup
already lives outside the owner test file: `live-shaping-quality` (driver.py),
`live-reviewer-rework` (its test/support fixture) and `live-native`
(`Kogen.Codex.Compatibility.prepare_fixture`). `live-general` and
`live-shape-to-build` stay byte-identical, and their `prepare` is a non-goal.
*(live-native's `prepare` later moved out with defect (d); see Q3.)*
Paid targets are `live-shaping-quality`, because the driver is an edited live
owner (review point 2, lesson 9), and `live-reviewer-rework`.
*(Superseded 2026-09-26 by the Shaper's direction, DIRECTION §1.19: an offline
replay of real rollouts plus a new `live-shaping-smoke` target replace
`live-shaping-quality`, which stays in the catalog, unselected.)*

**Q3. Defect (d) moves out.** *(Correction after the re-baseline: it did not land
with isolated-candidate-workspace and has no owner yet.)* *(Revised after the Shaper's review, 2026-09-26,
option B.)* The canonical scope key (`Kogen.Codex.State.project_id/1` and
`Kogen.ClaudeCode.project_id/1` hash `Path.expand`, so `/tmp/X` and `/private/tmp/X`
pick different scopes; evidence/probe-prepare P6c) changes login selection for every
project, and it is exactly what `live-native` exercises. It goes to
`isolated-candidate-workspace`, which owns canonical paths and scope binding, together
with live-native's `prepare`, which would edit `lib/kogen/codex/compatibility.ex`. This
Intent keeps two paid targets and does not touch `lib/kogen/codex*` or
`lib/kogen/claude_code.ex`.
*(Later refined: process custody edits the `Port.open` launch sites in
`lib/kogen/codex.ex` and `lib/kogen/claude_code.ex`. Their scope selection stays
byte-identical, and `lib/kogen/codex/*` stays unguarded; risk `owner-edit-selection`.
`isolated-candidate-workspace` landed without defect (d), so it has no owner yet.)*

## Shaper's external review (2026-09-26), applied

The Shaper shared a review of this Draft and its recommendations:
1. **Lazy loading (lesson 17).** Added risk `lazy-controller-modules` and the
   "Build launch requirement" in INTENT.md, with the exact preload command.
   *(Superseded: the Shaper rejected launch wrappers; see "Controller lazy
   loading" below and `intent.yaml` `build_prerequisite`.)*
2. **The driver is an edited live owner.** Scenario `shaping-suite-finishes-cases`
   now selects `live-shaping-quality`. *(Superseded: now `live-shaping-smoke`
   plus an offline replay; see above.)*
3. **Contradiction with #5.** The non-goal now says outside writers are covered by
   `isolated-candidate-workspace` isolation (`shaping-during-build`), not a lock.
4. **Turn timeouts.** Only explicit provider markers (usage limit, overload or
   capacity, 5xx) count as `provider`. Every timeout, harness turn or ExUnit,
   stays a paid failure that goes back to the Developer.
5. **Prove before approval.** Not done in Shaping; see "Open before approval".
6. **Paid cost.** Two paid targets (Q2 above). The live-general and
   live-shape-to-build scenarios were removed.
7. **`offline_retries`** stays required, with a README line and a refusal message
   naming the key (scenario `offline-failures-own-budget`).

## Pre-approval probes (review point 5): done

Point 5 was settled with small disposable probes rather than a full prototype
run (Shaper: "you can create your own mini-project, mini claude/codex session").
See evidence/PROBES.md. Nothing is open.

## Controller lazy loading (Shaper, 2026-09-26)

- The Shaper rejected the preload launch wrapper: "No, I'm not gonna do hacks.
  This intent needs to fix all that."
- A Candidate cannot protect its own Build from main's lazy loading, because the
  fix must be in main's `mix kogen.build` before the Build starts
  (evidence/probe-preload).
- So the preload goes into its own tiny Intent, shaped in its own session and
  built first. build-reliability then runs with the plain command
  (historical: `intent.yaml` once had `build_prerequisite`; it was replaced by
  `launch` after the re-baseline, see the update below).
- Isolation (`isolated-candidate-workspace`) is the lasting fix, but it is not
  required by this Intent.
- *Update (re-baseline on 7ed41f66):* isolation has landed, and the tests show
  that Candidate compiles no longer touch control's `_build`. The preload Intent
  is no longer needed for this Build, and it launches with the plain command
  (`intent.yaml` `launch`).

## Cannot_comply before verification (Shaper, 2026-09-26)

- Added as scenario `notes-and-selectors-before-verification` and dropped from the
  non-goals, because `shaping-preflight-audit` doesn't own it.
- Evidence: Build IEf3rtZ8xYuvEPSj_gtdanD8, supplied by the Shaper (not on this
  machine).
- The ordering was verified in 7ed41f66's `build.ex:778-948`.
- The Shaper: "Decide technical details yourself; ask me only UI/UX/product
  questions."

## Shaper's 2026-09-26 folds (scope decision, DIRECTION §1.17)

Added:
- the prompt tune-up (ROADMAP 4b, BLD-09);
- process custody (ROADMAP 7, EXE-03);
- the Build status output, in the Shaper's exact layout; *(moved out on
  2026-09-26, see "Appetite" below)*
- `--notify`; *(moved out with the status output)*
- trash cleanup;
- refusal before verification.

The ROADMAP now marks 4b and 7 as delivered by build-reliability. The Shaping
progress checklist and the Developer scratch checklist (CTX-05), mid-turn
messages (EXE-06), the Rust launcher (NAT-03), durable Build state (EXE-04) and
multi-Build ownership (EXE-05, EXE-08) stay out.

## Assumed

*(Items 1, 2 and 7 belong to the split-out status-output Intent since
2026-09-26; they are kept here as history.)*

1. **Terminal detection uses `:io.getopts(:standard_io)[:terminal]`.**
   `:io.columns()` returns `{:error, :enotsup}` under `mix` even in a real pty
   (evidence/probe-status-notify).
2. **Status lines go to stdout.** Durations are `Ns`, `Nm` or `XhYm`. Dates use
   local time (`Sat 26 Sep 11:42`). The phase totals are Developer, checks
   (offline targets and `prepare`), live (provider-backed targets) and Review.
   `unfinished_work` also appears as a stop class.
3. **The Reviewer's checked/not-checked statement goes in the existing finding
   `reason`, with no new verdict key.** A new key would break this Build's own
   Review under main's static schema (evidence/probe-prompts).
4. **The Developer's self-review is reported in its existing per-scenario prose
   notes**, which Jev reads. No new structured section (§1.16).
5. **Custody uses one Python supervisor**, generalised from `VerificationRunner`:
   it stays outside the group, starts the child with a new session, and acts as a
   ppid==1 / pipe-EOF watchdog. Pid, pgid and lstart are recorded in the lock.
   Orphans are identified by pid plus lstart, because `ps` shows no environment
   on macOS (evidence/probe-custody).
6. **Ctrl-C without a menu uses `mise.toml` `[env] ELIXIR_ERL_OPTIONS = "+Bd"`.**
   Break can't be disabled at runtime (badarg), and a relaunch can't take the
   terminal's foreground group (EPERM). Without mise, the menu still appears,
   but the watchdogs reap regardless (risk `custody-ctrl-c-without-mise`).
7. **`--notify` uses the Shaper's chosen commands** (2026-09-26, picked by ear):
   `afplay -v 6 -r 0.6` with Glass for accepted and Basso for stopped, and
   `osascript display notification "<Accepted|Stopped (<class>)> · <duration>"
   with title "Kogen" subtitle "<slug>"`. The fallback is `\a`. Whether the
   banner shows depends on macOS notification permission.
8. **Interactive `mix kogen.shape` sessions are outside custody.** It covers the
   processes a Build launches.

## Expert audit (Codex gpt-6-sol high, 2026-09-26; evidence/expert-audit)

1. **Blocking, confirmed** at `guarded_paths.ex:33-67`: a `.gitignore` edit
   stops any Build. Fixed: the trash scenario uses a `check` pattern test and
   leaves `.gitignore` untouched.
2. **Not blocking:** main doesn't run `prepare` in this Build. It is only a
   rehearsal of setup each live owner does itself. Clarified in risk
   `self-hosting-accounting`.
3. **Not blocking:** `mise.toml` affects only later Builds. Clarified in the
   custody scenario.
4. **Gap:** the loader validates `prepare` as a nonempty argv list. Added to
   `controller-runs-prepare-before-paid`.

## Guarded paths (Shaper, 2026-09-26)

- "let's then fix the guarded paths and the trash (.gitignore change) can be a
  future thing." Added scenario `declared-gitignore-edit` (probe:
  evidence/probe-gitignore).
- Not folded, and still unowned: the test-reliability hash catalog, and the
  clean-control-checkout admission rule. The Shaper did not ask for them here.
  *(Superseded for the hash catalog by the continuation of 2026-09-26: now
  scenario `test-catalog-binds-declarations`. The clean-checkout rule stays.)*

## Settled by the brief (not re-asked)

- One Intent covering A-E ("nah, all of them together", 2026-09-26).
- No auto-formatting by the controller, no raised timeouts or case budgets, no
  best-of-N, no weakened checks.
- `live-reviewer-rework` on the Codex-Reviewer route is the paid proof for E.
  Its fixture already runs `claude-dominant-adversarial-codex`
  (`test/support/live_reviewer_rework_fixture.ex`).
- Non-goals and where they go: see INTENT.md.

## Accepted engineering choices (from source; say if any is wrong)

1. **`prepare` is a catalog field with an argv command** (like
   `rehearsal.command`), not a Make target. The Makefile/catalog 1:1 rule
   (`validate_declared_targets/2`) and main's tolerant loader stay untouched.
2. **The offline gate is by class, not by name.** Every selected
   `provider_backed: false` target must pass before any paid dispatch. README
   says no target name is special. Today the gate only emerges from `check`
   dependencies plus halt-on-first-failure.
3. **Provider retry per class.** Overload, capacity and 5xx get one retry. Usage
   limit gets none, because waiting for its reset is a non-goal
   (durable-builds-and-failure-reports). A second provider failure stops the
   Build as `provider`. No timeout is ever `provider` (review point 4).
4. **Unchanged Candidate means no re-run.** After a non-provider failure, a
   Developer turn that leaves the Candidate id unchanged stops before the cycle,
   with the previous signature. That is how this Draft reads "stops instead of
   re-running the cycle".
5. **The re-ask keeps the judgement.** When the invalid verdict parsed, the
   repaired verdict must keep its `verdict` value. Otherwise the Build stops.
6. **In `check`, `prepare` runs its login/toolchain steps against controlled
   passing and failing scopes**, so `check` keeps needing no real login. The
   controller (caller 2) runs them for real.
7. **Live owners emit their manifest on failure.** live-native already does
   (`test/kogen/codex_compatibility_test.exs:301-303`). For live-shaping-quality,
   the driver writes the manifest on failure and prints it. The owner's failure
   message carries the driver output, so the owner stays byte-identical. The
   live-reviewer-rework and live-shape-to-build owners emit no manifest today,
   and this Intent adds none.

8. **The controller stays generic** (Shaper steering, 2026-09-26: "mind you,
   not every projects has this constellation of checks"). `prepare` is
   optional. Environment class and failure signatures come through documented
   generic frames, with a normalized-tail fallback. The controller never names
   `check`, offline.py, ExUnit or the Shaping driver. Those are this repository's
   own use of the mechanisms. Proved by scenario `generic-project-catalog`.

## Rules that fail Builds for simple changes (continuation, 2026-09-26)

- The Shaper, on the audit list in CONTINUE.md: "Let's see what else we can
  improve", then "add whatever needs adding for stability improvements
  brosky", then "investigate thoroughly before we include that stuff. we
  shouldn't make the system so rigid that it fails for simple stuff as we've
  seen. it needs to be flexible enough that it can be changed on the fly, that
  the builds pass, but we have to make the builds also follow certain rules so
  that the code quality is great at the end".
- Resolved by the Shaping Controller under that direction, after probes
  (evidence/probe-rigidity): fold audit items 1-6 as five scenarios
  (`test-catalog-binds-declarations`, `config-checked-by-reader`,
  `docs-and-prompts-checked-by-meaning`, `hooks-checked-by-behavior`,
  `helper-make-targets-allowed`). Items 2 and 6 share the config scenario.
  The whole-suite sweep extended item 3 to five more prose-pinning tests.
- The hash catalog was a non-goal pointing to the parked
  `shaping-preflight-audit`. It is now in scope, because the probe showed the
  hash both fails every edit and misses real drift (7 stale rows).
- Not folded, with reasons in evidence/probe-rigidity: audit items 7 and 8, the
  "consider or defer" list, unique ranks, the preservation test over old
  packages. No Build in the mining was lost to them, or a fix needs its own
  probe or product choice first.
- The Shaper asked for a review of the whole Intent by Astra medium, Sol high
  and Opus high before approval. Results: `evidence/review-2026-09-26/`.

## Appetite after the review (decided by the Shaper, 2026-09-26)

Decision: "builds status output - yes, it should go into a separate intent, but
everything else should be this one". `build-status-output` and `build-notify`
moved to a separate Intent, not yet shaped (evidence/split-build-status-notify).
Process custody, the orphan sweep and the docs-and-prompts relaxation stay. Assumed
items 1, 2 and 7 above now belong to that Intent. The question as asked:

**Appetite after the review.** Astra, Sol and Opus all
call 28 scenarios with two paid targets high-risk for one Developer conversation.
Under main's accounting, this Build still spends a paid cycle on each formatting
or compile failure. Opus proposes splitting out process custody and the orphan
sweep, status output and `--notify`, and the docs-and-prompts relaxation. Sol
names custody, the re-ask and the smoke target as the largest surfaces. The
Shaper earlier chose one Intent ("nah, all of them together") and folded custody,
status and `--notify` on purpose.

## Left undecided

None.
