# Isolate Builds in Candidate workspaces

B1 of the agreed order: named routes (`5af11273`) → handoff hardening
(`5b44ceb4`) → **this Intent** → B2 parallel Builds. Reshaped on 2026-09-24
from the Shaper's brief `SHAPE_B1_ISOLATED_CANDIDATE.md` against `main` at
`5b44ceb4`. Approved by the Shaper on 2026-09-24 (see `approval.md`). The pre-reshape contract is under
`historical/` and is not Build input. The 41-file saved implementation in
`evidence/implementation-inputs/` is optional reference only; it predates the
pluggable harness, named routes and the controller-built handoff, and its
`lib/kogen/harness.ex` must not be applied.

## Problem

`mix kogen.build <slug>` runs the whole Build in the invoking checkout: the
Developer edits it, Stop verifies it, the Reviewer reads it and publication
commits in it. The Shaper cannot keep working in that checkout during a
Build, and B2 (several Builds at once) is impossible while every Build owns
the same working tree.

## Outcome

One Build at a time (the global `.kogen/build.lock` stays; B2 replaces it):

1. **Admission.** From the clean, attached control checkout at commit `A` on
   branch `B`, Build creates one linked worktree, the Candidate, in Kogen's
   own directory, outside the repository:
   `<workspaces-root>/<project-id>/<slug>-<build-id>/`, on a new branch
   `kogen/<slug>/<build-id>` at `A`. `<workspaces-root>` is
   `~/Library/Application Support/Kogen/build-workspaces`, overridable only by
   an explicit `KOGEN_WORKSPACES_ROOT`, which tests use to stay out of the
   real Kogen directory. `<project-id>` is the SHA-256 of the expanded control
   path, the id already used for per-project login scopes. `<build-id>` is the
   id of the Build's scenario-tracking record. An existing path or branch
   with that name is refused, never reused. Before the worktree is created,
   Kogen writes an owner record outside the worktree, at
   `<workspaces-root>/<project-id>/candidates/<build-id>.json`: build id, Intent
   id, slug and title, control root, worktree path, branch, admitted
   branch/commit, start time, status (`running`, `stopped: <category>`,
   `accepted-unpublished: <reason>`) and, when one exists, the Candidate
   commit. The controller updates the status at every exit. A
   `running` status counts only while this project's build lock is held by a
   live Build. Otherwise the commands report it as `stopped: interrupted`, for
   example after the controller process was killed. The Candidate gets a plain
   recursive copy of control `deps/` (none present: stop before any launch
   and name `mix deps.get`; no network fallback) and no `_build/`: it compiles
   cold (about 3 s here). The frozen Approved package bytes are written to
   the Candidate's ignored `.kogen/intents/approved/<slug>/` so roles read
   the package in their own cwd. Creation lives in one module function, so a
   later seeding step (brief 17) can be added in one place.
2. **Routing.** Every fresh Developer turn, exact-session resume, native
   helper, Stop verification, Jev packet, and fresh Reviewer run with
   process cwd and Git toplevel equal to the Candidate. Every Candidate-side
   operation receives the Candidate root explicitly: Candidate identity,
   changed paths, guarded-path capture, proof-selector existence, the
   controller-built report, citation snapshots, staging and commit. Every
   controller-owned item receives the control root explicitly: build lock,
   tracking record, verification context/state/history, Build
   runtime logs, prompts and engine assets, route/config, and harness login
   scope identity (`Harness.open/2` gets the control project explicitly; its
   `File.cwd!()` default is removed rather than silently substituted). No
   `File.cwd!()` or re-resolved toplevel stands in for either root.
3. **The judge stays in control.** The Stop and PreToolUse hooks run the
   control checkout's `.codex/hooks/*` scripts, while `make check` and the
   selected targets run with `make -C <Candidate>`. The controller passes
   both roots to hooks through the launch environment (the existing
   `KOGEN_PROJECT_ROOT` carries the control root today; a Candidate root is
   added), and the verification context's `project_root` is the Candidate.
   A missing or invalid root blocks fail-closed; hooks never fall back to
   `git rev-parse --show-toplevel`. Editing the Candidate's copy of the hooks
   cannot change what judges that Build (see Q3 for the Codex route).
4. **Rework stays in the same Candidate.** Stop verification retries, every
   outer resumption (settled verification failure, missing proof selector,
   Review finding) and the fresh Review each time reuse the same Candidate
   and the same Developer session; no attempt creates another worktree.
5. **Publication.** On acceptance the controller writes the Complete package
   into the Candidate and commits there with today's checks (per-path and
   aggregate staged-size limits, `.kogen/runtime/` rejection,
   assume-unchanged/skip-worktree refusal, trailers, ordinary commit hooks).
   Then, in control, it requires: still on `B`, `B` still at `A`, control
   clean by today's `clean_worktree?` rule, and no blinding index flags. It
   fast-forwards `B` to the Candidate commit, updating control's index and
   working tree in the same step (`git merge --ff-only`, or an equivalent
   compare-and-swap followed by a verified sync). It asserts control HEAD, tree
   and clean status, removes control's ignored Approved copy, and then removes the
   Candidate worktree, its branch (`git worktree remove` without
   `--force`, `git branch -d`) and its owner record. No merge commit, rebase or re-verification
   happens when `B` has not moved.
