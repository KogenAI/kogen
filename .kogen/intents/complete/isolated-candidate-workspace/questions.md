# Questions

All questions are resolved. The Shaper delegated every technical decision on
2026-09-25 ("I approve whatever you guys decide! so you can build, drive this
without me"). The decisions below were made by the driver's shaping subagent
(Claude Opus 5.5, high) from source, probes and the adversarial audit, and are
revisable with evidence.

## Ask the Shaper

None.

## Shaper answers

1. Batch approval (2026-09-25, driver session): "so yeah, I approve:
   1. bounded-reviewer-evidence 2. cross-harness-adversarial-roles
   3. shaping-preflight-audit 4. verification-fortification
   5. isolated-candidate-workspace" and "that should count as my explicit
   approval".
2. Delegation (2026-09-25, driver session; plan/SUBAGENT-SHAPING-BRIEF.md and
   plan/BATCH-REPORT-2026-09-25.md): "you gotta make sure all the intents are ready to build tho …
   I approve whatever you guys decide! so you can build, drive this without
   me", and later "you don't need me for anything, you can do everything
   yourself … I approve everything".
3. The 2026-09-24 answers (worktree location, kept Candidates, commands) are
   quoted under "Open for the Shaper (2026-09-24, B1 reshape)" below.
4. **Launch-time write boundary (BLD-12): "Keep it in #5"** (Shaper, 2026-09-25,
   driver session, about 21:45; recorded in plan/BATCH-REPORT-2026-09-25.md).
   The question offered keeping the boundary in this Intent or the split
   ROADMAP row 7b. The Shaper chose to keep it: Build roles and helpers must be
   physically unable to write outside their Build's worktree, enforced by macOS.
   ROADMAP row 7b is withdrawn. This replaces the earlier `## Assumed` note that
   recorded the driver's split. The design is outcome 13 of INTENT.md and R8-R10
   below.

## Left undecided

None.

## Assumed

1. **The cross-harness Expert launched by `mix kogen.expert` from the
   Candidate uses the Build's binding and harness home.** Reason: every Build
   of this batch runs on `claude-dominant-adversarial-codex`, so without it
   the Expert would re-resolve its login scope from the Candidate path and
   write outside the harness home (which the write boundary now refuses).
   Undo: drop the Expert clause from `per-build-harness-home` and
   `lib/mix/tasks/kogen.expert.ex` from the guards.
2. **Review packets and record-version sidecars stay control-side.** Reason:
   the unedited Reviewer-rework support asserts the packet path layout, and
   both live fixtures retain from control. The locators Kogen hands a role are
   absolute (R12), so a Reviewer in the Candidate can still open the packet. Undo: none sensible; moving them
   would need edits to live-reviewer-rework support and its paid target.

## Settled

The technical decisions and their sources are in "Resolved in the 2026-09-25
re-shape" and "Carried forward" below.

## Dispositions

The 2026-09-25 audit findings and dispositions are in the driver's READINESS
note, `evidence/audit-2026-09-25/` and `evidence/repreflight-2026-09-25-363c20af/`.

## Resolved in the 2026-09-25 re-shape

### R1. Does the judge still need hooks that run from control?

No. Intent #4 makes the parent controller the only verification authority, loaded
from control when the Build starts, and it runs `make` with cwd equal to the
Candidate. The 2026-09-24 plan rewrote hook commands and Claude settings to run
control's scripts. Under main's controller that rewrite caused the refusal that
ended Build `cFnHwg7P2oNe1wMMnK7jxeMH`. Decision: this Intent changes no hook,
hook registration or Claude settings file. The Shaper's 2026-09-24 rule "the
verification code that judges a Build must not come from the Candidate" still
holds, because the controller is the judge. Q3 of 2026-09-24 (Codex reads
`.codex/hooks.json` from the Candidate) becomes moot for judging: that file now
drives only the courtesy PreToolUse guard.

### R2. How does a Build get its own harness home without losing a login?

The source and probe are in `evidence/harness-home-credential-probe-2026-09-25.md`.
A private `HOME` hides the login keychain, and a fresh `CLAUDE_CONFIG_DIR` has
no login. Claude Code keys its Keychain item and refresh lock on
`CLAUDE_SECURESTORAGE_CONFIG_DIR` when that variable is set. Decision: Claude
roles get `CLAUDE_CONFIG_DIR=<harness home>/claude` and
`CLAUDE_SECURESTORAGE_CONFIG_DIR=<scope>`, with the real `HOME`. Real model calls
and an exact resume worked from a per-Build config dir. Codex keeps `CODEX_HOME`
as the scope (`auth.json` and rollouts live there, and there is no separate
auth-home variable). Its per-Build part is the operation root, which already
holds a private `HOME`, `XDG_*` and sqlite. Nothing is copied, linked or moved.

### R3. What does "credentials per Build" mean while Builds are serial?

A per-Build **binding**, not a per-Build login. The scope for each role harness
is resolved once from control at admission. Readiness is checked in the Build's
own environment, the binding is recorded, and it is held for the whole Build.
A second concurrent login slot is order 8's question (SEC-01, "how many logins
the Shaper maintains").

### R4. Which paid target?

Superseded in part by R10 (2026-09-25, after the Shaper kept the write
boundary here): `live-reviewer-rework` is selected too, for the Codex boundary
observable. The original answer: `live-shape-to-build` only (ROADMAP: "one
lifecycle target"; D8). After #4 it
already drives a real fail, resume, pass, Review and commit loop. With this
Intent its inner Build runs in a Candidate with a per-Build Claude home, and
the real Shape session before it uses the scope directly. That makes it the
single run that observes both provider-only facts: login by reference and
resume from a worktree cwd. `live-general` is not edited and is not run (risk
`unrun-live-targets`).

### R5. Is BLD-12 in scope?

Yes, for Build roles (Shaper answer 4). Outcome 13 confines the writes of every
Build role process tree to the Candidate, the harness home, the Build temp dir,
retained evidence and the harness login state it must update. BLD-12's Shaping
half (Shaping sessions writing only their Draft) belongs to the
`headless-shaping-and-question-inbox` row, as `plan/features/BLD-12.md` lists it,
and the Shaper's answer names Build roles. Kernel protection of the Build's own
Approved copy inside the Candidate isn't added: the Shaper's rule names the
worktree as the boundary, and today's approved-mutation check already stops such
a Build.

### R6. Does the harness home survive publication?

Yes. Live audits read the Developer transcript after the fixture Build has
published, and the tracking record names the session ids. Homes are removed
with a retained Candidate by `mix kogen.candidates.remove`. Pruning published
homes is parked with Candidate prune.

### R7. `proof.base` for #4's red-on-base check?

Omitted. Main at `363c20af` rejects unknown proof keys. After #4, a contract
without `proof.base` validates and is labelled `unproven-on-base`, and #4 does
not switch integrity on for Kogen's own catalog. Re-checked 2026-09-26 at
`9ff7af6e`: `Contract.load` accepts an optional `proof.base` (`fail`/`pass`,
`contract.ex:261-263`), but with integrity off it is inert, so it stays omitted.

### R8. Which enforcement mechanism?

A per-launch macOS Seatbelt profile, `/usr/bin/sandbox-exec -p <profile>`,
wrapped around every Build role launch by Kogen's launcher. Probes on this host
(macOS 26.6.2, arm64; `evidence/write-boundary-probe-2026-09-25.md`):

- Writes outside the grants fail with EPERM for direct writes, child and
  grandchild processes (`make`), background children, `/tmp` aliases, symlinks,
  hardlinks, renames, chmod, xattr and utimes (probe 1).
- The kernel refuses a different nested profile (probe 2), so an enclosing
  profile can't be weakened from inside, and Codex's own Seatbelt can't run
  inside it (probe 10).
- A real Claude Code 2.1.281 turn inside the profile had its Write tool, Bash,
  a helper agent and a Stop hook's `make` refused outside and allowed inside
  (probes 4, 5, 13). Resume works (probe 13).
- `launchctl` job submission is refused from inside (probe 17). LaunchServices
  and Apple Events are not, so the profile denies `lsopen` and
  `appleevent-send`.
- Kogen's whole `make check` behaves identically inside the profile (probe 9).

Rejected alternatives:

- Claude Code's `permissions` or `sandbox` settings, and Codex's
  `--sandbox workspace-write`. They govern tool calls, not the harness process's
  own writes. Kogen launches both with bypass flags. Codex's Seatbelt can't
  nest. Claude settings are a controller-read file this Intent must not change
  (D9).
- A deny-default profile (the 2026-09-19 attempt). It needed repeated
  capability additions (`system-socket`, `file-ioctl`) and still failed Builds.
  The Shaper's requirement is about writes, so the profile allows everything
  except writes.
- File permissions or ACLs. They aren't per process tree and would also block
  the controller.

`sandbox-exec` is marked deprecated in its man page but ships and works on this
host (risk `seatbelt-interface-deprecated`).

### R9. What must roles be allowed to write?

The Candidate, the harness home and the per-Build temp dir, because roles work
there. The controller's `KOGEN_RAW_LOG_DIR` is **not** granted (Sol finding: it
could sit inside control or another Candidate). Roles get
`KOGEN_RAW_LOG_DIR=<harness home>/raw-log`, and the unconfined controller copies
that dir into its own at Build exit. The Shaper's rule is "worktree only", and the
remaining grants are named exceptions for shared login state. The login keychain file
and `<Claude scope>/.oauth_refresh.lock`, because a Claude Code OAuth refresh
writes both from inside the role's process tree. If those writes were denied, a
rotated refresh token would be lost and the shared login broken (probe 12). The
Codex scope, because `CODEX_HOME` is the scope: Codex writes rollouts, history,
state databases, locks, `config.toml` bookkeeping and `auth.json` refreshes there
(probe 10 and the 2026-09-18 probe). The profile denies the scope entries Kogen's
`validate_scope!` refuses and the ones Kogen owns (probe 18), so a role can't
plant `hooks.json` or `plugins/` (lesson 3). Kogen still validates `config.toml`
at every open (`native_settings.py`), so tampering fails closed at the next
launch. `/bin/ps` may run outside the profile: setuid executables can't run
inside one (probe 7), Kogen's own code calls it, and it writes nothing. Zsh
here-documents need `TMPPREFIX` in the temp dir, and Claude Code's Bash tool
needs `CLAUDE_CODE_TMPDIR`: its default `/tmp/claude-<uid>/` is refused
(probes 4, 5, 15).

### R10. Which paid targets?

`live-shape-to-build`, which this Intent already selects, observes the real
Claude Code Developer (fresh and resumed) and Reviewer inside the boundary. A
fixture-only SessionStart hook in their real process trees shows a refused
write into the fixture's control checkout and Git refs (probe 13 proved the
mechanism for about $0.06). `live-reviewer-rework` is selected for one Codex
observable: the real Codex Reviewer on the hybrid route every batch Build uses
completes inside the boundary. No fake can show which files real Codex writes
during an authenticated turn, and no other target runs a real Codex role through
a Kogen Build. That is D8's provider-only case. Its support files are also edited
here. It is an existing target, not a new one.

