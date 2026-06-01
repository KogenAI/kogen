# AGENTS.md

Guidance for AI agents in OCG workspaces.

## MANDATORY: Load Rules FIRST

BEFORE any action:

1. IDENTIFY agent type from prompt/role
2. LOAD appropriate rules from `./codegen/rules/INDEX.md`:
   - All agents: load shared rules
   - Orchestrator: ALSO load all orchestration rules
   - Subagents: ALSO load domain-specific rules from subagents/
3. APPLY rules to every action

Rule loading strategy:

- Orchestrators: load orchestration rules (delegation-patterns.md, resource management, parallel strategies) + UI delegation patterns if plan mentions UI/design
- Subagents: role definition specifies exact rules — follow that list
- All agents: always load shared rules (server-management, subagent-core-rules)

## Output Style

Output: caveman ultra. Agents read you, not humans. No preamble. No recap. No pleasantries. Drop articles, filler, hedging. Fragments OK. Arrows for causality (X → Y). Short synonyms (fix not "implement a solution"). Inline acronyms (dev, VE, impl, DB, conn, fn, reqs). NEVER touch JSON schemas, Ecto field names, contracts, code blocks, error strings, "MUST"/"NEVER"/"FORBIDDEN", or hook markers (ALL CLEAR ✅, FAILED ❌, INCONCLUSIVE ⚠️) — verbatim regardless of style. Drop ultra for security warnings or irreversible-action confirmations.

## Planning vs Implementation Rule Separation

NEVER load planning rules during implementation.

FORBIDDEN during implementation:

- `planning.md` (planning sessions only)

Use ONLY during `ocg bird-eye`, `ocg plan`, or planning mode contexts.

Why forbidden: planning rules contain constraints for planning sessions → confusion between planning goals and impl execution.

## Cross-Role Rule Contamination

NEVER LOAD unless specified in your role template:

- `code-review.md`: ONLY for reviewer-phoenix / reviewer-static
- `verification-workflow.md`: superseded by `dev-gate.sh` hook classifications

When loading a rule file, ONLY follow commands appropriate for your role. Rule files may contain examples for other roles — ignore them.

### Command Authority Matrix

| Command                            | dev-gate.sh hook | developer-phoenix-backend | developer-phoenix-frontend | reviewer-phoenix |
| ---------------------------------- | ---------------- | ------------------------- | -------------------------- | ---------------- |
| `make ci`                          | ✅ Full suite    | ❌ FORBIDDEN              | ❌ FORBIDDEN               | ❌ FORBIDDEN     |
| `mix test` (no args)               | ✅ Full suite    | ❌ FORBIDDEN              | ❌ FORBIDDEN               | ❌ FORBIDDEN     |
| `mix test test/file.exs`           | ✅ Allowed       | ✅ Targeted only          | ✅ Targeted only           | ❌ FORBIDDEN     |
| `mix credo --strict`               | ✅ Full scan     | ✅ Self-check             | ✅ Self-check              | ❌ Read only     |
| `mix compile --warnings-as-errors` | ✅ Verification  | ✅ Self-check             | ✅ Self-check              | ❌ FORBIDDEN     |

- `mix test` = full suite = dev-gate.sh hook ONLY (runs `make ci` per gate-select.sh)
- `mix test test/specific_file.exs` = targeted = developer-phoenix-backend / developer-phoenix-frontend OK
- reviewer-phoenix NEVER executes, only analyzes

### Translation File Staging

See `git.md`. Only translator agent can stage .po/.pot files.

## Rule Hierarchy

- Orchestrators: `delegation-patterns.md` always overrides everything
- Subagents: core domain rules always critical (e.g. `phoenix.md` for developer-phoenix-backend)
- ANY conflict → critical rules WIN, no exceptions

## MCP Tool Failure Protocol

All agents load `./codegen/rules/shared/mcp-tool-failure-protocol.md`.

Required for: developer-phoenix-backend, developer-phoenix-frontend.

Working without MCP tools → broken/incomplete results. Fail fast.

## Workspace Rules

- Work in current directory only (never `../` or `../../`)
- Check `./codegen/CONTEXT.md` for ports/settings

## Universal Context Files

All agents read:

- `./codegen/PROJECT_CONTEXT.md` — project architecture and patterns
- `./codegen/CONTEXT.md` — workspace state, ports, progress

UI agents also read (if files exist):

- `./codegen/FIGMA_MAP.md` — Figma node ID to Phoenix component mappings
- `./codegen/FIGMA_DESIGN_SYSTEM_RULES.md` — design system rules
- `./codegen/FIGMA_TOKEN_MAPPING.md` — design token mappings

## Recipe System

If orchestrator provides recipe references, use them. Don't search for recipes yourself — orchestrator handles discovery.

```
Task: "Fix async test failures"
HELPFUL RESOURCES: See ./codegen/recipes/phoenix-async-feature-testing.md
```

## Library Usage Rules

Location: `$OCG_CONTEXT_DIR/usage_rules/`

Load BEFORE implementing with unfamiliar libraries:

- Jason → `jason-1.4.4.md`
- Ecto → `ecto-*.md`
- Phoenix LiveView → `phoenix_live_view-*.md`
- Gettext → `gettext-*.md`
- Floki → `floki-*.md`
- Other → `ls $OCG_CONTEXT_DIR/usage_rules/`

Discovery:

```bash
ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "^library_name"
```

Files named `{library_name}-{version}.md`. Large frameworks split into topic files — load main index first.

Generate missing:

```bash
ocg usage-rules
```

Not needed for: built-in Elixir/Erlang modules, libraries you know well, simple one-function utilities.

## Session Logging

All agents create session logs. See `shared/session-management.md`.

- File: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_[role].md`
- When: create as SECOND action (after loading rules). Update continuously.

Rules:

1. Mark `[x]` ONLY after reading file with Read tool
2. Log commands with timestamp
3. Save lessons to `./codegen/CONTEXT.md`

## Work Context Management

Use RELATIVE paths for context files. NEVER absolute paths.

```bash
# CORRECT
./codegen/context/PENDING-*.md

# WRONG — writes to main project, invisible to agents
/Users/.../project/codegen/context/PENDING-*.md
```

- Location: `./codegen/context/`
- Prefixes: `PENDING-*`, `ACTIVE-*`, `RESOLVED-*`
- Check at session start: `ls ./codegen/context/PENDING-* 2>/dev/null`

## Universal Requirements

- 100% task completion
- Issue Discovery → Immediate Fixing — find issues, fix them, never stop after documenting
- Check work contexts — always check `./codegen/context/PENDING-*` at session start
- Update work contexts — PENDING→ACTIVE→RESOLVED as you work
- Workspace isolation — never navigate outside current directory
- Port awareness — use ports from CONTEXT.md, not hardcoded
- Server management — Phoenix server already running; only restart if explicitly needed
- Session logs — ALL agents must log
