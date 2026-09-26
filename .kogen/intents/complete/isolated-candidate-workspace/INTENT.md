# Isolate each Build in its own Candidate worktree and harness home

ROADMAP order 5, ID 7 (features EXE-01, SEC-01 and BLD-12's launch-time write boundary for
Build roles).

**Shaper decision (2026-09-25, driver session, about 21:45): "Keep it in #5".** The launch-time
write boundary (BLD-12) stays in this Intent, and ROADMAP row 7b is withdrawn. Every Build role and
helper must be physically unable to write outside its Build's worktree, and macOS enforces it
(outcome 13).
Re-shaped on 2026-09-25 by the driver session, and re-preflighted on 2026-09-26
against main `9ff7af6e`, where these Intents have landed:

1. `bounded-reviewer-evidence` (22a2db95: bounded, Candidate-bound review packet;
   live Reviewer-rework fixture outside the checkout);
2. `cross-harness-adversarial-roles` (363c20af, without an auditor role: hybrid
   routes whose Reviewer and Expert run on the other harness; each role's
   assignment fixed for the Build; `default_route` stays `claude`, and the flip
   is ROADMAP 10a);
3. `fortify-paid-verification` (9ff7af6e: **the parent controller is the only
   verification authority**. After each Developer turn it computes the Candidate
   id and runs `make check` and the selected targets itself through
   `Kogen.Build.VerificationRunner` (`make -C <root>`, its own process group,
   outside every role's tree), writes Candidate-bound receipts and logs under the
   attempt's `verification/` directory next to the tracking record, reuses a
   passed provider-backed receipt only on the same Candidate id and catalog within
   one attempt, and resumes the same Developer session with a failure prompt that
   names the retained receipt and log. Stop scripts stay only for v1 contexts; the
   catalog and Makefile are unchanged.)

`shaping-preflight-audit` (#3) is **parked and not landed**
(`plan/staging/shaping-preflight-audit-PARKED.md`). This Intent assumes none of
it: no `mix kogen.audit`, no Shaping Stop hook, no auditor role or launch.

**Reshaped against main `98ebcfb2` (2026-09-26, continuation visit, on the Shaper's direction).**
98ebcfb2 only renames the Jev Keychain service; nothing below changes because of it. Scenario
`candidate-creation` now states the credential-binding order the Reviewer of Build 8Bs51yZP
enforced (see "Retry after Build 8Bs51yZP").

**Driver re-preflight at 9ff7af6e (2026-09-26).** Every Build of this batch runs
with `--route claude-dominant-adversarial-codex`, launched with every Kogen module
preloaded (build-failure lesson 17), so the Developer's cross-harness Expert
(`mix kogen.expert`, launched from the Candidate) must use the Build's binding
and harness home too (outcome 2). The Candidate never receives control's volatile
state such as `.kogen/build.lock` (outcome 1). Review packets and record-version
sidecar locators stay control-relative (outcome 11). #4's controller-owned
verification gets both roots explicitly, and role-facing control locators are
absolute (outcome 4). Anchors are re-read at 9ff7af6e.

The 2026-09-24 B1 contract, which was approved and then failed in Build
`cFnHwg7P2oNe1wMMnK7jxeMH`, is kept in `historical/2026-09-24-b1-reshape/`. Its
worktree, publication, retention and command design carries over. What changed:
the hook-based judge is gone (Intent #4 made it unnecessary, and editing the
hooks is what failed that Build under main's controller), and a per-Build
harness home and credential binding are added. See
`evidence/failed-attempts-lessons-2026-09-25.md` and
`evidence/harness-home-credential-probe-2026-09-25.md`.

## Problem

`mix kogen.build <slug>` runs the whole Build in the invoking checkout. The
Developer edits it, the controller verifies it, the Reviewer reads it and
publication commits in it. So:

- **Shaping stops during Builds.** The guard snapshots ignored files in that
  checkout. A Shaping session that saves a Draft or approves a package there
  fails the running Build (`l5Ur5WAv`, and three Builds of this Intent on
  2026-09-22). Today the driver must not write in the checkout during a Build.
- **Parallel Builds (order 8) are impossible**: one working tree, one index,
  one set of files per checkout.
- **Roles can write anywhere the user can.** The Developer runs with
  `--dangerously-skip-permissions` (Claude Code) or
  `--dangerously-bypass-approvals-and-sandbox` (Codex). Any role, helper or command it starts
  can write the control checkout, its Git refs, other Candidates, login scopes or the user's
  files. Only the prompt contract and after-the-fact checks stand in the way.
- **Every role shares one harness home.** Every Claude Code session of this
  repository (Shaping, Developer, Reviewer, every Build) writes into the one
  login scope directory. A Build can't be given a home of its own the obvious
  way: a private `HOME` hides the login keychain (probe case B), and a fresh
  `CLAUDE_CONFIG_DIR` has no login (case C). Separately, an inherited
  `CLAUDE_SECURESTORAGE_CONFIG_DIR=""` makes a Kogen launch authenticate with the
  user's **personal** Claude Code login (case F), and Kogen doesn't strip it.

## Outcome

Still one Build at a time: the global `.kogen/build.lock` stays in control.
Order 8 replaces it.

1. **Admission creates the Candidate.** From the clean, attached control
   checkout at commit `A` on branch `B`, Build creates one linked worktree in
   Kogen's own directory, outside the repository:
   `<workspaces-root>/<project-id>/<slug>-<build-id>/`, on a new branch
   `kogen/<slug>/<build-id>` at `A`.
   - `<workspaces-root>` is `~/Library/Application Support/Kogen/build-workspaces`,
     or `KOGEN_WORKSPACES_ROOT` if set. Tests always set it.
   - `<project-id>` is the SHA-256 of the expanded control path, the same id
     the login selectors use (`Kogen.ClaudeCode.project_id/1`).
   - `<build-id>` is the scenario-tracking record id.

   An existing path, branch or owner record with that name is refused, never
   reused. Before the worktree, Kogen writes an owner record at
   `<workspaces-root>/<project-id>/candidates/<build-id>.json` with these fields:
   schema version, build id, Intent id, slug, title, control root, worktree path,
   branch, admitted branch and commit, harness home, credential bindings, start
   time, status (`running`, `stopped: <category>`,
   `accepted-unpublished: <reason>`) and, when one exists, the Candidate commit.
   The status is updated at every exit. A `running` status counts only while
   this project's build lock is held by a live process. Otherwise it's reported
   as `stopped: interrupted`.

   The Candidate gets a plain recursive copy of control `deps/`. If `deps/` is
   missing, admission stops before any launch and names `mix deps.get`; there is
   no network fallback. It gets no `_build/` and compiles cold. The controller's
   frozen Approved package bytes go to the Candidate's ignored
   `.kogen/intents/approved/<slug>/`. Nothing else from control's ignored
   state is copied: no `.kogen/build.lock`, `.kogen/runtime/`, `.kogen/codex/`
   or `.codex/sessions/` (build-failure lesson 13). Creation is one function in one module
   (`Kogen.Build.Workspace.create/…`), so a later seeding step lands in one
   place.
2. **Harness home per Build.** Admission also creates
   `<workspaces-root>/<project-id>/harness/<build-id>/`, outside both the
   Candidate and control, and uses it for every role launch of the Build:
   - **Claude Code roles** get `CLAUDE_CONFIG_DIR=<harness home>/claude`. The
     login stays where it is: `CLAUDE_SECURESTORAGE_CONFIG_DIR` is set to the
     login scope path, and `HOME` stays the user's. Sessions, `.claude.json`
     and other Claude Code state for the Build land in the harness home. The
     Keychain item and its refresh lock are the scope's, shared by reference
     with Shaping sessions.
   - **Codex roles** get their operation root (private `HOME`, `XDG_*` and
     sqlite) inside `<harness home>/codex`. `CODEX_HOME` stays the scope,
     because Codex keeps `auth.json` and rollouts there and has no separate
     auth-home variable.
   - **Cross-harness Expert.** On a hybrid route the Developer reaches the
     Expert through `mix kogen.expert`, which it runs from the Candidate. The
     frozen Expert assignment (`Kogen.Harness.expert_environment/2`,
     `KOGEN_EXPERT`, `harness.ex:88-109`, which today carries only route, harness,
     model, effort and helpers) also carries the control root, the Candidate path,
     the Build's binding for the Expert's harness and the harness home, and the
     task uses them: cwd the Candidate (it refuses any other cwd), the bound scope,
     operation root or config dir under the harness home. The task runs the
     Candidate's own compiled Kogen code, the code under review, not the
     controller's; inside a Build it runs within the Build's boundary, so code
     that ignored the binding still could not write outside the grants.
   - The harness home survives publication as session evidence. It is removed
     only together with a retained Candidate by `mix kogen.candidates.remove`.
     Pruning is parked with Candidate prune.
3. **Credentials per Build: bound by reference, never copied.** At admission
   the controller resolves each role harness's login scope once, from the
   **control** root (never the Candidate path), and checks readiness with the
   Build's own launch environment (`claude auth status` with the per-Build
   config dir, and the Codex login check). It records each binding (harness,
   scope name, scope path, runtime version) in the owner record and in the
   tracking record. Every launch of that Build uses exactly these bindings,
   even if the Shaper changes the login selector during the Build.
   - Kogen never reads, copies, links, moves or renames a credential or a scope
     directory. It never sets a per-launch `HOME` for Claude Code.
   - Every Kogen Claude Code launch (Build roles, Shape, login and status)
     removes an inherited `CLAUDE_SECURESTORAGE_CONFIG_DIR` and sets its own.
     Claude launches also remove the Codex adapter's credential prefixes
     (`CODEX_`, `OPENAI_`, `AZURE_`, `CHATGPT_`), mirroring Codex's removal of
     `ANTHROPIC_`.
     Scope-native launches set it equal to `CLAUDE_CONFIG_DIR`, which selects
     the same Keychain item as today.
4. **Routing.** Every fresh Developer turn, exact-session resume, native
   helper, Jev packet, controller `make` run (`make -C <Candidate>`) and fresh
   Reviewer runs with the Candidate as its process cwd and Git toplevel. #4's
   proof-selector and base-suite runs keep running in its controller-owned
   scratch workspaces outside the repository (`Kogen.Build.BaseWorkspace`): the
   admission base workspace is exported from control at the admission commit, and
   a Candidate workspace from the Candidate's tree id (the object store is shared).
   - Candidate-side work gets the Candidate root explicitly: Candidate id,
     changed paths, guarded-path capture, proof-selector existence and runs, the
     controller-built report and review packet, citation snapshots, staging and
     commit.
   - Control-side items get the control root explicitly: build lock, tracking
     record, verification context, state, history and receipts, runtime logs,
     prompts and engine assets, route and config, and login-scope identity.
   - `Harness.open` and the adapters' `open` take the control project
     explicitly and a separate launch root (the Candidate). Their
     `File.cwd!()` defaults are removed, not substituted.
   - Codex trusts the Candidate as its project root. Its login scope still
     keys on control.
   - **Capturing control.** `mix kogen.build` is the only place that reads the process
     cwd, once, to find the control checkout (a main worktree, never a linked one). It
     passes that root to `Kogen.Build.run`, which today takes none
     (`build.ex:73-95`); an absent or non-checkout root fails before admission.
   - #4's controller-owned verification is split the same way (none of this exists at
     9ff7af6e). The environment `Build` hands `Kogen.Build.Verification.run_cycle/4`
     (today one `:root`, set from `File.cwd!()`, `build.ex:489-498`) and the
     persisted verification context (today only `project_root`,
     `verification.ex:47-58`) name both roots: the
     Candidate for `VerificationRunner.run_target/4`, `CatalogChange.check/4`
     (the Candidate's catalog, read as data), `TargetEvidence.capture/4` and every
     `TargetEvidence.verify/2` (`build.ex:1407`, `verification.ex:605`, both on the
     `"."` default today, so they read the Candidate root from the context); control for
     the attempt directory, so receipt, proof, base-suite and ledger `log_path`/`path`
     values stay relative to control and
     `Verification.settle/3`, `Ledger.verify/2` (`build.ex:1180`) and publication
     re-read them there. `Kogen.Git.candidate_id/0` and `candidate_changes/1`
     (implicit cwd today), and `Report.build/1`'s selector-existence predicate
     (`File.regular?/1` on the cwd, `report.ex:29-34`), run in the Candidate.
     `snapshot_references/2` (`build.ex:1334-1345`) resolves citations against the
     Candidate. `Verification.project_root/1`'s `File.cwd!()` fallback goes.
   - **Mix redirection.** `VerificationRunner` children and every role launch drop
     inherited `MIX_BUILD_PATH`, `MIX_DEPS_PATH` and `MIX_EXS` (the runner keeps them
     at 9ff7af6e, `verification_runner.ex:17,114-120`), so the Candidate's `make check`
     and role compiles use the Candidate's own `deps/` and `_build/`.
   - `GuardedPaths` snapshots `.git/config` and `.git/info/exclude` by joining
     them to the root (`guarded_paths.ex:9,115-131`). In a linked worktree `.git`
     is a file, so these resolve through `git rev-parse --git-path` instead, and a
     mid-Build change to control's `.git/config` is still caught.
   - `VerificationPolicy.environment/2`'s `KOGEN_PROJECT_ROOT` names the
     Candidate, whose `.codex/hooks/verification_policy.py` the PreToolUse guard
     runs.
   - **Role-facing locators are absolute.** A role runs in the Candidate, so every
     control-side path Kogen hands it opens from there: the task context's
     `tracking_path` (`build.ex:1261-1279`), the review-packet path in the
     Reviewer's task context and notes section (`build.ex:1287-1330`), and the
     retained receipt and log in the verification-failure prompt
     (`build.ex:520-561`). The task context gains an absolute `control_root`, against
     which the control-relative locators in the record and inside the review packet
     (packet `path`, receipt `log_path`, ledger diffs, sidecars) resolve; those stay
     control-relative (outcome 11).
   - No `File.cwd!()` or re-resolved toplevel stands in for either root.
5. **The controller judges the Candidate; hooks don't.** Intent #4's
   controller runs `make check` and the selected targets with cwd equal to the
   Candidate (`make -C <Candidate>`), as child processes outside every role's
   process tree. Its receipts bind to the Candidate id. Unless the caller set
   one, the controller gives those children `KOGEN_LIVE_LOG_DIR=<control>/.kogen/runtime/live-evidence`.
   The live owners already honor it (`live_shape_to_build_test.exs:587-600`,
   `live_reviewer_rework_fixture.ex:173-178` at 9ff7af6e), and without it they would retain
   evidence inside the Candidate, which `git worktree remove` deletes with the
   Candidate's other ignored files at publication. Editing the
   Candidate's copies of `.codex/hooks/**`, `Makefile` recipes or
   `scripts/check/**` can't change who judges, which is always the parent
   controller loaded from control when the Build started.
   - This Intent changes no hook script, hook registration or Claude settings
     file (self-hosting, D9).
   - Build calls `VerificationPolicy.preflight(targets, candidate_root)` with
     the Candidate root explicitly, because the Candidate's hook files are the
     ones the PreToolUse gate guard actually runs. The default root argument is
     not used on any Build path.
   - A Candidate edit to a hook file is outside this and most Intents' guards,
     so the guarded-path check stops such a Build before verification, as
     today. The offline proof uses a fixture Intent that guards
     `.codex/hooks/**` to show the edited copies still change no verdict. The PreToolUse gate
     guard stays a courtesy guard against running gates by hand, not a judge;
     README says so.
6. **Rework stays in the same Candidate.** Verification retries, every outer
   resumption and each fresh Review reuse the same Candidate, the same harness
   home and the same Developer session. No attempt creates another worktree or
   home.
7. **Publication.** On acceptance the controller writes the Complete package
   into the Candidate and commits there, with today's checks: per-path and
   aggregate staged-size limits, `.kogen/runtime/` rejection,
   assume-unchanged/skip-worktree refusal, trailers and ordinary commit hooks.
   1. In control it then requires: still on `B`, `B` still at `A`, control
      clean by today's `clean_worktree?` rule, and no blinding index flags.
   2. It fast-forwards `B` to the Candidate commit and updates control's index
      and working tree in the same step (`git merge --ff-only` in control).
   3. It asserts control's HEAD, tree and clean status.
   4. It removes control's ignored Approved copy of this slug, then removes the
      Candidate worktree (`git worktree remove`, no `--force`), its branch
      (`git branch -d`) and its owner record.

   No merge commit, rebase or re-verification happens. If step 4's worktree
   removal is refused after the fast-forward (for example an untracked file in
   the Candidate), `B` stays published. The worktree, branch and owner record
   are kept with status `published: cleanup refused: <reason>`, the record's
   disposition is `published-retained`, and the Build exits zero with a warning
   naming the path and `mix kogen.candidates.remove <build-id>`.
8. **Refused publication.** The Build refuses to publish if `B` moved, if
   control is dirty or on another branch, or if the fast-forward fails. Then:
   - `B`, control's index and working tree, and control's Approved package stay
     unchanged.
   - The Candidate worktree, branch (holding the accepted commit) and harness
     home are kept.
   - The Build exits non-zero. The message names the reason, the admitted and
     current commits, the worktree path, the branch, the Candidate commit, the
     tracking record and `mix kogen.candidates.remove <build-id>
     --discard-accepted`.
9. **Failure retention.** On any other stop (verification or outer allowance
   exhausted, Jev cannot-comply, integrity failure, provider failure, malformed
   Review):
   - The Candidate worktree, branch and harness home are kept as they are.
   - The stop message names the slug, build id, worktree path and branch next
     to the record path, plus `mix kogen.candidates.remove <build-id>`.
   - Nothing adopts, reuses or deletes a retained Candidate. The next Build of
     the same Intent gets a new one.
   - Worktrees without a Kogen owner record are never touched. That includes
     the old `.kogen/runtime/build-worktrees/checkouts/*`.
10. **Shaping keeps working during a Build.** While a Build runs, a Shaping
    session in control may write Drafts, edit other packages under
    `.kogen/intents/`, and move another package into `approved/`. It may also
    use the same Kogen login at the same time. None of this fails the Build,
    because guarded-path capture, changed paths and Candidate id read only the
    Candidate. The Build still publishes, since ignored files don't make
    control dirty. The Build's own Approved package stays protected in the
    Candidate by today's approved-mutation check. A tracked-file edit in
    control still makes publication refuse (outcome 8) and keeps the Candidate.
11. **Record.** The tracking record gains a `candidate` block with the worktree
    path, branch, admitted branch and commit, control root, harness home,
    credential bindings and final disposition (`published`, `published-retained`
    or `retained`, plus
    the Candidate commit when one exists). Changed paths, proof selectors,
    report entries and citations are Candidate-relative. The tracking-record
    citation (metadata only, per #1) and `build-summary.json`'s
    `full_record.path` resolve from control. Review packets and record-version
    sidecars stay under control's `.kogen/runtime/scenario-tracking/<build-id>/`
    with control-relative locators, which the live fixtures' retention and
    `Kogen.ReviewPacketAudit` read (scenario
    `shape-to-build-retains-record-sidecars`).
12. **Candidate commands, current project only.** They act only on Candidates
    that have an owner record under the current control checkout's
    `<project-id>`:
    - `mix kogen.candidates` lists them with build id, slug, title, status,
      start time, branch and path.
    - `mix kogen.candidates.remove <build-id> [--discard-accepted]` deletes the
      worktree (forced, since a stopped Candidate's uncommitted edits are
      expected), the branch (`-D`), the harness home and the owner record.
    - Remove refuses a `running` Candidate. For a Candidate holding a commit:
      if the commit is reachable from its admitted branch (the Shaper
      fast-forwarded it, or `published: cleanup refused`), it is removed without
      a flag; if not, it is refused unless `--discard-accepted` is given. It deletes only paths under
      `<workspaces-root>/<project-id>/` that match the owner record and are
      registered in this repository's `git worktree list`.
    - Both commands print what they removed or refused. There is no prune or
      orphan cleanup (parked, `SHAPE_CANDIDATE_PRUNE.md`).

13. **Role write boundary (BLD-12), enforced by macOS.** Every role process tree of a Build
    runs inside one macOS Seatbelt profile, applied by the kernel at launch
    (`/usr/bin/sandbox-exec -p <profile>`). That covers the fresh Developer, every resume, the
    Reviewer, their native helpers, hooks (including Stop and any `make` it or the Developer
    starts), `mix kogen.expert` and the Expert it launches, and anything any of them spawns.
    Descendants inherit the profile and can't remove it. The mechanism was chosen by probing
    (`evidence/write-boundary-probe-2026-09-25.md`). Neither harness's own permission layer
    confines the harness process's own writes (the Write tool, apply_patch, session files),
    and Codex's Seatbelt can't nest inside another profile.
    - **One Build-wide profile.** `Kogen.Build.WriteBoundary` renders it once at admission
      from canonical, symlink-resolved paths. It is `(allow default)`, then
      `(deny file-write*)`, then writes allowed only under:
      - the Candidate;
      - the Build's harness home;
      - a spaceless per-Build temp dir under the controller's canonical system temp dir,
        `kogen-build-<build-id>/`. It is created at admission and removed at every Build exit,
        and every launch gets it as `TMPDIR`, `TMPPREFIX` (zsh here-documents) and
        `CLAUDE_CODE_TMPDIR` (Claude Code's Bash tool);
      - the stdio and pty devices.

      Beyond those, the only exceptions to "worktree only" are shared login state, which
      logins need to keep working. The profile names each one:
      - the login keychain file and its `.sb-` temp files, because Claude Code persists
        rotated OAuth tokens through `/usr/bin/security` in-process (probe 12);
      - `<Claude scope>/.oauth_refresh.lock` when the route uses Claude Code;
      - the Codex scope when the route uses Codex (`CODEX_HOME` holds `auth.json`, rollouts
        and bookkeeping; probes 10, 19), minus the entries Kogen's scope validation refuses or
        owns: `hooks.json`, `plugins/`, `rules/`, `config.d/`, `AGENTS.md`,
        `AGENTS.override.md`, `environments.toml`, `agents/` and `.kogen-owned`.

      There is no other grant. In particular, the controller's `KOGEN_RAW_LOG_DIR` is not
      granted. Role launches instead get `KOGEN_RAW_LOG_DIR=<harness home>/raw-log`, so
      `mix kogen.expert`'s raw streams and the live probes' receipts land in the harness home.
      At every Build exit the unconfined controller copies that directory into its own
      `KOGEN_RAW_LOG_DIR`, when one is set.

      `/bin/ps` is the one executable run outside the profile, because sandboxed processes
      can't exec setuid binaries and Kogen's own code reads the process table with it.
      LaunchServices opens (`lsopen`) and Apple Events (`appleevent-send`) are denied, because
      they hand work to processes outside the profile. The same profile applies to every role
      of the Build, so an Expert on the other harness runs inside the Developer's profile.
    - **Everything else is refused, and named.** Writes to the control checkout (including
      `.kogen/`, the build lock and the tracking record), control's Git metadata (the
      Candidate's index, objects, refs and config live there, so role `git add`, `commit`,
      `stash`, `checkout -b`, `update-ref` and `config` fail), other Candidates, other harness
      homes, owner records, the Claude scope directory, the user's home and every other path
      fail with `EPERM` ("Operation not permitted"). That includes writes through symlinks,
      hardlinks, renames and `/tmp` aliases. Reads, network and process execution stay open.
      Role `git status` and `git diff` still work. The claim is about file writes by the
      tested routes (probes 1, 4, 5, 13, 17, 19, 20): direct writes, children, daemons,
      aliases, symlinks, hardlink creation, renames, launchd, LaunchServices and Apple
      Events. A hardlink that already exists inside a granted tree would let a role write the
      linked file. Admission creates the Candidate with `git worktree add`, the `deps/` copy
      and a fresh harness home and temp dir, none of which make hardlinks, and the `deps/`
      copy must not use `cp -l`. Other macOS services a role could ask to write on its behalf
      are not claimed to be closed (risk `service-delegation`).
    - **The launcher.** `Kogen.Harness` Build role launches (adapters' `run_with_stdin`, the
      Codex review and exec paths, Build readiness such as `claude auth status` and
      `codex login status`) take the boundary from the launch context and prefix the command.
      Readiness runs inside the boundary too, so a grant a real harness needs fails before any
      model call. Shape, login, status outside a Build, and Shaping sessions are not wrapped.
      Their containment is the Shaping half of BLD-12, owned by
      `headless-shaping-and-question-inbox`. Every wrapped launch sets `KOGEN_WRITE_BOUNDARY` to
      the profile sha256. Kogen's own state root (`~/Library/Application Support/Kogen/…`:
      runtimes, selectors, Codex `operations/` and `active/` leases) is outside the grants. So
      `mix kogen.expert` run from the Developer's tree in a Build takes no Codex lease and makes
      no operation dir there. It uses the frozen binding from `KOGEN_EXPERT`, puts its
      operation root under the harness home, and relies on the lease the Build controller
      already holds for that harness from admission to exit (`Harness.open_roles/3`).
    - **Fails closed.** Every grant is resolved to its canonical path first, because the
      kernel matches only real paths and `/tmp/…` or `/var/folders/…` aliases would silently
      never match (probe 14). If `/usr/bin/sandbox-exec` is missing, a grant can't be resolved
      to an existing directory, a grant is `/`, `/private/tmp`, `/private/var`, `$HOME`, the control
      root or one of its ancestors, or the admission self-test (the profile applied to
      `/usr/bin/true`) fails, admission stops before any readiness call or launch, naming the
      reason. There is no unwrapped fallback.
    - **Already confined.** The kernel refuses to apply a different profile inside a sandbox
      (`sandbox_apply: Operation not permitted`, probe 2). Confinement is detected by the kernel,
      never by the environment: applying `(version 1)(allow default)` to `/usr/bin/true` exits 71
      only inside a sandbox. If it is not confined, `KOGEN_WRITE_BOUNDARY` is ignored and the
      profile is applied. If it is confined:
      - `mix kogen.expert` run from a role of the admitted Build launches without re-applying,
        inside that Build's own profile. Its record entry says `inherited`.
      - A `mix kogen.build` whose roles use a managed harness runtime stops before admission:
        "a Build cannot start inside another Build's role boundary". A real Build always gets
        its own profile from an unconfined controller, so it can never run with someone
        else's grants.
      - A `mix kogen.build` whose roles are `KOGEN_HARNESS` test executables, meaning an offline
        fixture Build a Developer runs in its shell, runs `inherited` if the marker is set. It
        still can't write outside the enclosing Build's grants, but it makes no claim about
        its own worktree. Its record says so. This is a restriction on the nested Build, not
        an exemption from the boundary.
      - Confined without the marker (a foreign sandbox): the Build stops, naming it.
    - **The controller stays outside.** The parent controller and its own verification children
      (#4: `make check` and the selected targets, `make -C <Candidate>`, plus proof-selector and
      base-suite runs, all started by `Kogen.Build.VerificationRunner` as the controller's own
      supervised children) run unconfined, with `KOGEN_WRITE_BOUNDARY` removed from their
      environment (added to `VerificationRunner`'s scrub list, `verification_runner.ex:17` at
      9ff7af6e). The controller must write the
      record, lock and receipts, and fixture Builds inside `check` and live targets must apply
      their own boundary, which the kernel would refuse inside another profile.
    - **Kept flags.** Claude Code keeps `--dangerously-skip-permissions`. Codex keeps
      `--dangerously-bypass-approvals-and-sandbox` and `--dangerously-bypass-hook-trust`. The
      enforcement is the enclosing kernel profile, which already covers everything those
      harness layers would, including the harness's own writes, and Codex's own Seatbelt would
      fail to nest inside it (probe 10). README says so.
    - **Record.** The tracking record gains a `boundary` block: mode (`applied` or `inherited`),
      the profile sha256, the grant list, the denied scope entries and the `sandbox-exec` path.

## Installing this Intent (self-hosting, D9)

The installing Build runs under main's controller at `9ff7af6e` (#1, #2 and #4; #3 is parked), in
the one checkout, not isolated, on `--route claude-dominant-adversarial-codex` (Claude Code
Developer, Codex Reviewer and Expert), launched with every Kogen module preloaded
(`mix run --no-start -e '… Code.ensure_loaded … Mix.Task.run("kogen.build", args)'`,
build-failure lesson 17). It reads several files **from disk at run
time**, so the Candidate must leave them byte-identical:

- `.codex/hooks.json` and `.codex/hooks/**`. `VerificationPolicy.preflight`
  byte-compares the PreToolUse command before every Developer launch
  (`lib/kogen/verification_policy.ex:20,34-49,66-92` at `9ff7af6e`: #4's preflight requires only
  `.codex/hooks/verification_policy.py` and the PreToolUse registration), and the Stop bootstrap
  stays for v1 contexts until ROADMAP order 10.
- `priv/kogen/claude_code/settings.json`, passed by path to every Claude launch
  (`lib/kogen/harness/claude.ex:26,165-166` at `9ff7af6e`).
- `priv/kogen/prompts/*.md`, read at each role launch.
- `Makefile` and `priv/kogen/verification_targets.yaml` (#4 keeps them frozen).
- `.kogen/config.yaml`.

None of these are in `may_change_guarded_paths`. The installing Build itself
never runs in a Candidate: then-main has no workspace admission, and Candidate
code can't change the controller that runs it. The first real Candidate is
created by the `live-shape-to-build` fixture Build inside this Build (running
the Candidate's code), and then by the first ordinary Build after this lands. Everything this Intent adds
is used only by the Candidate's own code: the Build's tests and the
`live-shape-to-build` fixture Build. It is an expand step with nothing to
contract later.

- The inert Stop bootstrap and the `$(git rev-parse --show-toplevel)`
  PreToolUse command stay. Removing them is ROADMAP order 10.
- The engine limitation stays. The controller of a later Build runs from
  control's compiled code and reads control's `priv/`, so the Shaper editing
  Kogen's own engine files in control during a Build can affect it. Pinned
  generations are ROADMAP order 6.
- Editing Drafts and other ignored files is safe.
- **Lesson 17 (late-called controller modules).** This Intent edits modules main's controller
  calls late: `Report`, `Tracking`, `ReviewPacket`, `Verification`, `Evidence`, `Git` and the
  publication path in `build.ex`. The preloaded launch keeps the controller on its admission code,
  and the Developer compiles only in `_build/test` or fixture build paths (Developer notes), so
  neither mechanism alone is relied on. Nothing in this Intent needs the running controller to
  load Candidate code, and nothing needs the application started (`mix run --no-start`): new code
  reads no `priv/` file and no application env at runtime. After this Intent, each Candidate has
  its own `_build/`, so a Developer compile can no longer reach the controller's code; only a
  compile in control can (order 6).
- The installing Build's own roles run without a write boundary, because then-main has none.
  The boundary first confines the nested fixture Builds of `live-shape-to-build` and
  `live-reviewer-rework` (Candidate code, launched by the controller's unconfined `make`), and
  then the first ordinary Build after this lands. No `.claude/settings.json` is added to this
  repository: `--setting-sources project` would load it into the installing Build's own roles.
  The SessionStart probe lives only in the live fixture's copy.

While this installing Build runs, **no session may write in the checkout**,
because the running controller still guards the one checkout.

## Outcome walkthrough and challenge

1. The Shaper runs `mix kogen.build my-slug` on clean `main` at `A`.
2. The Candidate is created at
   `…/build-workspaces/<pid>/my-slug-Q7…/` on `kogen/my-slug/Q7…`, with the
   harness home `…/<pid>/harness/Q7…/`.
3. Readiness runs `claude auth status` with `CLAUDE_CONFIG_DIR=<home>/claude`
   and `CLAUDE_SECURESTORAGE_CONFIG_DIR=<shared scope>`, and gets
   `loggedIn: true`. On a hybrid route, the Codex Reviewer's login is checked
   the same way.
4. The Developer starts in the Candidate. Meanwhile the Shaper saves a Draft
   and approves another package in control. Both are ignored paths, so control
   stays clean and the Build's guard never sees them.
5. The turn ends. The controller runs `make -C <Candidate> check`, which fails,
   and resumes the same session in the same Candidate and config dir. It then
   passes, and the controller builds the report and packet from the Candidate.
6. The Reviewer (Claude Code on `default_route: claude`, or Codex on a hybrid
   route), with cwd the Candidate, asks for rework. The same
   Developer session resumes, verification passes, and a fresh Reviewer
   accepts.
7. Throughout, every role process and everything it spawns runs inside the
   Build's Seatbelt profile. A Developer command `echo x > <control>/README.md`,
   a helper's `git -C <control> update-ref …` or a Write-tool edit of
   `~/.zshrc` fails with "Operation not permitted", while its edits in the
   Candidate, its session files in the harness home and its here-documents
   in the Build temp dir work. The record says `boundary: applied`.
8. The controller commits in the Candidate, checks `main == A` and a clean
   control, and fast-forwards `main`. Control shows the commit and a clean
   status, the worktree and branch are gone, and the harness home keeps the
   transcripts.

Plausible implementations that pass naive checks but miss the outcome:

- The worktree exists and roles `cd` there, but Candidate id, changed paths,
  guards or selectors are still computed from control. Control is clean at
  `A`, so the report says "no changes", and a missing selector looks present.
- `make` targets still run in control (or in `File.cwd!()`), so a failing
  Candidate passes against control's clean tree.
- A per-Build `HOME` for Claude Code. Every role then reports "not logged in"
  (probe B). Or a fresh `CLAUDE_CONFIG_DIR` without the secure-storage
  reference (probe C). Or a copied `.credentials.json` or Keychain export: a
  forbidden copy that forks the refresh token.
- The login scope is keyed on the Candidate path, so a project-scope login is
  never found. Or the scope is re-resolved per launch, so a mid-Build selector
  change switches logins inside one Build.
- Inherited `CLAUDE_SECURESTORAGE_CONFIG_DIR` is left alone, so an empty value
  silently uses the personal login (probe F).
- Hook commands and settings are rewritten to "run from control". That
  reintroduces the `cFnHwg7P` preflight failure under main's controller and
  isn't needed, because the controller already judges.
- Guard capture still includes control's ignored files, so a mid-Build Draft
  fails the Build.
- `_build/` is copied, carrying links into control.
- Publication uses `update-ref` and leaves control's index stale, or treats
  "no conflicts" as publishable after `main` moved.
- Removal is `--force` on success.
- The harness home is deleted on publication before the live audit reads the
  transcripts, or it is deleted with a foreign worktree.
- Offline tests keep `File.cd!(repo, fn -> Build.run(slug) end)` and assert on
  `repo`'s HEAD, which passes even if Build still works in the invoking
  checkout.
- The boundary wraps only the fresh Developer, or is set as harness
  permission flags (Claude Code `permissions.deny`, Codex `--sandbox
  workspace-write`) that leave the harness process's own writes and Kogen's
  bypass flags in place.
- Grants use `/tmp/...` or `/var/folders/...` aliases, so the kernel never
  matches them and every role fails, or the fix is a broad `/private/tmp`,
  `$HOME` or control grant.
- `sandbox-exec` failing (missing, or `sandbox_apply` refused) falls back to
  an unwrapped launch, or an inherited `KOGEN_WRITE_BOUNDARY` alone turns the
  boundary off.
- The controller's `make check` runs inside a role boundary, so every
  fixture Build in the suite fails with `sandbox_apply: Operation not
  permitted`, or fixtures pass by special-casing `KOGEN_HARNESS`.
- The Codex scope is left unwritable (the real Reviewer can't write its
  rollout or refresh its login) or fully writable (a role plants
  `hooks.json` or `plugins/`, lesson 3).

Each scenario names the sentinel or control that rejects these.

## Appetite and non-goals

One Build. Not in this Intent:

- concurrent Builds, per-Build locks, two logins at once (order 8);
- pinned engine generations (order 6);
- process-group custody (order 7);
- continuing or adopting a stopped Candidate;
- rebase or re-verify on a moved `main`;
- warm seeding;
- a publish-later command, prune and orphan cleanup;
- pruning per-path harness state.

The write boundary (outcome 13) confines **writes** of Build role process trees.
The following are outside it:
- Shaping sessions. Their containment is BLD-12's Shaping half, in the
  `headless-shaping-and-question-inbox` row.
- Reads and network, which stay open.
- The controller and its verification children (`make check` and targets). The
  controller has to write, and fixture Builds inside them must apply their own
  profile.
- Kernel protection of the Build's own Approved copy inside the Candidate. It
  stays protected by today's approved-mutation stop (detect and stop), because
  the Shaper's rule names the worktree as the boundary.
- A Linux mechanism (DST-03).

Also out: changes to hooks, Claude settings, prompts, `Makefile`, the catalog or
`.kogen/config.yaml`; Jev, Review independence, retry allowances; any new paid
target (the existing `live-reviewer-rework` is selected, see Evidence ownership).

## Developer notes

- New test files the Developer creates (proof selectors):
  `test/kogen/build_workspace_test.exs`, `test/kogen/harness_home_test.exs`,
  `test/kogen/candidate_verification_test.exs` and
  `test/kogen/candidates_command_test.exs`, plus `test/kogen/write_boundary_test.exs` and
  the fake role `test/support/fake_boundary_role`. Every other selector exists at
  `9ff7af6e`. Until integrity is switched on for Kogen's catalog (ROADMAP order
  10), the controller only checks that these selectors exist, and `make check`
  runs them with the whole suite. So each one must hold one named test per
  `then` clause of its scenario, including every negative control the scenario
  names. The handoff must map each clause to its test name, and Review checks
  that mapping.
- Compile only in the test environment or in a fixture's own `MIX_BUILD_PATH`.
  A `mix compile` in dev rewrites `_build/dev`, from which the running
  controller can still lazily load modules (risk
  `self-hosting-running-controller`).
- Focused non-gate tests are allowed throughout. Each scenario's
  `proof.offline` lists the tests to run while implementing. The controller
  owns `check` and the targets.
- Every edited cataloged test needs its `priv/kogen/test-reliability.yaml`
  `source_sha256` refreshed with
  `python3 scripts/check/refresh_test_reliability_sources.py` (see
  `scripts/check/README.md`). New test files follow the catalog rules that
  `test_reliability_catalog_test.exs` enforces, with 1:1 rows in
  `test-reliability-remediation.yaml`.
- `test/test_helper.exs` sets `KOGEN_WORKSPACES_ROOT` to a disposable
  per-run directory whose path contains a space, unless a test sets its own.
  The fixture Builds (`System.cmd` env deltas) inherit it. No test may create
  anything under the real Kogen directory; the workspace tests assert a
  real-root sentinel stays empty.
- The fake harnesses (`test/support/fake_claude*`, `fake_codex*`) must write,
  from inside the launched process, `pwd -P`, `git rev-parse --show-toplevel`,
  `CLAUDE_CONFIG_DIR`, `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `CODEX_HOME` and
  `HOME` to a per-launch receipt **under the harness home** (inside the boundary).
  Tests assert the OS process state, not launch arguments.
- **Write boundary in the suite.** Every fake-harness Build in `check` now runs
  its fake roles inside a real Seatbelt profile. Any existing fixture whose fake
  role, fake hook or helper script writes outside the Candidate, the harness home
  or the Build temp dir will now get EPERM. Two known cases at `9ff7af6e`:
  - `two_outer_resumptions_test.exs`, the `midbuild-config-mutation.sh` hook,
    which writes a `stage` file under the test's `System.tmp_dir!()`;
  - the control-side writes of scenario `shaping-during-build`.

  Related, not a boundary failure: `fake_claude` keeps its state in `.kogen/runtime`
  relative to its cwd, and #4's `test/support/verification_cycle_fixture.ex` Makefile
  appends to `target-calls.log` in the `make` root. Both now land in the Candidate, so
  tests that read them from the invoking repository must read the Candidate's copy (from
  the tracking record's `candidate` block) instead.

  Fix each one by moving the outside write to the trusted test process, which
  coordinates with the fake role through a marker inside the Candidate or harness
  home, or by keeping fake-role scratch state in the harness home or Build temp
  dir. **Inventory first:** before changing Build code, list every fake role and fake hook
  (`test/support/fake_*`, and every fake-harness body written inline by a test, e.g.
  `core_integrity_test.exs` `fake_harness_body/3`) with each path it writes. Classify each
  path as inside the grants or not, and put the list in the handoff notes. Review checks it.
  Never widen the grants, never special-case `KOGEN_HARNESS` or fake
  executables, and never exempt a test from the boundary (2026-09-19 lesson,
  `evidence/write-boundary-probe-2026-09-25.md`). A fixture that expects a role
  to write outside must now expect the refusal.
- The Developer's own shell is inside the boundary. Focused `mix test` runs work
  there. In probe 9 the full `make check` gave the **same** result inside and outside
  the profile: 800/805, the same five pre-existing environment failures, not a pass.
  Fixture Builds started from that shell run in `inherited` mode. Tests
  that must observe `applied` (write_boundary_test, candidate_verification_test)
  pass under the controller's unconfined `make check`. Inside a role shell they
  may be skipped only by the kernel confinement self-test (tag `:unconfined`,
  excluded in `test/test_helper.exs` when the self-test reports confinement),
  never by an environment variable.
- The Candidate's Git metadata is control's `.git/worktrees/<name>/`, so role
  `git add`, `commit`, `stash` and `checkout` fail inside the boundary. The
  controller stages and commits. No Kogen test may need role-side Git writes to
  its own Candidate (probe 9 found none).
- The Codex SessionStart probe (`test/support/live_reviewer_rework_fixture.ex`): in the
  fixture's own copy only, add a `SessionStart` entry to `.codex/hooks.json`, keeping
  Kogen's PreToolUse Bash registration byte-identical (preflight checks only that entry,
  `verification_policy.ex:66-92` at 9ff7af6e). Add the same probe script, with the same env gating,
  `boundary-escape/` dir and receipt format as the Claude probe below. Probe 20 showed
  that real Codex 0.156.1 runs it on a fresh `exec` and on `exec resume`, and that the
  kernel refuses its outside write. The fixture asserts one receipt per Codex Reviewer
  session with the inside write succeeding and the outside write and `update-ref`
  refused. The Expert path is proved offline through the production managed-open path
  with a fake runtime (scenario `codex-roles-inside-boundary`).
- The live fixture's SessionStart probe (`live_shape_to_build_test.exs`): in
  `setup_fixture`, write `.claude/settings.json` and a small hook script into the
  fixture before its baseline commit, and create the fixture control's ignored
  `.kogen/runtime/boundary-escape/` directory, so a refused write can only fail with
  EPERM, never ENOENT. The hook prints nothing to stdout, because SessionStart output
  would enter the model's context. It does nothing unless
  `KOGEN_BOUNDARY_PROBE_OUTSIDE` is set, which only the nested `mix kogen.build`
  environment sets, so the unconfined Shape session skips it. It appends one JSON
  line per session to `$KOGEN_RAW_LOG_DIR/boundary-probe.jsonl`. Inside a role this is
  `<harness home>/raw-log/`, and the controller copies it into the test's raw-stream dir at
  Build exit. The line holds: role, session id
  (from the hook's stdin JSON), pid, cwd, and the exit code and stderr of each attempt.
  The attempts are:
  - a write into `$TMPDIR`;
  - for `KOGEN_ROLE=developer` only, a write into the Candidate's ignored
    `.kogen/runtime/` (the Reviewer must not change the Candidate);
  - a write to `KOGEN_BOUNDARY_PROBE_OUTSIDE`, the fixture control's
    `.kogen/runtime/boundary-escape/`;
  - `git -C <fixture control> update-ref refs/heads/kogen-boundary-escape HEAD`.

  The test matches lines to the Developer (fresh and resumed) and Reviewer session
  ids from the tracking record. It asserts the inside writes succeeded, that both
  outside attempts failed with "Operation not permitted", and that the escape file
  and ref are absent.
  Never add `.claude/settings.json` to this repository.
- Prior art, read only: stash `d6d184f8872c367c6e62172cd7e4285f4a16f4cc`
  (`failed prevent-intent-mutation candidate`, 2026-09-19), `^3:lib/kogen/containment.ex`,
  has canonical-path checks and SBPL string quoting you may reuse. Its deny-default
  profile and in-Candidate Intent-tree protections are **not** this design.
- `workflows/codex-runtime-upgrade.md` and `workflows/claude-code-runtime-upgrade.md`:
  before accepting a new pin, re-run the write-boundary probes (a real turn and a
  resume inside the profile, with the denial log empty for the harness's own paths).
  The scripts are in `evidence/write-boundary-probe/`.
- A Codex scope already receives two deterministic Kogen files
  (`environments.toml`, `agents/kogen_boundary.toml`,
  `lib/kogen/codex/environment.ex:227-303` at `9ff7af6e`). Fixtures pre-seed them, and the
  scope-immutability assertion allows exactly those two.
- `test/support/root_profile_audit.ex`: `sessions_root/3` (project, role, route, since #2) for a Claude role must
  cover both the scope's `projects/` (interactive Shape) and the project's
  Build harness homes (`<workspaces-root>/<project-id>/harness/*/claude/projects`).
  Live callers pass `sessions_root(fixture)` or `sessions_root(fixture, role, route)`, so no live test file needs
  editing for this. Prove it offline in `root_profile_audit_test.exs`.
- Quote every path. The default root contains a space. At `9ff7af6e` the
  lifecycle fixture's `target_evidence` recipe splices unquoted `-pa` paths
  (`test/kogen/lifecycle_test.exs:724-792`, `install_target_evidence_fixture!/1`, the
  `-pa` join at line 785). Fix it.
- `README.md`: the Build paragraph (Candidate location, kept-Candidate message,
  `mix kogen.candidates*`), the Claude login section (per-Build harness home,
  logins referenced through `CLAUDE_SECURESTORAGE_CONFIG_DIR`, never a private
  `HOME`), the PreToolUse guard as a courtesy guard, the write boundary (what
  roles may write, the EPERM message, `boundary: applied|inherited` in the
  record, the kept bypass flags and why, macOS only, the controller and Shaping
  outside it), and the limits (engine limitation, Codex rollouts, login and
  keychain writable by roles).
- `workflows/claude-code-runtime-upgrade.md`: add the re-probe of cases A, D2
  and F from `evidence/harness-home-credential-probe-2026-09-25.md` before
  accepting a new pin.

## Evidence ownership

- `check` owns everything deterministic: topology, harness-home and credential
  wiring, routing sentinels, controller verification in the Candidate,
  same-Candidate rework in the fake lifecycle, Shaping during a Build,
  publication and refusal, retention, records and the commands, plus the write
  boundary's profile, every refusal and allowed write (real `sandbox-exec`, fake
  roles), the Codex scope denials and every fail-closed and inherited case.
- `live-shape-to-build` owns the Claude Code provider-only observables:
  - a real Claude Code Developer logs in through the scope reference from a
    per-Build config dir;
  - its session resumes there in the Candidate cwd after a controller-failed
    verification;
  - the real Reviewer on the default route's Reviewer harness (Claude Code
    while `default_route` stays `claude`; the paid fixture copies the
    repository's `.kogen/config.yaml`) runs in the same Candidate. The Codex
    Reviewer's Candidate cwd and per-Build operation root are proved offline
    only;
  - the fixture's `main` is fast-forwarded and the Candidate is removed;
  - the real interactive Shape session before it still uses the scope's own
    config dir with the same login;
  - the real Claude Code Developer (fresh and resumed) and Reviewer run to
    acceptance inside the write boundary, and a write from their process trees
    into the fixture's control checkout and its Git refs is refused (scenario
    `role-write-boundary`).
- `live-reviewer-rework` owns the one Codex provider-only observable. Its nested
  Build already runs the hybrid route every batch Build uses, and its real Codex
  Reviewer returns both verdicts inside the boundary, with rollouts, login refresh
  and bookkeeping in the granted Codex scope (scenario `codex-roles-inside-boundary`).
  It is not a new target. Its support, `test/support/root_profile_audit.ex` and
  `test/support/live_reviewer_rework_fixture.ex`, is edited here, and no other target
  runs a real Codex role through a Kogen Build. DIRECTION D8 allows a second paid
  target for a provider-only observable, and this is one. It also closes the old
  `unrun-live-targets` gap for that target.

## Prior Candidates to reuse (driver, 2026-09-25)

Earlier failed Builds of this Intent left reviewed Candidates in the main repository's
stashes. Find them by SHA with `git stash list --format='%gd %H %s' | grep <sha>`:
- `eb76a87200…`, the Candidate of Build `cFnHwg7P`. This is the closest one: it passed both
  paid targets, and it failed only because it rewrote `.codex/hooks.json`, which this
  revision forbids.
- `ccfa9e48a2…`, the Candidate of Build `JendTonO`.
- `3f5059b095…` and `85bf47200e…`: unmatched earlier attempts.
- `d6d184f887…` (`failed prevent-intent-mutation candidate`): a 2026-09-19 Seatbelt
  containment attempt (`^3:lib/kogen/containment.ex`). Use it only for path
  canonicalization and SBPL quoting; see Developer notes.

Restore the worktree, launch-context and cleanup parts that still fit this contract
(`git show <sha>:<path>`, and `<sha>^3:<path>` for untracked files), then apply this
revision's design: no hook, prompt, catalog or config changes; the per-Build
`CLAUDE_CONFIG_DIR` with `CLAUDE_SECURESTORAGE_CONFIG_DIR`; controller-owned verification from
#4. Don't re-implement working code from scratch. Never apply, pop or drop these stashes.

## Retry after Build 8Bs51yZP (2026-09-26, driver)

Start from the stashed Candidate `isolated-candidate-workspace-candidate-2026-09-26`. Find it with
`git stash list --format='%gd %H %s' | grep isolated-candidate-workspace-candidate-2026-09-26`, and restore
files with `git show <sha>:<path>` and `git show <sha>^3:<path>` for untracked files; never apply, pop or
drop it. It passed check, live-reviewer-rework and live-shape-to-build. Then fix the Reviewer's finding
(evidence/build-failure-8Bs51yZP.md): resolve the Build's credential bindings (login scopes per harness the
route's roles use) and write them to the owner record **before** `Kogen.Harness.open_roles/4` and before
any readiness or provider call. Readiness then verifies those recorded bindings.

Rebasing the stash onto main `98ebcfb2` (Jev Keychain service renamed from `ai.typesafe.api` to
`dev.kogen.jev`) conflicts only in `test/kogen/build_preconditions_test.exs` (keep the Candidate's
`Kogen.Build.run(@slug, nil, dir)` call with main's `dev.kogen.jev` strings) and the generated
`priv/kogen/test-reliability.yaml` (take the Candidate's file, then run
`python3 scripts/check/refresh_test_reliability_sources.py`). Probed: compile clean, 440 focused
tests pass (evidence/reshape-2026-09-26-98ebcfb2/). Those tests pass with the binding-order defect,
so add the ordering assertion that scenario `candidate-creation` now requires.
