# Continued shaping decisions

## B1 reshape from the Shaper's brief, 2026-09-24 (Claude Code visit)

Provenance: in this visit the Shaper supplied
`.kogen/runtime/shaping-followups/SHAPE_B1_ISOLATED_CANDIDATE.md`, which asks
for this identity to be continued (`mix kogen.shape isolated-candidate-workspace`).
Its "Decisions already made (do not reopen)" and "Drop" lists are applied as
the Shaper's direction:

- Scope: B1 only. One Build at a time with the global lock kept, no
  concurrency, no continuation, and no integration with a newer `main`.
- The verification code that judges a Build must not come from the
  Candidate. Hooks run from the control checkout; `make check` and targets
  run against the Candidate.
- Keep it simple: `git worktree` and ordinary files.
- Warm seeding is dropped. The Candidate gets a plain copy of `deps/` and
  compiles cold (the Shaper measured about 3 s; this visit's probe measured
  3.29 s). Creation stays in one place for a later seeding step (brief 17).
- Dropped: the 41-file saved implementation and its recovery instructions
  (now optional reference only), the APFS clone and symlink-admission policy,
  and the attempt semantics written for the old JSON handoff. The
  pre-reshape contract moved to `historical/2026-09-22-warm-seed-revision/`.
- Baseline: the scenarios are rewritten against `main` at
  `5b44ceb4dfb62c07296c1a799246c125f252ac69` ("Rewrite the scenarios against
  `5b44ceb4`"). This supersedes the 2026-09-23 plan to reshape against
  `6cdb2912`. It is recorded as `reshaped_against` in `intent.yaml`; the
  original `shaped_against: c1f08532` block stays as history.
- Paid proof comes only from `live-reviewer-rework` and `live-shape-to-build`;
  the Shaper must be asked before adding any other paid target.

Controller engineering choices (inspected source and probes, see
`evidence/b1-worktree-probe-2026-09-24.md`):

- Candidate branch (initially proposed `kogen/build/<build-id>`, now
  `kogen/<slug>/<build-id>` per Q2), where `<build-id>` is the
  scenario-tracking record id. This namespace is distinct from the stale
  `97109bf9` worktrees, which stay untouched.
- The controller process keeps control as its cwd. Every Candidate-side and
  control-side operation gets its root explicitly. `Harness.open/2` loses its
  `File.cwd!()` default, and the login scope keys on the control project.
- Hooks get both roots through the launch environment, extending the
  existing `KOGEN_PROJECT_ROOT`. Hook commands and scripts stop resolving
  `git rev-parse --show-toplevel` and fail closed without the roots.
- Publication commits in the Candidate. It then checks, in control, the
  admitted branch, the unmoved commit, a clean checkout and the index flags,
  and fast-forwards with a verified sync. The explicit clean check is required
  because the probe showed `git merge --ff-only` proceeds over non-overlapping
  dirty edits.
- The Candidate is removed only after successful publication, without
  `--force`, and the branch with `git branch -d`. Every other outcome keeps
  both and names them.
- The frozen Approved bytes are written into the Candidate's ignored approved
  path so roles read the package in their cwd.
- Catalog rows are edited in the tracked catalog directly. Future Candidates
  do not have the ignored coverage matrix, and recent Builds did not use it.

Shaper answers in this visit (full wording in `questions.md`):

- Q3 Codex hooks: "Support, document limit". Both routes share one mechanism;
  it is documented that Codex reads `.codex/hooks.json` from the Candidate;
  there is no `live-native` target.
- Q1 location: "inside Kogen's own tree". Candidates live at
  `~/Library/Application Support/Kogen/build-workspaces/<project-id>/<slug>-<build-id>/`
  with owner records beside them. Tests use `KOGEN_WORKSPACES_ROOT`, as
  explained to the Shaper. The in-repository `.kogen/runtime/build-workspaces`
  plan above is superseded. The branch becomes `kogen/<slug>/<build-id>` so
  names are readable.
- Q2 commands: a Kogen list command is required ("git worktree list is
  useless ... names are obfuscated"). Publish is dropped ("pretty much
  useless"). Remove is added with a guard on accepted commits only
  (`--discard-accepted`). Prune is added, and cross-project orphan cleanup
  needs its own flag ("unexpected behavior"). All commands act on the current
  project only. The command names `mix kogen.candidates[.remove|.prune]` are
  the controller's proposal and are open to veto.
- Parallel Builds: the Shaper asked about including them and suspected it
  was too much. The controller answered that B1 keeps the global lock and
  that B2 (per-Build state, pinned engine, serial publication) and brief 22
  (rebase and re-verify) remain separate. The order is not changed.

- Independent review, forwarded by the Shaper: "the agent was right /
  these other commands are unnecessary for now". Prune, `--orphans` and
  `project.json` are cut from B1 and parked in
  `.kogen/runtime/shaping-followups/SHAPE_CANDIDATE_PRUNE.md`, for B2 or a
  separate Intent. List and remove stay. Both live fixtures use a
  space-containing `KOGEN_WORKSPACES_ROOT`. The review's other notes (the
  tracked-file editing limit, the session allowance) need no contract change.

The Draft was unapproved at this point in the visit. The Shaper then approved it
explicitly in the same conversation ("I approve", 2026-09-24T05:48:08Z); see `approval.md`.

## Parallel-ready reshape, 2026-09-23 (Claude Code visit)

Provenance: the Shaper supplied
`.kogen/runtime/shaping-followups/SHAPE_PARALLEL_READY_BUILDS.md` in this
visit. It supersedes the 2026-09-22 “one active Build only” narrowing for this
Intent's direction: per-Build worktrees, concurrent Builds of different Intents
without the global `.kogen/build.lock`, serial publication that stops honestly
when `main` moved, and per-session named routes. It explicitly permits not
inheriting this Draft's complexity and splitting when one Build is too large.
Where it conflicts with briefs 21/22 (continuation before concurrency; fresh
Review after rebase), the Shaper's newer brief and `ROADMAP.md` govern; the
rebase policy is context for the next Intent only.

Accepted in this visit:

- Control checkout sync (Shaper answer): publication requires a clean control
  checkout and refuses otherwise without moving `main`, retaining the
  Candidate. `main` should never be dirty: all work MUST happen in worktrees.
- Saved implementation (Shaper answer: “probably reference only because we've
  made some changes since then, but probably you can find some useful stuff
  there”): the 41-file snapshot becomes optional reference material. This
  supersedes the 2026-09-22 mandatory import and the `repair-plan.md` /
  `developer-recovery.md` obligations, which will be relabelled historical.
  Its `lib/kogen/harness.ex` payload predates `6cdb2912` and must not be
  applied.
- Engine stability (Shaper: “Research and probe this and come back to me with
  the solution you picked”): controller-picked pinned engine per Build, see
  `evidence/engine-stability-probe-2026-09-23.md`. Each Build's long-running
  controller runs from its own recompiled copy of the admitted commit; hooks
  judging the Build come from that copy, not from the Candidate.

- Baseline (Shaper answer: “ofc, it has to be reshaped because the previous
  one was shaped without claude code in the main”): the reshaped Intent is
  shaped against `main` at `6cdb29122fe662c7908aa50a179cac0697639a4a`. The
  original `shaped_against: c1f08532` block and `shaping` provenance remain as
  history; the new baseline is recorded as a separate reshape field when the
  scenarios are rewritten, not by editing the original block.

- Split (Shaper answer to the restated proposal: “alright, I like it … We go
  with intent A first, then B right?”): Intent A, named routes, is shaped in a
  fresh `mix kogen.shape` from `.kogen/runtime/shaping-followups/SHAPE_NAMED_ROUTES.md`
  and built first with `[check]` only. This Draft carries Intent B (worktree
  isolation and parallel-ready Builds) and is reshaped after A, carrying the
  Build's route. Splitting costs one extra `check` run and no repeated paid
  target. The Reviewer stays on the Build's route for now.

- B split (Shaper forwarded an independent review of this proposal that
  agreed with “A → B1 → B2” and raised no objection): this Draft becomes B1,
  isolated Candidate worktrees with one Build at a time; B2 (per-Build
  ownership, concurrent Builds, pinned engine, serial publication lock,
  multi-Build output) gets a fresh Shape later. The pinned-engine decision and
  probe are carried to B2. The same review moved A to select
  `live-shape-to-build` for the real default route and recommended failing on
  the old flat config; both are written into `SHAPE_NAMED_ROUTES.md` for the A
  session to settle.

- No silent fallbacks (Shaper, while reviewing Intent A: “we don't want those
  kinds of defaults / everything needs to be explicit / so we can have a
  default configured, but no silent fallbacks”). B1 applies this too: the
  Candidate project root, control root, route and engine paths are passed
  explicitly; no `File.cwd!()` or config re-read substitutes for them
  (e.g. `Kogen.Harness.open(config, project \\ File.cwd!())`,
  `lib/kogen/harness.ex:20`, `lib/kogen/codex.ex:18`). Route names are
  `claude` and `chatgpt` (Shaper, in the A session).
- Sequencing: B1 is reshaped after Intent A lands, against the post-A `main`,
  so it records the Build's route directly.

Pending: the reshaped B1 scenarios.


## Latest failed Build, source preservation and audit repair, 2026-09-22

Provenance: after Build `181SwyyMv5aW2U838Wh8xXIt` failed, the Shaper requested
Fable diagnosis and then “run cheaper subagents to fix the intent”. This is
authority to repair the same Draft, not approval or implementation authority.
The 11:06 approval is historical. Original shaping/shaped-against bytes and the
existing continuation entry are unchanged; no extra visit entry is appended.

Root integrated the requested Fable-high report with read-only Luna-low advice.
The Luna recommendation to pin two attempts was rejected against actual
`Build.rework/4` and retained three-attempt same-session evidence; the reader
corrected it. An invalid handoff consumes an outer resumption; two-/three-attempt
controls preserve that existing behavior and fresh Review without changing
allowances or introducing counters. No human choice of test mechanics is needed.

The current 41-path dirty implementation is retained byte-for-byte as inert
compressed source payloads inside this Draft with sizes, hashes, modes and base
blob identities. This resolves clean-start availability without creating a Git
checkpoint, touching source, consuming a stash, or changing the accepted c1
baseline. The older 38-file checkpoint and all backups remain intact. Retained
code is known unfinished work, never acceptance evidence.

The complete live-audit producer/consumer and cleanup route is mandatory, not
only the latest failing assertion. Both owners must rehearse their real setup
and retention functions offline, consume the correct verification formats,
retain required artifacts, and cover all session/token/count/native/profile and
Candidate-content assertions. Generated citation tests must independently expose
the observed origin/citation mismatch; permitted recovery must not hide it.

The original-versus-optional-separate installing checkout choice remains. The
old judge commits on the invoking branch; a separate recovery branch or clone
cannot be presented as automatic publication to this main. Keep unrelated work
out of the installing checkout. Concurrency, stopped-Build continuation and
newer-main integration remain parked and unapproved.

Only package validation and source-input integrity checks are performed here.
No current implementation pass, provider success, time bound or next-run
guarantee is claimed. Latest results and advisory limitations are maintained in
`evidence/latest-build-reconciliation.md`.

## Fable-high review and same-Intent repair contract, 2026-09-22

Historical shaping-state note: this section records the review/reopening before
the later explicit approval maintained in `approval.md`; its engineering
decisions and evidence limitations remain applicable.

Provenance: the Shaper requested Fable at high effort after the latest failed
Build and challenged the earlier assurance. Fable was invoked read-only with
`--model fable --effort high`; its runner identifies `claude-fable-5-1`. Root
reconciled its advice against source and bounded citation/native-clone probes.
See `evidence/fable-high-reconciliation.md` for the findings and limitations.

Engineering decisions within the existing scope: distinguish physical origins
from admissible artifact citations, preserve control-relative published record
locators, test both real live-owner retention functions through cleanup, use a
genuinely fail-closed native clone primitive, finish already-required journal
recovery and generation-aware validation, preserve exhaustion alongside guard
failure, and retain the terminal test's actual diagnostic. Add guards only for
the terminal test and an optional narrow clone helper. No static role prompt,
hook, configuration, retry, target-set or product-scope change is introduced.

The old `cp -c` clone-or-fail inference is withdrawn on executed counterevidence;
the Shaper's native-clone/no-fallback choice is preserved. A test-name registry
is not added because it does not prove behavior. Developer focused-test output
does not become a trusted receipt or extra handoff attestation.

Preserve all 38 saved files and the newer fixture normalization. Preserve the
original-or-optional-separate installing checkout choice, but state the old
controller's no-concurrent-edits constraint honestly. Concurrent Builds,
stopped-Build continuation and newer-main integration remain parked. This review
request is not approval; the same Intent is returned to Draft and no Build is
launched. No guarantee of a next-run pass or duration is recorded.

## Concurrent Builds: desired direction, 2026-09-22

Provenance: after being told that the existing Draft allowed one active Build, the Shaper proposed allowing multiple Builds at once because a single Build may not finish and overlapping the work would save time. The Shaper also raised both merge conflicts and tests failing after a conflict-free integration.

Preserve this outcome: an independent Build can make progress while another develops or fails; installing a combined result requires checking that combined result. A clean Git merge alone is insufficient acceptance evidence. The single-active-Build contract does not yet meet this goal.

Unresolved: automatic versus explicit integration after main advances; whether integration conflicts and new test failures pause or receive bounded Developer repair; interaction with existing retry/outer allowances and controller-generation admission. The Shaper has not approved automatic rebasing, resolving product conflicts, widening guards, or treating old Candidate receipts as evidence for changed bytes.

Controller recommendation for discussion: overlap development and focused feedback, serialize final integration/verification/Review/publication, and keep failing work available without holding up unrelated development. Existing source uses a whole-Build lock and an exact baseline publication check (`lib/kogen/build.ex`, `lib/kogen/git.ex`); current Candidate binding rejects post-verification mutation, which the proposed design must preserve (`lib/kogen/build/verification.ex`). Implementing concurrency therefore requires an explicit contract amendment, not a lock deletion.

Smallest recommended first version: parallel Builds may finish independently; the first publishable Candidate can advance main, and any Candidate whose baseline has then become stale is retained with an explicit integration-needed outcome. Integration is a separate explicit action followed by fresh verification and Review of the combined tree. This avoids silently granting automatic conflict-repair authority. Such a held Candidate must be distinguished from a failed, nonreusable Candidate, and the command/lifetime contract still needs shaping; the existing package does not already provide a resume/integration operation. Automatic queued integration remains an alternative for the Shaper to select, not approved backlog.

## All integration and repairs stay in worktrees, 2026-09-22

Provenance: the Shaper explicitly rejected merging into main and fixing problems there, and required investigation and repair to happen in a worktree. This boundary is settled. Updating a Candidate means bringing current main into its owned worktree. Main changes only to the final verified and independently reviewed commit. The control checkout is never an integration or repair scratch area.

Clarification: a clean Git merge establishes only that Git found no textual conflicts. If bringing main into the Candidate changes the tested source tree or admitted verification inputs, prior receipts cannot approve the new combination. If main has not advanced and the exact Candidate already has current passing verification and accepting Review, an additional merge and duplicate verification are not required merely to publish it.

The previous discussion used ambiguous phrases such as “publication slot” and “integration with main.” The concrete developer-experience proposal in `developer-experience.md` replaces that wording. It is a proposal, not implemented commands or accepted automatic-repair policy. Earlier explicit-integration and automatic-queue recommendations remain historical alternatives; the Shaper has not yet selected their automation semantics.

No new approval or implementation authority is recorded by this decision note.

## Isolation first; future continuation uses the existing command, 2026-09-22

Provenance: the Shaper explicitly said to keep the first Intent to basic isolation, identified resuming a Build as a separate Intent, rejected a separate command, and requested additional briefs under `.kogen/runtime/shaping-followups/intent-briefs`.

Accepted now: retain the single-active-Build isolation contract, including same-session rework within that running Build and safe exact-baseline publication. Do not add concurrent Builds, stopped-process recovery, changed-main integration, or conflict repair to this Build. The earlier concurrency recommendations above are historical alternatives, now parked rather than an unresolved expansion of this Intent.

Accepted for future shaping: `mix kogen.build <slug>` detects existing work and continues eligible work. The earlier `mix kogen.build.resume <build-id>` proposal is rejected. This command choice does not settle eligibility, exhausted budgets, missing native sessions, changed authority, or integration/repair automation. Those consequential questions remain in the separate briefs. All investigation and repair stays in a worktree; main is only updated to the accepted result.

Verification remains causal: future Intents do not inherit every workspace live target automatically. Deterministic recovery and scheduling need offline controls; real native-session continuation needs appropriate provider evidence. Exact target selection belongs to each later shaped contract, not this planning note.

Engineering reconciliation: `priv/kogen/prompts/developer.md` permits focused non-gate tests throughout development (lines 58–60 and 71–75); only the controller-issued readiness bundle is restricted to two points (lines 78–102). `developer-testing.md` makes the iterative test instruction explicit without changing the installed prompt or gate ownership. The earlier concern about conflicting wording is resolved by distinguishing those operations, not by claiming execution has already occurred.

Historical Draft-state note, before the current approval recorded in `approval.md`: the package remained Draft and unapproved. No source or test repair, Build, or new live run was performed for that scope reconciliation.

## Continue all 38 saved implementation files, 2026-09-22

Provenance: the Shaper rejected discarding the existing 38-file implementation,
clarified that the normal `mix kogen.build` Developer should finish it, and
explicitly directed “fix the intent then approve it”. The earlier blanket
no-reuse rule is superseded for checkpoint
`913ba174bffd864e0940c49d36d9e5d022333565` and its complete manifest.

Accepted: preserve and continue all saved implementation, restoring missing
changes or recognizing already restored files before repair. Do not recreate
the feature, discard useful work, or consume its backup. The original
`c1f08532` baseline and installing controller remain authoritative; all imported
source remains subject to the full contract, current verification and fresh
independent Review. The checkpoint is not an accepted feature commit.

This is a one-off source import in a new ordinary Build, not resumption of an
exhausted process or reuse of old receipts. Runtime identity, private caches,
credentials, old tracking and retry counters are not imported. Automatic
continuation, concurrency and newer-main integration stay parked. The installing
run may use the original clean-start checkout or an optional separately prepared
clean checkout; it must not depend on the unfinished isolation feature to judge
its own installation. `developer-recovery.md` supplies the concrete instructions.

Historical approval for that source-reuse revision was recorded in `approval.md`
and `intent.yaml`; it is now preserved as history after the Fable-high reopening.
That package amendment performed no source repair, stash operation or Build launch.

## Re-shape on top of controller-owned verification, 2026-09-25 (driver session)

Provenance: the Shaper approved the batch and delegated all technical
decisions (see `approval.md`). The driver's shaping subagent (Claude Opus 5.5,
high) re-shaped this identity against `main` `2909f557`, assuming Intents #1 to #4
of the batch have landed. Decisions (details in `questions.md` R1 to R7):

