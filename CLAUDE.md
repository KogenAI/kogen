# AGENTS.md - Codegen

Guidance for AI agents working in the codegen repository.

**Codegen = polyglot generator repo.** Generates and installs AI-agent harnesses (Claude Code, Pi) consumed by downstream Phoenix and static-site projects. Tech stack: Bash + Python (`process_template.py`, `hook_registrations.py`) + Jinja-style `.md.j2` templates + TypeScript Pi extensions + Elixir/ExUnit test harness.

@context/repo-structure.md

@context/development.md

---

## Agent Roles

Codegen uses the standard multi-agent chain. Role routing for this repo:

```
planner-phoenix
    ↓
developer-phoenix-backend   ← ALL non-UI work in codegen (schemas, contexts, controllers, hooks, rules, scripts)
    ↓ (if frontend slice)
developer-phoenix-frontend  ← only if HEEx/LiveView/Tailwind/JS changes needed
    ↓
reviewer-phoenix
    ↓
context-curator
    ↓
committer
```

**Codegen-specific gloss — `developer-phoenix-backend` scope:**
In this repo "backend" means everything: Bash scripts, Python generator pipeline, TypeScript Pi extensions, Elixir/ExUnit test harness, `.md.j2` templates, rule files, hook scripts, scaffold files. There is no separate UI layer; `developer-phoenix-frontend` is only needed if a downstream-facing HEEx template, LiveView module, or Tailwind class is being changed.

**Split discipline (downstream Phoenix apps):** `lib/<app>/` (contexts, schemas, workers, mailers) → backend. `lib/<app>_web/` LiveView modules (`*_live.ex`), HEEx templates, JS hooks, Tailwind → frontend. Reviewer routes feedback to the correct subagent based on which layer the fix lands in.

---

## Orchestrator Rules

> **NEVER IMPLEMENT** — Orchestrator MUST NOT write code, edit source files, or run build commands directly. Delegate all implementation to the appropriate subagent.

> **ALWAYS RUN FULL CYCLE** — After any rule, template, hook, or scaffold change the full install cycle MUST be run by the developer subagent: `make test` → `make install` → parity checks → `make test-stacks` (pre-deploy gate). Skipping steps leaves stale baked prompts in `~/.claude/`.

---

## Real Dev Loop

What the developer subagent runs after any change:

1. Edit a `.md.j2` template, rule file, hook script, or scaffold script
2. `make test` — fast, hermetic; no LLM calls
3. `make install` — regenerate agents, register hooks, render settings; propagates edits to `~/.claude/`
4. Post-gate checks (optional): `make harness-path-check` — standalone optional manual target
5. `make test-stacks` — slow ExUnit scaffold suite; real LLM calls; run as pre-deploy gate

**Gate command = `make test`** (fast, hermetic). `make test-stacks` is the pre-deploy gate (slow, real LLM calls). `make ci` exists as a pure alias for `make test` (`ci: test`) — not a distinct target; the Phoenix-only gate is the _downstream generated app's_ `make ci`. Planners: always emit `Gate: make test` for codegen tasks.

---

## Draining the Queue

Multiple SHAPED pitches in `codegen/pitches/ready/` → drain with `claude-build --queue --watch`. This routes to `mix codegen.loop.queue` (`LoopQueueDrain`), which already: orders `ready/` by `blocks_on:` frontmatter, spawns one fresh `codegen-build` child per pitch, verifies each ship is non-orphaning (HEAD moved forward since the pre-spawn `head_before`, never reset away), moves `ready/<slug>.md → shipped/<slug>.md` only on a VERIFIED ship, and — with `--watch` — sleeps and re-scans on an empty queue instead of exiting, honoring mid-arrival quiescence. Cross-box possession: `codegen-drain assign`. Fleet distribution never separates a ready pitch from a prerequisite or dependent — `assign --auto`/`assign --slug --node` keep a `blocks_on:` chain on one node for its full ready → building → shipped lifecycle, fail-closed on any unreachable node.

**NEVER hand-roll a drain, driver, or relaunch loop** — no `/tmp/*.sh` polling `ready/`, no shell wrapper re-implementing ship verification or backoff. This has happened before, cost real commits, and the fix is always to use the shipped drain, not to patch the hand-rolled one.

---

## Workspace Rules

- Work in current directory only (never `../`)
- No worktrees — commit directly to main

---

## Update PROJECT_CONTEXT.md Before Reporting Done

Cross-reference modified files against `PROJECT_CONTEXT.md` § Domain Context Files Update column. Update every matched row before reporting done. If structural changes added new modules or files that no row covers, add a new row to § Domain Context Files with concrete Load-when and Update-when targets.

---

## Result Reporting (MANDATORY)

@codegen/rules/build-runtime/result-json.md

`{"status":"success"}` requires ALL of:

1. Session log exists with all subagent sections
2. CI passed (loop's dev-gate step → `ALL CLEAR ✅` in session log)
3. Quality approved (reviewer-phoenix)
4. Git commit made

---

## Universal Requirements

- **Issue Discovery → Immediate Fixing** — find, fix, never just document
- **Session logging** — record commands in `codegen/logging/`
- **Credentials** — never replace real credential/token values with placeholders
