# Scaffold Domain — Scaffolding for Downstream Apps

The scaffold domain produces the initial file tree for new downstream Phoenix or static-site projects. `codegen-scaffold` (top-level) delegates to `shared/scaffold/<stack>/scaffold.sh` which applies `mutations/` (bash scripts that write individual files) and `eex_render.sh` (renders `.eex` templates). The result is a runnable app with AGENTS.md, PROJECT_CONTEXT.md, and all boilerplate pre-wired for AI-agent workflows.

`shared/apps/` contains the human-readable template documents (`AGENTS-phoenix.md.j2`, `PROJECT_CONTEXT-phoenix-template.md`) used as both scaffold output and reference for new project setup.

## Trigger Keywords

scaffold.sh, eex_render, mutations, AGENTS.md.j2, PROJECT_CONTEXT.md.j2, ocg setup, codegen-scaffold, downstream app scaffolding

## Components

| File / Dir                                        | Purpose                                                           |
| ------------------------------------------------- | ----------------------------------------------------------------- |
| `shared/scaffold/phoenix/scaffold.sh`             | Phoenix scaffold entry — creates new Phoenix app via mutations    |
| `shared/scaffold/phoenix/mutations/`              | Per-file bash mutation scripts (config_exs.sh, mix_exs.sh, etc.)  |
| `shared/scaffold/phoenix/eex_render.sh`           | Renders `.eex` templates with variable substitution               |
| `shared/scaffold/phoenix/templates/`              | `.eex` source templates for Phoenix scaffold output               |
| `shared/scaffold/static/scaffold.sh`              | Static site scaffold entry                                        |
| `shared/scaffold/static/scaffold_test.sh`         | Bash tests for static scaffold                                    |
| `shared/scaffold/phoenix/README.md`               | Phoenix scaffold setup and mutation authoring guide               |
| `shared/apps/AGENTS-phoenix.md.j2`                | Downstream AGENTS.md template (Jinja — rendered for each new app) |
| `shared/apps/AGENTS-static.md.j2`                 | Downstream AGENTS.md template for static sites                    |
| `shared/apps/AGENTS-phoenix.md`                   | Rendered reference copy (static, checked in)                      |
| `shared/apps/AGENTS-static.md`                    | Rendered reference copy for static sites                          |
| `shared/apps/CLAUDE-phoenix.md`                   | Downstream CLAUDE.md content for Phoenix apps                     |
| `shared/apps/CLAUDE-static.md`                    | Downstream CLAUDE.md content for static sites                     |
| `shared/apps/PROJECT_CONTEXT-phoenix-template.md` | Format reference for downstream PROJECT_CONTEXT.md                |
| `shared/apps/PROJECT_CONTEXT-static-template.md`  | Format reference for static site PROJECT_CONTEXT.md               |
| `codegen-scaffold`                                | Top-level launcher — selects stack, delegates to scaffold.sh      |

## Key Paths

```
shared/scaffold/
  phoenix/
    scaffold.sh
    eex_render.sh
    mutations/   ← config_exs.sh, mix_exs.sh, router.sh, endpoint.sh, ...
    templates/
  static/
    scaffold.sh
    scaffold_test.sh
shared/apps/
  AGENTS-phoenix.md{,.j2}
  AGENTS-static.md{,.j2}
  CLAUDE-phoenix.md, CLAUDE-static.md
  PROJECT_CONTEXT-phoenix-template.md
  PROJECT_CONTEXT-static-template.md
codegen-scaffold
```

## Integration Points

- **core**: `codegen-scaffold` is a core launcher with two subcommands: `codegen-scaffold create --stack=<stack> --cwd=<dir> --slug=<name>` (full scaffold) and `codegen-scaffold integrate --stack=<stack> --cwd=<dir> [--slug=<name>]` (wire symlinks only); see `context/core.md`
- **subagents**: `AGENTS-phoenix.md.j2` references subagent roles by name; changes to agent roles may require updating this template
- **rules**: `AGENTS-phoenix.md` encodes orchestrator rules for downstream apps; kept in sync with `shared/rules/roles/orchestrator.md` — see `context/rules-roles.md`
- **test-harness**: ExUnit tests in `test_harness/test/stacks/` validate scaffold output — scaffold changes require test updates; see `context/test-harness.md`
- **development**: `codegen-scaffold` is invoked via make targets — see `context/development.md` make-target index