- The hook-based judge is dropped. The #4 controller judges and runs `make` in
  the Candidate. No hook, hook registration, Claude settings, prompt, Makefile,
  catalog or config change (D9; failed Build `cFnHwg7P2oNe1wMMnK7jxeMH`).
- Per-Build harness home at `<workspaces-root>/<project-id>/harness/<build-id>/`:
  - Claude: `CLAUDE_CONFIG_DIR` per Build, with the login referenced through
    `CLAUDE_SECURESTORAGE_CONFIG_DIR`. Never a private `HOME`; never a copied
    credential.
  - Codex: the operation root per Build, with `CODEX_HOME` kept as the scope.
- Credentials per Build means a per-Build binding, resolved from control once
  and held for the whole Build.
- Every Kogen Claude launch strips and sets `CLAUDE_SECURESTORAGE_CONFIG_DIR`.
  This closes the personal-login leak seen in probe case F.
- New scenario `shaping-during-build`, new scenario `per-build-harness-home`.
  `judge-from-control` is replaced by `controller-judges-candidate`.
- Paid: `live-shape-to-build` only.
- BLD-12's enforcement boundary is split out as a proposed ROADMAP row.
- Kept from 2026-09-24: location, naming, owner records, deps-only copy,
  publication and refusal, retention, and the list and remove commands.

