# OCG Codegen Style Guide

Conventions for the template-generation engine and subagent templates under `templates/`.

## Subagent Templates Must Declare `tools:`

Every `templates/shared/subagents/**/*.md.j2` MUST include a `tools:` line in its YAML frontmatter:

```jinja
{% if tool.yaml_frontmatter %}
---
name: my-agent
description: ...
model: opus
effort: medium
tools: Bash, Edit, Glob, Grep, Read, Write
---
{% endif %}
```

The list is comma-separated, alphabetized for readability. Required by `process_template.py --format=toml` — Codex generation fails fast when frontmatter is missing this key.

## Codex `sandbox_mode` Derivation

`process_template.py` derives each agent's Codex `sandbox_mode` from the `tools:` list:

- Contains `Write` or `MultiEdit` → `workspace-write`
- Otherwise → `read-only`

This replaces the deprecated `READONLY_ROLES` allowlist that previously lived in `generate-codex.sh`. The single source of truth is now the template's own frontmatter — no separate registry to keep in sync.

**Caveat for shell-based file writers**: an agent that writes via shell tools (e.g. `committer` running `git commit`, which mutates `.git/`) needs `workspace-write` even if it doesn't logically need an `Edit`/`Write` tool. List `Write` in its `tools:` to promote it to `workspace-write`. The tool-list inaccuracy is the lesser evil compared to a sandbox that blocks the agent's primary job.

## `tool.name` Branch Pattern

`process_template.py` recognizes three `tool.name` values: `claude`, `codex`, `cursor`. Two branches render differently — not future hooks, real divergence today.

**Mechanics** (`process_template.py` `_strip_template_blocks`, regex pass):

- `{% if tool.name == 'claude' %}A{% else %}B{% endif %}` → claude keeps `A`, codex/cursor keep `B`.
- `{% if tool.name == 'claude' %}A{% endif %}` (no else) → claude keeps `A`, codex/cursor drop entire block.

**Why two branches** (semantic intent):

- Claude Code auto-loads `@path/to/file.md` recursively when CLAUDE.md is ingested → claude branch emits `@<path>` for free recursive inclusion.
- Codex (AGENTS.md) and Cursor do NOT auto-resolve `@`-references → else branch must instruct the agent explicitly: `→ See \`<path>\` for <reason>` so the agent Reads on demand.

Same intent, different delivery mechanism. Don't collapse to one branch — codex/cursor agents would silently miss the file.

**Path caveat**: claude-branch `@`-paths sometimes use the `codegen/` symlink prefix (Claude resolves `@` against project root where the symlink lives, e.g. `@codegen/rules/foo.md`) while the else-branch uses the real path under `context/` or `rules/` (e.g. `→ See \`rules/foo.md\``). Both resolve to the same file via the symlink, but the prefix differs because `@` ingestion and explicit Read have different working-dir semantics.

**Example** (`templates/AGENTS-HYBRID.md.j2:76-78`):

```jinja
{% if tool.name == 'claude' %}@context/repo-layout.md
{% else %}→ See `context/repo-layout.md` when editing rules or recipes.
{% endif %}
```

Add new harness branches by extending `_strip_template_blocks` regex rather than forking the generator.

## Rule Authoring Order

Rule prompts ordered TOP (reference) → MIDDLE (situational) → BOTTOM (hard rules + most-violated). Recency bias — Claude weights top + bottom strongest; middle suffers "lost in the middle."

- **Reference** (TOP): ast-grep-patterns, elixir-code-generation, framework patterns (phoenix.md, phoenix-ui.md).
- **Situational** (MIDDLE): testing, session-management, server-management, token-budget.
- **Hard rules + most-violated** (BOTTOM): subagent-core-rules, workflow, style-caveman-ultra. Role-specific "Done when:" line ABSOLUTE LAST.

Common files at `/Users/almirsarajcic/Areas/Optimum/context/subagents/_*_common.md.j2` set canonical order via `{% include %}` slots.

See combobulate `context/rules-authoring.md` for full ordering law + bucket assignments + hooks-vs-rules separation + PROJECT_CONTEXT loader contract.

## Generators

- `process_template.py` is the single rendering engine. It supports two output formats:
  - `--format=md` (default) — Markdown body for Claude/Cursor.
  - `--format=toml` — per-agent Codex TOML. Requires `--config=<path>` and `--role=<name>`.
- `generate-codex.sh` is a thin walker that calls `process_template.py --format=toml` per template.
- `generate-cursor.sh` is a thin walker that calls `process_template.py <template> cursor false`.

When adding a new harness, prefer extending `process_template.py` (new `tool.name` branch + new `--format` mode) over introducing a parallel renderer.
