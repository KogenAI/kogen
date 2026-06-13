# OCG Codegen Style Guide

Conventions for the template-generation engine and subagent templates under `templates/`.

## Subagent Templates Must Declare `tools:`

Every `shared/subagents/**/*.md.j2` MUST include a `tools:` line in its YAML frontmatter:

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

The list is comma-separated, alphabetized for readability.

## `tool.name` Branch Pattern

`process_template.py` recognizes two `tool.name` values: `claude`, `pi`. Two branches render differently — not future hooks, real divergence today.

**Mechanics** (`process_template.py` `_strip_template_blocks`, regex pass):

- `{% if tool.name == 'claude' %}A{% else %}B{% endif %}` → claude keeps `A`, pi keeps `B`.
- `{% if tool.name == 'claude' %}A{% endif %}` (no else) → claude keeps `A`, pi drops entire block.

**Why two branches** (semantic intent):

- Claude Code auto-loads `@path/to/file.md` recursively when CLAUDE.md is ingested → claude branch emits `@<path>` for free recursive inclusion.
- Pi (AGENTS.md) does NOT auto-resolve `@`-references → else branch must instruct the agent explicitly: `→ See \`<path>\` for <reason>` so the agent Reads on demand.

Same intent, different delivery mechanism. Don't collapse to one branch — pi agents would silently miss the file.

**Path caveat**: claude-branch `@`-paths sometimes use the `codegen/` symlink prefix (Claude resolves `@` against project root where the symlink lives, e.g. `@codegen/rules/foo.md`) while the else-branch uses the real path under `context/` or `rules/` (e.g. `→ See \`rules/foo.md\``). Both resolve to the same file via the symlink, but the prefix differs because `@` ingestion and explicit Read have different working-dir semantics.

**Example** (`shared/apps/AGENTS-phoenix.md.j2:86-88`):

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

- `process_template.py` is the single rendering engine. It supports one output format:
  - `--format=md` (default) — Markdown body for Claude or Pi.

When adding a new harness, prefer extending `process_template.py` (new `tool.name` branch) over introducing a parallel renderer.