## Update When Changing

- `shared/scaffold/` — mutation scripts, eex_render.sh, scaffold.sh entry points
- `shared/apps/` — `.j2` template files, rendered reference `.md` copies
- `shared/scaffold/<stack>/templates/` — .eex source templates

## Downstream Agent Phase Structure

`AGENTS-phoenix.md.j2` and `AGENTS-static.md.j2` define phases that guide the orchestrator through each agent cycle:

| Phase | Agent           | Role                                                                 |
| ----- | --------------- | -------------------------------------------------------------------- |
| 0     | Orchestrator    | Session start, context load                                          |
| 1     | Planner         | Planning and slicing                                                 |
| 2     | Developer       | Implementation                                                       |
| 3     | Reviewer        | Code review and approval                                             |
| 3.5   | Context-curator | Updates context files post-reviewer; provides backstop before commit |
| 4     | Committer       | Commits changes to git                                               |

**Phase 3.5 curator insertion**: When updating downstream templates due to orchestrator role changes, ensure Phase 3.5 exists between reviewer (Phase 3) and committer (Phase 4). The curator phase enforces the reviewer → curator → committer ordering. Remove any "Act now" skip logic that bypasses curator, as that breaks the ordering contract.

## Subcommand Dispatch: `create` vs `integrate`

`codegen-scaffold` has two subcommands rather than flags:

| Subcommand  | Purpose                                                | Use case                    |
| ----------- | ------------------------------------------------------ | --------------------------- |
| `create`    | Full scaffold (phx.new or static scaffold + integrate) | Initial app provisioning    |
| `integrate` | Wire symlinks + Makefile + README + .gitignore only    | Add codegen to existing app |

Both accept `--stack=<phoenix|static>` and `--cwd=<dir>`. `create` requires `--slug=<name>` and version pins; `integrate` auto-derives `--slug` from `--cwd` basename if not provided. Version pins (`--elixir-version`, `--node-version`, `--otp-version`) are stored in `codegen-scaffold` itself as single source of truth — not duplicated in mutation scripts.

The `create` path uses **transactional temp-parent + trap**: all mutations run in a temp sibling dir; if any fails, cleanup is automatic; on success, move is atomic into final position. See `codegen/rules/_core/bash-discipline.md` § Transactional Multi-Step File Creation.

## Pitfalls

- **Mutation scripts are order-sensitive** — scaffold.sh runs mutations in a defined sequence; inserting out of order can break the generated app
- **`AGENTS-*.md` vs `AGENTS-*.md.j2`** — `.j2` is the Jinja template; `.md` is the rendered reference copy checked in for human review. Both must stay in sync when changing agent roles or rules
- **`eex_render.sh` variable scope** — variables must be exported before calling `eex_render.sh`; unset vars render as empty string silently
- **Post-condition assertions** — each mutation script validates its own success (lines added, anchors found, placeholders resolved) before returning; see `codegen/rules/_core/bash-discipline.md` § Post-Condition Assertions in Mutations
- **`eex_render.sh` hard-errors on unresolved placeholders** — any leftover `<%= ... %>` in output causes non-zero exit
- **AGENTS-phoenix.md.j2 embeds orchestrator rules** — downstream app templates in `shared/apps/` carry a copy of orchestrator rules; when `orchestrator.md` (rules-roles.md) changes, update these templates too to avoid sync drift. Ensure Phase 3.5 curator always precedes Phase 4 committer. Note: there is no `CLAUDE-phoenix.md.j2` — `CLAUDE-phoenix.md` is a plain file (not a Jinja template)
- **Idempotent .gitignore updates use section markers** — repeated `integrate` runs do not duplicate codegen symlink entries in .gitignore; marker comment detects already-present section
