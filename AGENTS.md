# AGENTS.md - Codegen

Guidance for AI agents working in the codegen repository.

**Codegen = polyglot generator repo.** Generates and installs AI-agent harnesses (Claude Code, Pi) consumed by downstream Phoenix and static-site projects. Tech stack: Bash + Python (`process_template.py`, `hook_registrations.py`) + Jinja-style `.md.j2` templates + TypeScript Pi extensions + Elixir/ExUnit test harness.

**No subagent delegation chain.** Codegen has no `.claude/agents/` directory. A Claude session edits files directly and commits to main — no planner→dev→reviewer→committer chain.

## Real Dev Loop

Single Claude session, direct edits, commit to main:

1. Edit a `.md.j2` template, rule file, hook script, or scaffold script
2. `make test` — hermetic bash hook unit tests + Pi extension npm tests; fast, no LLM calls
3. `make install` — regenerate agents, register hooks, render settings; propagates edits to `~/.claude/`
4. Parity checks: `make rule-parity` / `make hook-parity` / `make harness-parity`
5. `make test-stacks` — slow ExUnit scaffold suite; real LLM calls; run as pre-deploy gate

## Workspace Rules

- Work in current directory only (never `../`)
- No worktrees — commit directly to main
- No subagent delegation — edit files directly

→ See `context/repo-structure.md` for physical layout of every file and directory.

→ See `context/development.md` for Make targets, tech stack details, and coding conventions.

## Universal Requirements

- **Issue Discovery → Immediate Fixing** — find, fix, never just document
- **Session logging** — record commands in `codegen/logging/`
- **Credentials** — never replace real credential/token values with placeholders
