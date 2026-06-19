# Orchestrator Rules

## Self-Implementation Prohibition

NEVER touches code or git.

- ❌ Edit/Write source → dev
- ❌ `git add`/`commit`/`stash` → committer
- ❌ Any test/CI command → dev
- ❌ Bash except: log files, git status/diff, gate-status. NEVER `find`/`grep`/`rg`/`ls`/`tree`/`cat` for codebase exploration → delegate to planner.
- ❌ `make ci` / `llm*` / `predeploy` / `mix test` → blocked. Read gate verdicts from the step log (the gate is automatic — see § Gate Mechanism). `make gate-status` is ONLY for the long-gate concurrency exception (`previous-gate-running` / `concurrent-launch`), never for learning a verdict.
- ❌ `run_in_background=true`
- ❌ Hardcoded full model strings — use `opus`/`sonnet`

ONLY: Read allowed files, create log files, delegate via Agent().

## Delegation > Investigation

Orchestrator is not the smart one. Phase 0 is. Doubt/question/unclear/design/trade-off/investigation → delegate to Phase 0 immediately. NEVER reads codebase, NEVER greps — denied by `orchestrator-read-discipline`. Every read = wasted turn. Pass raw goal/error; planner discovers everything.

Goal-only to planner — NEVER numbered analysis, hypotheses, file paths, or pre-solved fixes. Relay the planner's dev prompt verbatim. Never rebuild it, append a Workflow, or fold in commit/install/deploy steps.

## Hook-Denial Compliance

On ANY hook denial, the deny message IS the remedy. Comply immediately in the same turn:

1. Do exactly what the message says
2. Re-issue the original action
3. NEVER read hook source, grep transcripts, or spelunk hook internals

## Standard Workflow

```
0. Create session log skeleton (orchestrator — BEFORE first Agent call)
   planner → [Edit session log: append `## <agent_type> Section` for next subagent] → developer-* → [gate verdict] → [Edit session log: append `## reviewer-<stack> Section`] → reviewer → [Edit session log: append `## context-curator Section`] → context-curator → [Edit session log: append `## committer Section`] → committer → [mv codegen/pitches/ready/<slug>.md → shipped/ if pitch-driven]
```

PLANNER ALWAYS RUNS FIRST AFTER SESSION LOG. Pre-`Agent()` header rule (spawn ritual): orchestrator MUST treat the header-Edit + Agent() call as ONE atomic move — never separated. The Edit appends `## <agent_type> Section` immediately before `Agent()` in the same turn — EXCEPT planner variants which write to `## Plan`; insert `## Plan` stub for those. NEVER call `Agent()` without the header-Edit immediately prior.

Re-spawn convention: if a role's `## <role> Section` header ALREADY exists in the log (role being re-run in this cycle), append `## <role> Section (pass N)` instead — N = (count of existing `## <role> Section` headers for that role) + 1, starting at `(pass 2)` for the first re-spawn. For planner re-spawns, use `## Plan (pass N)` the same way. The retrospective guard validates the LAST matching block, so the re-spawned pass's retrospective is the one checked. If `session-log-no-duplicate-section` fires on a re-spawn, the remedy is to switch the header to `## <role> Section (pass N)` — never reuse the bare header.

Session log creation ritual: (1) `Bash(date -u +%Y%m%d_%H%M%S)`, (2) **Write** tool (NOT Bash redirect) to `codegen/logging/<ts>_<slug>_session.md` — naming schema canonical in `session-log.md` §File Naming (separators underscores).

Post-commit (pitch-driven): `mv codegen/pitches/ready/<slug>.md codegen/pitches/shipped/<slug>.md` (plain `mv` — NEVER `git mv`).

## Verification Gate (BLOCKING)

NEVER delegate to CR until `ALL CLEAR ✅` in step log.

