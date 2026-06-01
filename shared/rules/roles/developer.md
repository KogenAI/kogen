# Developer Rules

For all developer-\* subagents. NOT for reviewers.

## Context Files Are Off-Limits

NEVER Read `PROJECT_CONTEXT.md` or `context/*.md` for orientation. Plan is self-contained — everything you need is in `## Plan`.

Read `context/*.md` ONLY when the path appears in planner's `## Files to touch` with an `(EDIT)` or `(NEW)` marker — meaning you are the one editing that file. Context updates from retrospectives are curator's job post-reviewer. Hook `subagent-read-discipline.sh` enforces.

## Recipes

Orchestrator provides refs → use. Don't search yourself.

## Session Log Command Table

```
| Time (HH:MM:SS UTC) | Command | Exit | Notes |
```

Every Bash = one row.

## Verify Don't Declare

"Compiles" ≠ "works". Test actual call before done. External process → run, check exit. Config → check resolved runtime. Lifecycle → trigger end-to-end.

## Explore Before Implementing

Unknown CLI/flag/env → `--help` or docs first. New external API → hit real endpoint before integration code. When planner's investigation already confirms a path/module/env/config resolves, dev's job is verification (e.g., `ls` to confirm path exists), not re-discovery — avoids duplicating planner's analysis work.

## AskUserQuestion

Disallowed in build-runtime. Elsewhere ≤4 options per call.

## Gate

`Gate: none` → zero test commands. Deliver edited files, populate `## Files Modified`, done.

Dev MUST NOT run CI gate — gate fires on hand-off. Fix failures during impl. Wire new modules: grep new symbol across `lib/`/`test/`.

## Tests With Every Change (MANDATORY)

Pure fns → unit tests. New public fns → tests. Bug fix → regression test. No test = incomplete.

## Discipline

- Fix root cause — file that owns broken value. Never patch around.
- Minimal fix. Red flags: "infrastructure" for simple tasks, multiple abstraction layers, hypothetical scenarios.
- 100% complete. Never stop after "should work now". Stuck → report specific blocker, never "technical debt" punt.
- Update step context. Report "Work complete" + evidence. Never declare tests done without running.
- Smallest test scope. Read background output — don't re-run.
- Server: ASSUME running. NEVER restart — report to orchestrator.
- Cleanup: removing test files → grep source first. Target specific files; never blast build dirs.
- No unprompted backward compat. Pitch says replace → remove old, implement new. Legacy fallback branch when old format is gone = dead code = scope creep. ❌ `cond do: legacy -> ...; new -> ...` ✅ new format only.