## The write boundary folded back in, 2026-09-25 (driver session, late)

Provenance: the Shaper answered the BLD-12 question with "Keep it in #5" (about
21:45; `plan/BATCH-REPORT-2026-09-25.md`). ROADMAP row 7b is withdrawn, and the
"BLD-12's enforcement boundary is split out" line above no longer holds. The
driver's shaping subagent (Claude Opus 5.5, high) designed the boundary by probing
this host. Details are in `questions.md` R5 and R8 to R10 and in
`evidence/write-boundary-probe-2026-09-25.md`.

- Mechanism: one Build-wide macOS Seatbelt profile, applied per role launch with
  `/usr/bin/sandbox-exec -p`. It allows everything except writes, and allows
  writes only under the Candidate, the harness home, a spaceless per-Build temp
  dir, the stdio devices, the login keychain file, the Claude
  refresh lock, and the Codex scope minus its refused and Kogen-owned entries.
  `/bin/ps` runs outside the profile. `lsopen` and `appleevent-send` are denied.
- The controller and its verification children stay unconfined. Fixture Builds
  inside a role's shell run `inherited`, detected by the kernel self-test and
  never by the environment alone. Everything else fails closed, with no
  unwrapped fallback.
- The Claude and Codex bypass flags stay, because the kernel profile is the
  enforcement and Codex's own Seatbelt can't nest inside it.
- New scenarios: `role-write-boundary` (check + live-shape-to-build, with a
  fixture-only SessionStart probe in the real process trees),
  `write-boundary-fails-closed` (check), and `codex-roles-inside-boundary`
  (check + live-reviewer-rework, for the real hybrid Codex Reviewer).
- Paid: `live-shape-to-build` and `live-reviewer-rework`. The second is an
  existing target, justified by D8's provider-only rule.
  (Corrected 2026-09-26: the controller's `KOGEN_RAW_LOG_DIR` is not granted; roles log to
  `<harness home>/raw-log`, which the controller copies out at Build exit, questions.md R9 and R11.)

## Re-preflight at 9ff7af6e (2026-09-26)

fortify-paid-verification landed as 9ff7af6e; shaping-preflight-audit is parked and assumed
nowhere. #4's controller-owned verification now takes the Candidate and control roots explicitly,
role-facing control locators are absolute, live owners retain evidence in control through
`KOGEN_LIVE_LOG_DIR`, and GuardedPaths reads Git metadata through `git rev-parse --git-path`.
See questions.md R12 and approval.md "Driver re-preflight at 9ff7af6e".