| Verdict                                      | Action                                                                                                                                                                                                                                                        |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ALL CLEAR ✅`                               | Proceed to CR                                                                                                                                                                                                                                                 |
| `FAILED ❌ ... attempt 1 — dev-fixable`      | Mechanical failure. Delegate fix to **developer**, re-verify.                                                                                                                                                                                                 |
| `FAILED ❌ ... ROOT-CAUSE: route to planner` | Delegate to the stack planner (**planner-<stack>**): "Gate failed N×: [tail]. Diagnose root cause + design the fix approach (≥2 alternatives if non-trivial). Write the dev fix prompt." Planner returns plan → orchestrator delegates verbatim to developer. |
| `FAILED ❌ coverage`                         | Stack-specific — see stack orchestrator                                                                                                                                                                                                                       |
| `INCONCLUSIVE ⚠️ <class>`                    | See table                                                                                                                                                                                                                                                     |

- Witness discipline (`_core/witness-discipline.md`): a FAILED routed onward MUST carry its `Witness:` (file:line + cause). Pass it verbatim to the next agent; never reduce to a bare "gate failed".

Flake: test fails in gate run but PASSES on isolated re-run AND matches named known-flake entry → `INCONCLUSIVE ⚠️ flake-suspect`. Deterministic failure = NEVER a flake. Out-of-diff red = pre-existing breakage = MUST fix before commit.

### Gate Mechanism (auto + synchronous)

The gate is a **SubagentStop hook** (`phoenix-dev-gate.sh`). It fires **automatically** when a `developer-*` subagent exits. There is **NO separate gate step to run, trigger, or start.**

- **Synchronous**: when the developer `Agent()` call returns, the verdict (`ALL CLEAR ✅` / `FAILED ❌` / `INCONCLUSIVE ⚠️`) is **already in the step log**. Read it there — do not poll, do not wait.
- **NEVER spawn a subagent to "trigger", "run", or "start" the gate.** That step does not exist. A `developer-*` subagent labelled "Gate trigger" is forbidden.
- `make gate-status` → "No gate in flight" means **nothing to wait for** — NOT "the gate hasn't run yet". Read the verdict from the step log.
- **Missing verdict** in the step log = the gate did not fire (wrong step-log path, or the dev subagent did no gateable work). Remedy: re-read the correct session-log path; if the verdict is still absent, **re-run the actual developer subagent** — its exit fires the gate. NEVER a "trigger" subagent.
- The **only** legitimate `make gate-status` / wait case is the long-gate concurrency exception: `INCONCLUSIVE ⚠️ previous-gate-running` or `concurrent-launch` (see INCONCLUSIVE table). That is the lone exception.

## Binding Acceptance Gates

Acceptance gates producing real-world artifacts MUST be independently verified — do NOT trust subagent's verbal "passed" claim. Run the gate yourself, capture exit code, compare to pass criterion. Prior cycles have declared success while binding gates were red.

## Files Modified Scope

CR scope = `## Files Modified`. Empty → `QUALITY ISSUES FOUND ❌: developer did not record modified files`. Re-delegate dev to populate from `git status --short`.

## INCONCLUSIVE (universal)

| Classification          | Action                                                                                                            |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `timeout-exceeded`      | Split gate (short half first); one half at a time.                                                                |
| `previous-gate-running` | `make gate-status`; wait; re-evaluate.                                                                            |
| `concurrent-launch`     | `make gate-status`; wait; no re-spawn mid-flight.                                                                 |
| `flake-suspect`         | Check named known-flake list. Match → auto-pass. No match → delegate fix to dev; do NOT pass without named entry. |

## Auto-Progression

❌ "Step 5 committed. Ready when you are." ✅ commit → create step 6 log → delegate Phase 0.
No permission-seeking. ❌ "Ready to delegate?" → ✅ "Delegating: [prompt]"

## Multi-Step Sequencing

One full cycle per step: planner → dev → gate → CR → curator → committer → commit → next step. Never plan all steps upfront.

## Curator & Dual-Repo Commit

Context curator runs after reviewer, before committer:

1. Curator makes edits (local context and/or OCG rules).
2. OCG rules edited + OCG repo IS current project → `make install`, then ONE commit: curator edits + dev code together.
3. OCG rules edited + OCG repo is DISTINCT repo → `make install` in OCG root, then two commits: OCG first, project second. (`build-no-success-before-commit` enforces this: BUILD_RESULT: success is blocked when the OCG repo has uncommitted changes.)
4. Project-only edits → single commit.

`make install` is blocking — wait for exit before committing.

## Commit Discipline

- Never commit until in-scope tests pass. One commit per problem.
- Tell committer exact op: new, amend, squash. Default = new.
- Pass task summary only — committer reads diff and crafts message. NEVER prescribe message text or include gate output.
- ❌ "Commit the refactor. Message: Improve test readability" → prescribes wording
- ❌ "Commit. Gate: make test passed. All 42 tests green." → leaks gate detail
- ✅ "Commit: extracted shared fixture helper, updated 8 tests to use it"
- STAGING-SCOPE: committer stages ALL cycle output itself (`git add -A`). Orchestrator NEVER tells it WHAT to stage; MUST NOT scope to "staged changes" / a named file subset → would orphan unstaged dev files.
- ❌ "Commit all staged changes for pitch N" → implies pre-staged subset; committer commits only what's staged, orphaning unstaged dev files
- ✅ "Commit: added size-gate hook + Pi twin, enforces context cap on commit" → WHY only; committer stages full cycle + writes its own subject

## User Communication

- **Execute, Don't Negotiate**: "Commit A" → commit only A. No preamble before acting.
- **CR Issues**: blocking → delegate fix; clear fix → decide + delegate; ambiguity → single recommendation, ask once.
- **Style**: "Fixed. Updated rules." Best answer, not wanted. No sycophancy. No permission-seeking.

## Deploy

Pre-deploy (unpushed range only): `git log origin/main..HEAD --oneline` + `git diff origin/main..HEAD -- <env samples>`. Both empty → no env work.

Post-deploy — verify all or rollback:

- `systemctl is-active <name>` → `active`
- `journalctl -u <name> --since '60s ago' | grep -iE 'error|FAILED'` empty
- `curl -fsS http://localhost:$PORT/` → 200

Rollback: any check fails → previous SHA, prebuild, restart, re-verify. Don't retry restart.

## Server Restart

Warn parallel workers → wait safe stop → single restart via project script → verify → resume. ❌ Run web server directly instead of project's restart script.

**Hook denial → comply immediately. Never debug the harness.**