6. **Refused publication.** If `B` moved, the control checkout is dirty or
   on another branch, or the fast-forward fails, then `B`, control's index
   and working tree, and control's Approved package stay unchanged. The
   Candidate worktree and branch are kept, holding the accepted commit, and
   the Build exits non-zero with a message naming the reason, the admitted
   and current commits, the worktree path, the branch, the Candidate commit,
   the tracking record and `mix kogen.candidates.remove <build-id>
   --discard-accepted`. There is no Kogen publish-later command (the Shaper
   dropped it). The Shaper may fast-forward the branch themselves after
   tidying the checkout; remove then no longer needs the flag.
7. **Failure retention.** Any other stop (verification or outer allowance
   exhaustion, Jev cannot-comply stop, integrity failure, provider failure,
   malformed Review) keeps the Candidate worktree and branch as they are.
   The stop message names the slug, build id, worktree path and branch next
   to the record path, plus `mix kogen.candidates.remove <build-id>`. Nothing
   adopts, reuses or deletes a retained Candidate automatically. A later
   Build of the same Intent gets a new Candidate. Unrelated worktrees are
   never touched, including the pre-existing
   `.kogen/runtime/build-worktrees/checkouts/*` from the stranded `97109bf9`
   experiment. They are not Kogen-owned Candidates, so the commands below
   ignore them.
8. **Record.** The tracking record gains a `candidate` block with worktree
   absolute path, branch, admitted branch/commit, control root, and final
   disposition (`published`/`retained`, plus Candidate commit when one
   exists). All changed paths, proof selectors, report entries and ordinary
   citations are Candidate-relative. The tracking-record citation resolves to
   the control record by its advertised absolute locator, as today. The
   committed `build-summary.json` keeps its control-relative `full_record.path`.
