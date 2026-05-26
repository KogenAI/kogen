# Subagents Domain — Subagent Templates + Roles

The subagents domain owns the `.md.j2` Jinja-style templates that `generate.sh` renders into per-harness agent prompt files. Each template uses `{% include %}` to inline rules, recipes, and common fragments — producing a self-contained system prompt baked at install time. Subagents never re-read rules at runtime; everything is pre-loaded into the rendered `.md`.

Two common fragments (`_phoenix_developer_common.md.j2`, `_static_developer_common.md.j2`) deduplicate shared backend/frontend developer rules.

## Components

| File                                                    | Purpose                                                            |
| ------------------------------------------------------- | ------------------------------------------------------------------ |
| `shared/subagents/phoenix/planner-phoenix.md.j2`        | Phoenix planner — reads codebase, writes structured plan           |
| `shared/subagents/phoenix/developer-phoenix-backend.md.j2` | Backend developer — schemas, contexts, migrations, Oban         |
| `shared/subagents/phoenix/developer-phoenix-frontend.md.j2` | Frontend developer — LiveView, HEEx, JS hooks, Tailwind         |
| `shared/subagents/phoenix/reviewer-phoenix.md.j2`       | Phoenix reviewer — quality, patterns, architecture                 |
| `shared/subagents/static/developer-html.md.j2`          | Plain HTML + Tailwind v4 developer                                 |
| `shared/subagents/static/developer-hugo.md.j2`          | Hugo static site developer                                         |
| `shared/subagents/static/developer-vite.md.j2`          | Vite/React static site developer                                   |
| `shared/subagents/static/planner-html.md.j2`            | HTML stack planner                                                 |
| `shared/subagents/static/planner-hugo.md.j2`            | Hugo stack planner                                                 |
| `shared/subagents/static/planner-vite.md.j2`            | Vite stack planner                                                 |
| `shared/subagents/static/reviewer-static.md.j2`         | Static site reviewer                                               |
| `shared/subagents/shared/committer.md.j2`               | Committer — analyzes diff, crafts why-focused commit message       |
| `shared/subagents/shared/context-curator.md.j2`         | Context curator — updates domain context files post-reviewer       |
| `shared/subagents/_phoenix_developer_common.md.j2`      | Shared rules fragment included by backend + frontend templates      |
| `shared/subagents/_static_developer_common.md.j2`       | Shared rules fragment included by all static developer templates    |

## Key Paths

```
shared/subagents/
  _phoenix_developer_common.md.j2
  _static_developer_common.md.j2
  phoenix/
    planner-phoenix.md.j2
    developer-phoenix-backend.md.j2
    developer-phoenix-frontend.md.j2
    reviewer-phoenix.md.j2
  static/
    developer-html.md.j2, developer-hugo.md.j2, developer-vite.md.j2
    planner-html.md.j2, planner-hugo.md.j2, planner-vite.md.j2
    reviewer-static.md.j2
  shared/
    committer.md.j2
    context-curator.md.j2
```

Generated output lands in `templates/generated/<harness>/` then installed to `~/.claude/agents/` or equivalent.

## Integration Points

- **core**: `generate.sh` + `process_template.py` render these templates; output goes to `templates/generated/`
- **rules**: templates `{% include %}` rule files from `shared/rules/` — rule changes require re-running `make install`; behavioral rules for each role are documented in `context/rules-roles.md`; these templates are the wiring mechanism, not the rules themselves
- **harnesses**: each harness may have harness-specific includes; claude harness renders phoenix + static; pi harness renders from the same `shared/subagents/` tree unless it has overrides in `harnesses/pi/`
- **scaffold**: `shared/apps/AGENTS-phoenix.md.j2` and `AGENTS-static.md.j2` are downstream AGENTS.md templates (separate from subagent templates here)

## Pitfalls

- **Rule changes don't auto-update running agents** — must run `make install` to regenerate and reinstall
- **`{% include %}` paths** are relative to repo root; broken includes fail silently in some renderers — check `generate.sh` output
- **Never duplicate rules** across common fragment and individual template — add to common fragment, include once
- **Pi templates** — Pi harness generates from the same `shared/subagents/` tree as Claude; check `harnesses/pi/manifest.yaml` for any pi-specific overrides or additional templates
- **`dev-gate` is not a subagent template** — `dev-gate` refers to the orchestrator-invoked hook workflow (`phoenix-dev-gate.sh`), not an agent role with a `.md.j2` template; see `context/hooks.md` for gate mechanics
- **Trigger keywords refer to template wiring** — subagents.md covers how roles are assembled and baked into prompts; for what each role must/must-not do at runtime, see `context/rules-roles.md`