### R11. Sol-high audit dispositions (2026-09-25, 23:3x)

Decisions by the driver's shaping subagent (Claude Opus 5.5, high, 2026-09-25) under the Shaper's
delegation ("I approve whatever you guys decide"), revisable with evidence.
Raw output: `evidence/audit-2026-09-25-write-boundary/sol-high.md`. Jev classification:
`evidence/audit-2026-09-25-write-boundary/jev-sol-classification.json`.

1. Grants beyond the worktree contradict "worktree only". Fixed. The harness home and
   temp dir are Build-owned working space named in the driver's brief. Everything else
   is now a named shared-login-state exception with its probe (outcome 13), and the
   READINESS asks the driver to show the Shaper this list.
2. The raw-log grant could reach control or another Candidate. Fixed: no longer granted.
   Roles log to the harness home, and the controller copies from there.
3. `inherited` lets a nested Build run with another Build's grants. Fixed: a
   managed-runtime Build refuses to start confined. Only the Expert and offline
   `KOGEN_HARNESS` fixture Builds may run inherited, and they are recorded as such.
4. The Codex paid proof could pass with an unwrapped real Codex. Fixed: a fixture-only
   `.codex/hooks.json` SessionStart probe in the real Codex Reviewer's process tree must
   show refused outside writes (mechanism proved by probe 20). The Expert is proved
   through the production managed-open path offline.
