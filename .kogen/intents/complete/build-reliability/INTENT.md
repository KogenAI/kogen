# build-reliability

**Status:** Draft, reopened after the Expert audit. The approval of 09:14Z is
kept as historical, superseded by the `.gitignore` fix. Not approved.

## Launch

```sh
mix kogen.build --route claude-dominant-adversarial-codex build-reliability
```

The plain command is enough. Since 7ed41f66, each Candidate compiles only in its
own worktree `_build/`, so main's controller never loads Candidate code (lesson 17;
probed in evidence/probe-isolation). Don't compile in the control checkout while
the Build runs.

## Problem

Over 5 days, 40 Builds took 37.1 h, and only 9 were accepted. About 31.7 h were
lost. Every failure class spends the same currency: 3 cycles
(`verification_retries: 2`, `failures_since_pass` in
`lib/kogen/build/verification.ex:130-191`). A formatting error, a logged-out
Codex scope, "model at capacity" and a real Candidate bug each burn one cycle.
In 15 of 30 verified Builds, cycle 1 failed at `check`. In 10 of the 14 exhausted
Builds, at least one cycle went to an offline-only failure. Fixture setup failed
in 0.4-5 s, but only after 6-20 min of earlier targets. The Developer's handoff
shows one receipt and a 6,000-character tail. Failure signatures hash the
offline.py preamble. Two Builds that passed all targets were lost to an invalid
verdict with no repair. The evidence is in the brief's mining report; see
`references.yaml`.

## Outcome walkthrough

The starting state is a Build under the new controller on any route, with
`offline_retries` and `verification_retries` in config. The Developer's turn ends:

1. **Offline gate.** Every selected offline target runs first. A failure is
   labelled `offline`, spends only `offline_retries` and resumes the same
   Developer. The prompt lists every failed receipt, log, manifest and case log,
   with digests and the primary failure lines. A test-file warning fails in the
   first seconds of `check`.
2. **Prepare.** Before the first paid dispatch, the controller runs `prepare`
   for every selected paid target that declares one, with providers denied. It runs the owner's own
   copy (build.lock excluded), warm seed, isolated compile, catalog match, login
   scope and hook toolchain. This repository declares it for live-shaping-quality, live-shaping-smoke
   and live-reviewer-rework. A failure the Candidate caused is `offline`. A
   logged-out scope or missing toolchain stops at once as `environment`, spending
   nothing.
3. **Paid targets.** A Candidate failure spends `verification_retries`. An
   explicit provider marker (usage limit, overload or capacity, 5xx) is labelled
   `provider` and spends nothing. Overload, capacity and 5xx get one retry, and
   usage limit gets none. Every timeout stays a paid failure. A second
   provider failure stops as `provider`. Stored provider evidence keeps the tail.
4. **Refusal and missing proofs first.** Before any cycle, Jev reads the
   Developer's notes. An objection at or above the threshold stops the Build as
   `cannot_comply`, and a missing declared proof test returns the Developer as
   `unfinished_work`, both without spending a cycle.
5. **Unchanged Candidate.** If the Developer returns the same Candidate id after
   a non-provider failure, the Build stops with the signature rather than
   re-running. Signatures now use the failing stage plus the first test id and
   assertion.
6. **Review.** The verdict schema is built for this launch: exactly n scenario
   ids from an enum, a path pattern, and a `receipt` field. `validate` returns
   the error list. One same-session re-ask repairs the shape, never the
   judgement. A second failure stops as today.

7. **Rules that don't freeze the repository.** Ordinary edits pass `check`:
   a test body change, a new config key, reworded README or prompts, a
   comment in a hook, a helper Make target, an incomplete route nobody
   selects. The protection stays: a renamed or deleted catalogued test, a
   broken tracked route, a missing cited path or safety rule, a hook that
   stops blocking, and a missing catalog target still fail.

The next usable state is either a settled Build that reaches Review and commit,
or a stop whose class (`offline`, `paid`, `environment`, `provider`, unchanged
Candidate) and evidence point to the cause.

## Generic by design

Kogen is meant to run in projects without this repository's checks. The
controller knows only these:
- catalog classes (`provider_backed`);
- `offline_retries` and `verification_retries`;
- the optional `prepare` field and its result contract (exit status plus an
  optional `KOGEN_PREPARE_RESULT` environment frame);
- the optional `KOGEN_FAILURE_SIGNATURE` frame, with a normalized-tail fallback;
- the existing target-evidence manifest;
- provider markers owned by the harness adapters.

The following are this repository's own use of those mechanisms, and the
controller never names them: `check`, offline.py's test-compile stage and
signature frame, rehearsals.exs rehearsing every declared `prepare`,
the Shaping driver changes, and the four regressions. Scenario
`generic-project-catalog` proves a complete Build on a non-Elixir project that
has none of them.

## Flexible rules, kept quality (Shaper, 2026-09-26)

