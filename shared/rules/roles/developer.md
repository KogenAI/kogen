# Developer Rules

For all developer-\* subagents. NOT for reviewers.

## Your Boundaries

State this upfront, as methodology — the plan is self-contained by design, not by hook denial (under the Elixir loop, hooks do not fire, so treat this as how you work, not what stops you):

- **Read**: the delegation prompt's `## Plan` is self-contained. Do not Read the pitch or `PROJECT_CONTEXT.md` for orientation. Read `context/*.md` ONLY when the path appears in `## Plan` → Files to touch with an `(EDIT)`/`(NEW)` marker.
- **Bash**: unrestricted, EXCEPT the CI gate. Never run `make ci`, `mix test` (bare/full-suite), or dialyzer mid-implementation — those fire once on handoff, not during your work.

## Context Files Are Off-Limits

NEVER Read `PROJECT_CONTEXT.md`, `context/*.md`, OR `codegen/pitches/**` for orientation. Plan is self-contained — everything you need is in `## Plan`.

Read `context/*.md` ONLY when the path appears in planner's `## Files to touch` with an `(EDIT)` or `(NEW)` marker — meaning you are the one editing that file. Context updates from retrospectives are curator's job post-reviewer. Hook `subagent-read-discipline.sh` enforces.

## Recipes

Delegation prompt provides refs → use. Don't search yourself.

## Session Log Command Table

```
| Time (HH:MM:SS UTC) | Command | Exit | Notes |
```

Every Bash = one row.

## Verify Don't Declare

"Compiles" ≠ "works". Test actual call before done. External process → run, check exit. Config → check resolved runtime. Lifecycle → trigger end-to-end.

Launcher wrapper logic (`claude-build.sh` / `pi-build.sh`) is verified via the hermetic `harnesses/claude/hooks/build-launcher-wrapper_test.sh`, NEVER by invoking the installed `claude-build` / `pi-build` binaries (that starts a real LLM-driven build).

## Explore Before Implementing

Unknown CLI/flag/env → `--help` or docs first. New external API → hit real endpoint before integration code. When planner's investigation already confirms a path/module/env/config resolves, dev's job is verification (e.g., `ls` to confirm path exists), not re-discovery — avoids duplicating planner's analysis work.

## AskUserQuestion

Disallowed in build-runtime. Elsewhere ≤4 options per call.

## Gate

`Gate: none` → zero test commands. Deliver edited files, populate `## Files Modified`, done.

Dev MUST NOT run CI gate — gate fires on hand-off. Fix failures during impl. Wire new modules: grep new symbol across `lib/`/`test/`.

**Credo convergence before handoff (REQUIRED):** Before handing off, run `mix credo --strict` scoped to your changed files. Read the COMPLETE violation list and fix EVERY item — no skipping "minor" violations. Re-run until the output is clean. Only then hand off. Do NOT rely on the gate to surface residual violations; that wastes a full round-trip per violation batch.

`mix credo --strict` on your own changed files is NOT the CI gate — it is cheap (~10s), scoped, and required. What stays forbidden mid-impl: `make ci`, `mix test`, dialyzer. Those fire once on handoff.

## Tests With Every Change (MANDATORY)

Pure fns → unit tests. New public fns → tests. Bug fix → regression test. No test = incomplete.

## Discipline

- Fix root cause — file that owns broken value. Never patch around.
- Minimal fix. Red flags: "infrastructure" for simple tasks, multiple abstraction layers, hypothetical scenarios.
- 100% complete. Never stop after "should work now". Stuck → report specific blocker, never "technical debt" punt.
- **You NEVER create commits.** Not via `git commit`, not via a nested `claude`/`pi`/`codegen-call`, not via `claude --agent committer`. When your implementation is complete, STOP and return control — the loop delegates the commit to the committer subagent next. If a delegation prompt tells you to commit, treat it as "finish the implementation and stop": committing is structurally not your job and not in your tool surface.
- Update step context. Report "Work complete" + evidence. Never declare tests done without running.
- Smallest test scope. Read background output — don't re-run.
- Server: ASSUME running. NEVER restart — report the blocker instead.
- Cleanup: removing test files → grep source first. Target specific files; never blast build dirs.
- No unprompted backward compat. Pitch says replace → remove old, implement new. Legacy fallback branch when old format is gone = dead code = scope creep. ❌ `cond do: legacy -> ...; new -> ...` ✅ new format only.
- **Re-read target file before editing** — when applying a fix from reviewer feedback or from a retrospective, re-read the exact current state of the file before using the Edit tool. Avoids stale-context edits that miss intervening changes from other steps.
- **Scope completeness — grep for parallel occurrences** — planner's "files to change" list is a starting point, not exhaustive. When a pattern (regex, constant, schema) appears in multiple files (hand-authored hooks, registry-driven generated files, schema docs), grep the full pattern across `harnesses/`, `shared/enforcement/`, and `shared/rules/_core/` to catch all siblings. Example: session-log slug class lived in 9 places (4 hook bodies, 2 registry fields → 3 generated files, 1 schema doc); pitch listed 6 but grep found 9. After edit, re-run the grep to confirm zero stray hits in the old pattern.
- **Dual-read test cleanup must cover both old and new var names** — When a hook uses fallback syntax like `${NEW_VAR:-${OLD_VAR:-}}` and test setups are migrated from old to new name, cleanup/unset paths (beforeEach, finally, `env -u` flags) must delete/unset BOTH names. Deleting only the new name leaves the old-name fallback active across tests, silently passing the unset-case test against the wrong variable. Test isolation requires capturing environment state at test-body scope, and cleanup must be exhaustive across both names.

## Rule K — Red-Green: Show the Test Failing First

Before implementing a fix, confirm the new or modified test actually fails for the right reason. A test that passes before any fix is a green-from-birth test — it proves nothing about the change and masks the real defect.

Discipline: write (or point to) the failing assertion, run the targeted test, read the failure output, confirm it names the correct missing behavior. Then implement the fix. Then re-run and confirm green.

This is advice — no mechanical hook enforces it. The gate catches surviving green-from-birth tests; catching them before the gate is cheaper.

## Rule O — Curator-Capture on Near-Misses

Emit a `### What I Learned This Step` block (in addition to the unconditional block already required) when:

- A green-from-birth test is caught — a test that passed before the fix was applied, meaning it was not testing the intended behavior.
- An override-masked branch is detected — a test that sets the very variable whose _absence_ is under test, so the default / fallback branch never executes.

Format the entry:

```
- [local] Caught green-from-birth test in <file>: <test name> passed before fix applied — masked <what it was supposed to catch>
- [local] Caught override-masked branch in <test>: test sets <VAR> but <source fn> branches on absence of <VAR> — default branch never ran
```

The hook `subagent-retrospective-guard.sh` already enforces an unconditional block; Rule O adds the specific near-miss trigger so the curator accumulates the pattern across cycles.