5. The fixture migration needs an inventory. Fixed: the Developer notes require an
   inventory of every fake role and hook's write paths in the handoff. The probe-9
   wording is corrected to "same result", not "passes".

Advisory findings adopted: the claim is narrowed to tested routes (risk
`service-delegation`, including pre-existing hardlinks). The login-state grants are
described as security exceptions. `live-reviewer-rework` is kept (Sol: justified under
D8). No missing guards or selectors were found.

### R12. Re-preflight against the landed #4 (2026-09-26, 9ff7af6e)

Decisions by the driver's shaping subagent (Claude Opus 5.5, high, 2026-09-26) under
the Shaper's delegation ("I approve whatever you guys decide"), revisable with evidence.

1. **Which root does #4's verification cycle use?** Both, named. `make`, the
   Candidate catalog check and target evidence use the Candidate. The attempt's
   receipts and logs live under control, and their paths are relative to control.
   Reason: `Verification.run_cycle/4` takes one `:root` from `File.cwd!()` today and
   uses it for both. With one root, either `make` runs on control's clean tree or the
   logs get Candidate-relative paths that settlement can't find.
2. **How does a role in the Candidate find control-side files?** By absolute paths.
   Reason: the task context's `tracking_path`, the review-packet path and the failure
   prompt's receipt and log are control-relative today and wouldn't open from the
   Candidate cwd. `fake_codex` already opens `tracking_path` from its cwd. Reads stay
   open under the write boundary.
