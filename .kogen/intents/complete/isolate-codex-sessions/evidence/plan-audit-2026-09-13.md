# Current repair plan: operation lifecycle and consumer evidence

This is the current repair entry point, superseding the ordering and current-tense
“latest” diagnoses in earlier repair notes. Those notes remain historical evidence.
Authority: after authorizing the first failure amendment, the Shaper supplied the
second failed Build and requested a more thorough investigation. This amendment
clarifies existing acceptance; it does not change scope, approval, provenance,
resumption limits, or gate ownership. No production/test/configuration edits or
Build restart were performed by the shaping audit.

## What the plan missed

The isolation mechanism and its bounded native fixture were investigated, but
integration guidance did not sufficiently specify who owns a complete operation's
selected runtime, account, final role, launch receipt, session locator and cleanup.
Component preparation and serializer tests can pass while the public route fails
before a session starts. Repeated full Builds are an expensive way to discover
these deterministic boundary defects. Repair the combined route first; do not
weaken acceptance or add retries to compensate.

## Latest observed state

Controller record: `.kogen/runtime/scenario-tracking/tKzl0rL70yx32Aaz830OXZS2/record.json`.
Attempt 0 passed Check (285 offline tests, candidate
`c33b57c7598833ba3670ac35f927fd8a1db70526`) and failed live: five failures out of nine.
Attempt 1 ended during Developer rework with a provider websocket broken-pipe
error, before another Check/target settlement. This was not exhaustion of both
outer resumptions. There is no accepting top-level Review. The current dirty tree
contains subsequent unverified edits; it is not the checked Candidate.

Confirmed integration defects:

- All five evaluation transports under
  `.kogen/runtime/shaping-evaluation-1789326000714-35/` report exclusive-write
  collisions on their own `managed-launch-context.json`. The public route prepares
  a context for native login status and again for launch; both inherited the same
  receipt destination. The previous tuple serialization defect is not this failure.
  Current `lib/kogen/codex.ex` removes the receipt variable from login preflight;
  that later edit has no settled gate evidence. The single-prepare test in
  `test/kogen/codex_environment_test.exs` cannot establish public-route correctness.
- `test/support/shaping_evaluation/driver.py` still selects shared-account sessions
  globally. Project-selected authentication requires the selected operation's
  concrete session root. Its `managed_runtime_context` and `managed_launch_context`
  helpers are unused definitions, not evidence of a working alternate route.
- Context retention in `lib/kogen/codex/environment.ex` precedes Harness's final
  role stamping. A source-bound synthetic control demonstrates that the real
  `managed_resume.py` consumer lets a serialized Developer role override an outer
  Shaper role. This is a demonstrated boundary hazard, not an assertion that the
  failed live sessions carried that role.
- The native-helper run at
  `.kogen/runtime/live-evidence/native-helper-21046-818-1789326000782227708/`
  retained three completed children with the selected models/efforts but null
  requested kinds. The committed validator rejects that actual receipt; a control
  adding expected kinds accepts. Current unverified edits remove kind requests,
  collection and assertions. That weakens required explorer/worker/default routing
  evidence and is not an acceptable repair. Null fields do not establish that the
  runtime lacks the native capability.

Other failures must remain distinct: the connected lifecycle retained a provider
connection reset, and the semantic Reviewer case timed out at 600000 ms. The
retained output does not establish the timeout's underlying cause. Do not label
all five failures as transient networking, infer success from a duration, or
silently alter provider-error handling, timeouts or budgets.

Successful core evidence is also retained: the native compatibility receipt at
`~/Library/Application Support/Kogen/codex/compatibility/compatibility-1789326000942-498/evidence.json`
records discovery/environment controls, blocked-gate evidence, successful shaping
and an internal accepting Reviewer. This supports the core mechanism; it does not
prove the failed public consumers or constitute acceptance of this Build. Preserve
unchanged source-bound success rather than rerunning it solely for a fresh receipt.

## Required repair sequence within this Intent

1. Distinguish checked Candidate evidence from the unfinished rework. Inspect the
   current source and failed receipts before editing; preserve user work. Do not
   restore a historical prototype wholesale or treat current README claims as proof.
2. Give each operation one selected runtime/account/context owner. Trace native
   login preflight, operation acquisition, settings generation, final role,
   receipt publication, launch, capture, exact resume, and cleanup. Login/status
   preparation must not publish the model-launch receipt. Publish the final context
   once after its role and account are fixed. Do not replace exclusive publication
   with overwrite/append to hide collisions. Keep owned resources alive through
   capture/resume and release them on success and failure.
3. Pass explicit selected scope and session locators to every affected fixture
   consumer, including continued Shape, helper capture, root-profile audit,
   semantic Review and connected/rework fixtures. No shared or personal fallback.
   Remove or align dead competing preparation paths; one wire representation
   preserves unset versus empty variables and final role consistently.
4. Retain helper kind/profile assertions and their corruption controls. Collect
   native evidence for the requested explorer/worker/default kinds. If actual
   native schema evidence shows incompatibility, expose that concrete conflict;
   do not infer it from missing collection or silently remove the requirement.
5. Before another full live attempt, add and run a focused composed offline
   regression through the real fresh and continued public Shape paths: installed
   synthetic managed runtime, selected login-status preflight, final launch receipt,
   actual Python resume consumer, selected session capture and owned cleanup.
   Fake the native endpoint, not Kogen's operation path: a `KOGEN_HARNESS` shortcut
   that skips managed selection/preflight is insufficient. Cover shared and project
   scope, two preparations in one operation, stale inherited role, unset/empty
   environment, serialization failure, missing receipt and failure cleanup.
   Demonstrate disconfirming controls for the old collision/wrong-scope/stale-role
   paths. These focused tests are Developer-owned non-gate work. This audit has
   not executed that complete regression and does not claim it passes.
6. Then use the unchanged Stop Check and outer-owned declared targets/independent
   Review. Retain exact source-bound receipts for each affected consumer. The outer
   driver owns ephemeral transport/session observations; Review inspects retained
   artifacts and Candidate without reconstructing unavailable interaction. A
   provider interruption remains a failed attempt, with no invented acceptance.

## Outcome challenge and completion

A plausible wrong implementation installs Codex correctly, passes an isolated
compatibility probe and serializer test, but cannot start public Shape because
preflight consumes its receipt, or resumes with the wrong account/role. Another
passes the helper test only by deleting kind validation. Neither satisfies the
existing scenarios. The next usable state requires the real user route and all
existing consumers to retain the same selected runtime/account and authority
through start, resume, Review and cleanup, with preservation on failures.

The existing twelve scenarios and risks remain authoritative. This sequence
particularly supports readiness-before-work, scoped-accounts, every-role-discovery,
ordinary-tool-environment, active-runtime-preservation and verification-and-review.
No new command, scheduler, provider recovery system, or extra resumption is added.

## Executed focused controls

See [probe and results](prototypes/plan-audit/README.md). The actual retained helper
receipt was rejected by the committed validator; its synthetic kind control passed.
The actual resume consumer reproduced stale-role override and passed corrected-role
and unset/empty controls. These are source-linked offline observations, not a
repaired public lifecycle or a substitute for native routing evidence. Private raw
Codex conversations were not copied into the Intent.