"It needs to be flexible enough that it can be changed on the fly, that the
builds pass, but we have to make the builds also follow certain rules so that
the code quality is great at the end." Every rule is judged by one test: keep
it if it protects behavior, isolation, formatting, lint, warnings, or a
reference a consumer resolves; relax it if it only freezes past bytes,
wording, counts or a commit. A relaxation keeps the real protection, and
names a negative control for it (risk `quality-floor`). The strongest case:
the test catalog's hashes failed every edit, yet 7 of its declarations already
name tests that don't exist (evidence/probe-rigidity §1).

## Challenge: plausible implementations that pass but fail the outcome

- **`prepare` re-implements the setup,** so it passes while the owner still
  copies build.lock. Countered by traced owner entry points. `prepare` exists
  only where the setup already lives outside the owner (Q2).
- **Timeouts are labelled `provider`,** so Candidate-caused slowness escapes the
  budget. Countered: only explicit provider markers qualify, with turn-timeout
  and ExUnit-timeout negative controls.
- **The re-ask opens a fresh Reviewer.** Countered by the same session id and an
  unchanged `verdict`, observed live on Codex.
- **The Candidate prompt tells a Reviewer under main's schema to use
  `receipt`,** which main's contract rejects. Countered by the conditional
  prompt wording (risk `self-hosting-review`). This Build's own Review renders
  main's prompt from control at 7ed41f66.
- **A relaxation deletes the check,** so every edit passes and nothing is
  protected. Countered: each relaxation scenario has negative controls for
  the protection it keeps (risk `quality-floor`).
- **Signatures are tested on synthetic strings.** Countered by committed excerpts
  of the real mined receipts.

## Non-goals and where they go

- Paid-target concurrency (concurrency groups, a global cap) →
  `parallel-builds-with-integration`.
- Outside writers → covered by `isolated-candidate-workspace` isolation (its
  scenario `shaping-during-build`). Shaping continues during a Build; isolation,
  not a lock, protects the Candidate.
- The controller loading Candidate code → `pinned-engine-generations`.
- Reusing receipts by footprint, and focused re-runs → a later verification-reuse
  Intent. Exact-bytes reuse stays.
- `prepare` for `live-general` and `live-shape-to-build`, whose setup is private
  to their owner tests → a later Intent, when they need it.
- The canonical login-scope key (defect d) and live-native's `prepare` → a later
  Intent, not yet shaped. `isolated-candidate-workspace` landed without the
  scope-key fix (`project_id/1` still hashes `Path.expand`). The probe evidence is
  in evidence/probe-prepare.
- `.gitignore` additions for the trash patterns → the next Intent, which can edit a declared `.gitignore` once `declared-gitignore-edit` has landed.
- The Build status output and `--notify` → their own Intent (Shaper,
  2026-09-26: "builds status output - yes, it should go into a separate
  intent, but everything else should be this one"). The scenarios as they
  stood are kept in evidence/split-build-status-notify.
- Rules looked at and left for a later Intent (evidence/rules-audit,
  evidence/probe-rigidity): re-reading earlier cycles' evidence from its
  original paths; the text heuristics in `rehearsals.exs`; `.gitmodules`
  still frozen; one retry for transport failures with no provider marker; the
  verification-policy hook missing on resume (cause unconfirmed); readiness of
  `sandbox-exec` and the clang guard; equivalent hook commands
  (`verification_policy.ex:80`); the preservation test that checks old
  packages against the current catalog; unique catalog ranks (kept).
- Durable terminal records, waiting out usage limits, the circuit breaker →
  `durable-builds-and-failure-reports`.
- Never raise timeouts or case budgets, never use best-of-N, never weaken a check.
- Out, per the Shaper: the Shaping progress checklist and Developer scratch checklist (CTX-05), mid-turn messages (EXE-06), the Rust launcher (NAT-03), durable Build state (EXE-04) and multi-Build ownership (EXE-05, EXE-08).
- Not addressed at all: Developer turn length beyond the prompt tune-up (25.6 of 37.1 h), `check` slowing
  to 184-271 s, and the hybrid route's 3-6× slower `live-reviewer-rework`.

## Scenarios

See `scenarios.yaml`: 26 scenarios, covering the five rule relaxations
(flexible rules that keep quality: test catalog, config, docs and prompts,
hooks, Make targets), A (4), B (2), C (4, including the driver replay and the smoke target), D (2), E (2), refusal before verification (1), prompt tune-up (1), process custody (2), no tracked caches (1), declared .gitignore edits (1), and the generic project (1).
There are two paid targets:
- `live-shaping-smoke`, new: one tiny real case through the edited driver,
  mechanics only, about 2.5 min (probed at 156 s);
- `live-reviewer-rework`: the Codex schema and the re-ask.

The 7-case `live-shaping-quality` stays in the catalog, unselected. The driver's
turn-end and fail-fast code is also proven offline, by replaying real retained
rollouts.