3. **Where do live owners retain evidence?** In control, through
   `KOGEN_LIVE_LOG_DIR`, which both live owners already honor. Reason: `git worktree
   remove` (without `--force`) deletes ignored files, so evidence written under the
   Candidate is lost at publication (checked with git on this host). Consumer: the
   existing live owners. Nothing new is added without a caller.
4. **GuardedPaths' Git files.** Resolved through `git rev-parse --git-path`. Reason:
   a linked worktree's `.git` is a file, so `File.read("<Candidate>/.git/config")`
   returns `:enotdir`, which `snapshot_files/2` turns into an admission error.
5. **Shaping-preflight-audit.** Not assumed. It is parked
   (`plan/staging/shaping-preflight-audit-PARKED.md`). If it lands later, its
   Shaping-only auditor launch must go through `Kogen.ClaudeCode.environment/2`,
   which this Intent already makes strip and set `CLAUDE_SECURESTORAGE_CONFIG_DIR`.
   That is #3's concern, not this Intent's.

### R13. Sol-high audit dispositions (2026-09-26, 9ff7af6e)

Decisions by the driver's shaping subagent (Claude Opus 5.5, high, 2026-09-26) under the
Shaper's delegation ("I approve whatever you guys decide"), revisable with evidence. Raw
output: `evidence/repreflight-2026-09-26-9ff7af6e/sol-high.md`. Jev classified all eight
findings as blocking (`jev-sol-classification.json`, 0.71 to 1.0). All are fixed in
`candidate-routing`, `controller-judges-candidate`, `write-boundary-fails-closed`,
`per-build-harness-home` and INTENT.md outcomes 2, 4 and 13:

1. Base-suite receipts are added to the control-relative log paths, and settlement is checked
   from a third cwd.
2. The persisted verification context records `candidate_root`, and every later
   `TargetEvidence.verify` reads it from there.
3. The scrub-list entry and the default `KOGEN_LIVE_LOG_DIR` are stated as additions of this
   Intent, which don't exist at 9ff7af6e.
4. `VerificationRunner` children and role launches drop `MIX_BUILD_PATH`, `MIX_DEPS_PATH` and
   `MIX_EXS`, proved by planted values.
5. `mix kogen.build` captures the control root once and passes it to `Build.run`. The
   `File.cwd!()` fallback in `Verification.project_root/1` is removed.
6. `Report.build`'s existence predicate and `snapshot_references` use the Candidate root.
7. The task context gains an absolute `control_root` for the control-relative locators inside
   the packet.
8. `KOGEN_EXPERT` also carries the Candidate path, the task refuses any other cwd, and a real
   subprocess test covers it. The task runs Candidate code inside the Build's boundary.

## The 2026-09-24 questions (history)


The questions file as it stood before the 2026-09-24 reshape is kept at
`historical/2026-09-22-warm-seed-revision/questions.md`. Its settled
boundaries still hold and are summarized under "Carried forward".

## Open for the Shaper (2026-09-24, B1 reshape)