9. **Candidate commands (current project only).** These act only on
   Candidates that have an owner record under the current control checkout's
   `<project-id>`:
   - `mix kogen.candidates` lists them: build id, slug, title, status, start
     time, branch and path. Git's own listing does not show which worktree
     belongs to which Intent.
   - `mix kogen.candidates.remove <build-id>` deletes one: its worktree
     (forced, since a stopped Candidate's uncommitted edits are expected),
     branch (`-D`) and owner record. It refuses a `running` Candidate, and a
     Candidate whose commit is not reachable from its admitted branch unless
     `--discard-accepted` is passed. Only a path under
     `<workspaces-root>/<project-id>/` that matches its owner record and is
     registered in this repository's `git worktree list` is deleted.
   - Each command prints what it removed or refused.
   - No prune or orphan cleanup in B1 (Shaper, 2026-09-24, after independent
     review). Those are parked in
     `.kogen/runtime/shaping-followups/SHAPE_CANDIDATE_PRUNE.md`.

## Outcome walkthrough and challenge

Shaper runs `mix kogen.build my-slug` on clean `main` at `A` → Candidate
`~/Library/Application Support/Kogen/build-workspaces/<project-id>/my-slug-Q7…/` on
`kogen/my-slug/Q7…` → Claude Code
Developer starts with cwd there. Meanwhile the Shaper edits a Draft in
control, which is an ignored path, so control stays clean. Stop fires and
runs control's `stop_runner.py`, which runs `make -C <Candidate> check`; it
fails and the retry continues in the same session. It passes, the report and
Jev read happen, and the Reviewer (cwd Candidate) finds a problem. The same
session is resumed in the same Candidate, verification passes again and a
fresh Reviewer accepts. The controller commits in the Candidate, checks
`main == A` and clean control, and fast-forwards `main`. Control now shows the
commit and a clean status. The Candidate and branch are gone and the
`git worktree list` output is back to its pre-Build state.

Plausible implementations that pass naive checks but miss the outcome:

- They create the worktree and `cd` the role there, but still compute
  Candidate identity, changed paths, guarded paths or proof selectors from
  control. Control is clean at `A`, so the report says "no changes", and a
  missing selector looks present because control has the file.
- They route roles correctly, but the Stop command still resolves
  `$(git rev-parse --show-toplevel)`. The Candidate's own editable
  `check.sh` then judges the Build, and a Developer edit to it that prints
  `{"continue":true}` passes verification.
- They copy `_build/`. `_build/<env>/lib/kogen/priv` is a relative link that
  lands in the Candidate, but other copied artifacts (the earlier Draft's
  runtime-worktree link) can point at control, so the Candidate runs control
  files. B1 copies `deps/` only.
- They commit in control from the Candidate tree, or update `main` with
  `update-ref` and leave control's index and working tree stale. Control then
  shows a reversed diff.
- They treat "no conflicts" as publishable after `main` moved.
- They `--force`-remove worktrees on success and delete a Candidate that
  holds unexpected untracked files.
- They key the Claude Code login scope on the Candidate path, so the project
  scope is empty. Or they launch resume in another cwd, so Claude Code cannot
  find the session.
- Offline tests keep `File.cd!(repo, fn -> Build.run(slug) end)` and assert
  HEAD in `repo`. That still passes if Build commits in the invoking checkout,
  so the tests must also assert that a Candidate existed, that role cwd and
  toplevel equaled it, that control was untouched until publication, and that
  it is gone afterwards.

The scenarios require disconfirming sentinels for each of these.

## Appetite and non-goals

One Build. Not in this Intent: concurrent Builds or per-Build locks and
state (B2); the pinned engine per Build (B2, see
`evidence/engine-stability-probe-2026-09-23.md`); continuing a stopped Build
or adopting a retained Candidate; rebasing, merging or re-verifying on a moved
`main` (brief 22); warm seeding of `deps/`/`_build/` or any cache (brief 17,
against a measured project); a command to publish a kept accepted
Candidate later (dropped by the Shaper); pruning kept Candidates and
cleaning orphans of deleted checkouts (parked in `SHAPE_CANDIDATE_PRUNE.md`); pruning Claude Code/Codex per-path
session state; kernel or Seatbelt containment. Linked worktrees are
structural ownership, not hostile-process containment: an absolute-path write
into control is prevented only by the Developer contract. Also out of scope:
new Make targets or catalog entries, and changes to retry/allowance
semantics, Jev, Review independence, or Stop's verification ownership.

**Engine limitation (honest, deferred to B2).** The controller and the
judging hooks are the control checkout's files. Kogen does not touch control
during the Build, but if the Shaper edits Kogen's own engine files there
(`lib/`, `priv/kogen/`, `.codex/hooks/`, config) mid-Build, the running Build
may read them. Publication still refuses a dirty or moved control. Editing
Drafts and other ignored paths is safe.

## Installing this Intent

The installing Build runs on `5b44ceb4` code, which still builds in the
invoking checkout and is judged by the current hooks. The feature is not a
prerequisite for its own installation. No saved-implementation import is
required.

## Developer notes

- Focused non-gate tests are allowed throughout development. Each scenario's
  `proof.offline` lists the tests to run and rerun while implementing. Stop
  alone owns `check` and the declared targets.
- Every test file created or edited needs its catalog rows in
  `priv/kogen/test-reliability.yaml` (and the 1:1
  `test-reliability-remediation.yaml`) updated with current `source_sha256`,
  consumer, wrong-control and affected-path fields, as in `5b44ceb4`, which
  edited the tracked catalog directly. Do not depend on the ignored
  `.kogen/runtime/shaping-followups/.../coverage-matrix.json`. It is not
  present in a Candidate and was not updated for recent Builds.
- The fake harnesses (`test/support/fake_codex*`, `fake_claude*`) invoke
  `sh .codex/hooks/check.sh` relative to their cwd. Route them through the
  same control-hook mechanism as the real settings, or they prove nothing
  about the judge.
- Claude Code stores sessions under
  `<scope>/projects/<encoded cwd>/`. Resume must use the same Candidate cwd,
  and `test/support/root_profile_audit.ex` must find sessions for Candidate
  cwds.
- Every test that runs a Build (the fake lifecycle, all `File.cd!` Build
  tests, and both live fixtures) must set `KOGEN_WORKSPACES_ROOT` to a
  disposable directory it owns and cleans. That directory's path must contain
  a space, including in `live-reviewer-rework` and `live-shape-to-build`, so a
  space problem in a real provider launch shows up there first, not in real
  Builds. No test may create worktrees in
  the real Kogen directory. A test must fail if a Candidate appears there.
- The real root contains a space (`Application Support`). Quote every path in
  hook commands, shell scripts, `make -C` and `sh -c` strings. At
  `5b44ceb4`, `make check` already fails from a path with a space: the fixture
  Makefile recipe in `test/kogen/lifecycle_test.exs:357-367` splices unquoted
  `-pa` code paths (see `evidence/b1-worktree-probe-2026-09-24.md`). Fix it,
  and run the workspace tests with a root that contains a space.
- Update `README.md`: the "Start Build …" and stopped-Build inspection
  paragraphs, the worktree location, the kept-Candidate message, and the
  `mix kogen.candidates*` commands.

## Evidence ownership

`check` owns deterministic topology, routing sentinels, judge location,
same-Candidate rework in the fake lifecycle, publication and refusal, failure
retention, record and owner-record contents, cleanup, and the Candidate
commands. `live-reviewer-rework` owns the real
Claude Code Developer, the exact-session resume and a fresh Reviewer running
in one Candidate, with the Stop hook firing from control against it.
`live-shape-to-build` owns real Shape→Build publication of a fixture `main`
through a Candidate, and Candidate removal. Their outer target owners retain
the provider streams. Review assesses the contract, the Candidate and the
receipts available to it.
