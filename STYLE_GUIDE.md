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

`process_template.py` recognizes four `tool.name` values: `claude`, `codex`, `cursor`, `opencode`.

- `claude` and `opencode` are explicit branches in `{% if tool.name == 'claude' %} ... {% elif tool.name == 'opencode' %} ... {% endif %}`.
- `codex` and `cursor` currently render the `claude` branch — explicit branch points exist as future-divergence hooks. Add new branches by extending `_strip_template_blocks` in `process_template.py` rather than introducing a new harness-specific generator script.

## Generators

- `process_template.py` is the single rendering engine. It supports two output formats:
  - `--format=md` (default) — Markdown body for Claude/Cursor/OpenCode.
  - `--format=toml` — per-agent Codex TOML. Requires `--config=<path>` and `--role=<name>`.
- `generate-codex.sh` is a thin walker that calls `process_template.py --format=toml` per template.
- `generate-cursor.sh` is a thin walker that calls `process_template.py <template> cursor false`.

When adding a new harness, prefer extending `process_template.py` (new `tool.name` branch + new `--format` mode) over introducing a parallel renderer.