The Draft currently assumes the recommended answer to each question.

### Q1. Where Candidate worktrees live — settled 2026-09-24

Shaper: "inside Kogen's own tree". CLAUDE.md/AGENTS.md nesting is
unimportant because those files are not wanted in projects; duplicate trees
in the repository are the cost to avoid. The location is
`~/Library/Application Support/Kogen/build-workspaces/<project-id>/`. Tests
redirect the root with `KOGEN_WORKSPACES_ROOT`, like `KOGEN_CLAUDE_ROOT`, so
automated tests never write to the real Kogen directory; the Shaper asked
what this meant and was answered.

### Q2. Kept Candidates: stop message and commands — settled 2026-09-24

The Shaper's answers across three rounds:

- A Kogen command for kept Candidates is wanted, not bare git commands.
- A list command is required: "git worktree list is useless - it doesn't
  show which worktree belongs to which intent and the worktree names are
  obfuscated". Names must be readable and list must show the Intent.
- Publish is dropped: "publish is weird because it's pretty much useless".
  An accepted Build already fast-forwards automatically.
- Remove is added. Guard accepted only: deleting a stopped Candidate's
  uncommitted edits is fine on request, but a Candidate holding an accepted
  commit not reachable from its admitted branch needs `--discard-accepted`.
- Prune is added. Removing orphans left by deleted or moved checkouts, the
  only cross-project action, needs an explicit flag, "because it's an
  unexpected behavior".
- Every command acts on the current project only.

Narrowed after independent review (2026-09-24): the Shaper forwarded a
review recommending cutting `prune` and `--orphans` to make B1 more likely to
land first time, and said "the agent was right / these other commands are
unnecessary for now / we can either add those as part of parallel builds or
even as a separate intent". B1 keeps `mix kogen.candidates` (list) and
`mix kogen.candidates.remove <build-id> [--discard-accepted]`. Prune, orphan
cleanup and the `project.json` they needed are parked in
`.kogen/runtime/shaping-followups/SHAPE_CANDIDATE_PRUNE.md`. They are not
approved backlog. The command names were not vetoed.

The same review's item 3 was also accepted ("the agent was right"): both
live fixtures' `KOGEN_WORKSPACES_ROOT` paths contain a space.

### Q3. The Codex route's hook configuration — settled 2026-09-24

The Shaper chose "Support, document limit": both routes use the same
control-root hook mechanism. It is documented that native Codex reads hook
*configuration* (`.codex/hooks.json`) from the Candidate, which is structural
separation, not hostile containment. Codex routing is proved offline only, and
no `live-native` target is added.

### Parallel Builds in this Intent? — answered, not reopened

The Shaper asked whether B1 allows parallel Builds and how much work adding
them would be, noting: "it might be too much ... when one build has merged
automatically, but then the other one needs to rebase main into it, rerun
the tests, maybe even fix conflicts". Answer: B1 does not allow them; the
global lock stays. B2 needs a per-Build lock and state, same-Intent refusal,
the pinned engine (the 2026-09-23 probe showed a running controller can pick
up code another Build publishes) and serial publication. Without rebase and
re-verification (brief 22), the second of two parallel Builds is kept
unpublished and must be rebuilt, which limits B2's value until integration
exists. The agreed order A → handoff → B1 → B2 stands unless the Shaper says
otherwise.

## Carried forward (settled, not reopened)

- All investigation, integration and repair happen in the Build's own worktree. Unverified
  changes are never installed on `main` to be fixed there.
- When `main` has not moved, publication needs no artificial merge or duplicate
  verification. When it has moved, B1 refuses. Bringing newer `main` into a Candidate needs
  fresh verification and Review and is a later Intent (brief 22).
- Future continuation uses the existing `mix kogen.build <slug>` command, not a separate
  resume command (brief 20). This does not settle its eligibility rules.
- Concurrent Builds, per-Build locks and the pinned engine are B2.
- The control checkout must be clean at publication; all work happens in worktrees
  (2026-09-23).
- No silent fallbacks (2026-09-23).

## Not B1

- Route naming: `decisions.md` (2026-09-23) records the Shaper asking for `claude` and
  `chatgpt`, but the committed config and README name `claude` and `codex`. That belongs to
  the named-routes follow-up, not this Intent.
