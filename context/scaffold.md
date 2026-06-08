# Scaffold Domain — Scaffolding for Downstream Apps

The scaffold domain produces the initial file tree for new downstream Phoenix or static-site projects. `codegen-scaffold` (top-level) delegates to `shared/scaffold/<stack>/scaffold.sh` which applies `mutations/` (bash scripts that write individual files) and `eex_render.sh` (renders `.eex` templates). The result is a runnable app with AGENTS.md, PROJECT_CONTEXT.md, and all boilerplate pre-wired for AI-agent workflows.

`shared/apps/` contains the human-readable template documents (`AGENTS-phoenix.md.j2`, `PROJECT_CONTEXT-phoenix-template.md`) used as both scaffold output and reference for new project setup.

## Trigger Keywords

scaffold.sh, eex_render, mutations, AGENTS.md.j2, PROJECT_CONTEXT.md.j2, ocg setup, codegen-scaffold, downstream app scaffolding

## Components

| File / Dir                                        | Purpose                                                                        |
| ------------------------------------------------- | ------------------------------------------------------------------------------ |
| `shared/scaffold/phoenix/scaffold.sh`             | Phoenix scaffold entry — creates new Phoenix app via mutations                 |
| `shared/scaffold/phoenix/mutations/`              | Per-file bash mutation scripts (config_exs.sh, mix_exs.sh, credo_fix.sh, etc.) |
| `shared/scaffold/phoenix/eex_render.sh`           | Renders `.eex` templates with variable substitution                            |
| `shared/scaffold/phoenix/templates/`              | `.eex` source templates for Phoenix scaffold output                            |
| `shared/scaffold/static/scaffold.sh`              | Static site scaffold entry                                                     |
| `shared/scaffold/static/scaffold_test.sh`         | Bash tests for static scaffold                                                 |
| `shared/scaffold/phoenix/README.md`               | Phoenix scaffold setup and mutation authoring guide                            |
| `shared/apps/AGENTS-phoenix.md.j2`                | Downstream AGENTS.md template (Jinja — rendered for each new app)              |
| `shared/apps/AGENTS-static.md.j2`                 | Downstream AGENTS.md template for static sites                                 |
| `shared/apps/AGENTS-phoenix.md`                   | Rendered reference copy (static, checked in)                                   |
| `shared/apps/AGENTS-static.md`                    | Rendered reference copy for static sites                                       |
| `shared/apps/CLAUDE-phoenix.md`                   | Downstream CLAUDE.md content for Phoenix apps                                  |
| `shared/apps/CLAUDE-static.md`                    | Downstream CLAUDE.md content for static sites                                  |
| `shared/apps/PROJECT_CONTEXT-phoenix-template.md` | Format reference for downstream PROJECT_CONTEXT.md                             |
| `shared/apps/PROJECT_CONTEXT-static-template.md`  | Format reference for static site PROJECT_CONTEXT.md                            |
| `codegen-scaffold`                                | Top-level launcher — selects stack, delegates to scaffold.sh                   |

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

## `--no-ecto` Post-Render Strips

After template rendering (Phase 1, before Phase 2 mutations), `scaffold.sh` strips lines that reference Ecto from generated files when `NO_ECTO` is set:

| File stripped                                    | Lines removed                                   | Reason                                                                              |
| ------------------------------------------------ | ----------------------------------------------- | ----------------------------------------------------------------------------------- |
| `Makefile`                                       | `ecto.rollback` invocation                      | No DB migrations under `--no-ecto`                                                  |
| `lib/<app>_web/controllers/health_controller.ex` | `alias Ecto.Adapters.SQL` and `SQL.query!(...)` | `mix phx.new --no-ecto` generates no `Repo` module; Ecto refs cause compile failure |

Both strips use the portable `grep | temp-file | mv` idiom (not `sed -i`). Each has a post-condition assertion that fails loud if any targeted lines remain after the strip.

### HealthController Route in Router

The `shared/scaffold/phoenix/mutations/router.sh` mutation wires the health check endpoint into the router. Prior to the bug-fix session, the route string included an unnecessary module prefix: `${APP_NAME_MODULE}Web.HealthController`. This was aliased away by default Phoenix router scope configuration, making it overly verbose.

Fixed: **bare `HealthController`** (drop `${APP_NAME_MODULE}Web.` prefix) — the router scope already provides the alias, so the full path is redundant. The idempotency guard (`grep -qF 'HealthController'`) still matches the bare form.

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

## Flags & Capabilities

### Command-line Flags (codegen-scaffold create)

| Flag                        | Purpose                                                  | Default |
| --------------------------- | -------------------------------------------------------- | ------- |
| `--stack=<phoenix\|static>` | Target stack                                             | (req)   |
| `--cwd=<dir>`               | Scaffold parent directory                                | (req)   |
| `--slug=<name>`             | App name (create only)                                   | (req)   |
| `--no-ecto`                 | Omit Ecto dependency; skip DB pieces (migrations, tests) | false   |
| `--with-appsignal`          | Include AppSignal integration (prod-only)                | false   |
| `--github-url=<full-url>`   | GitHub repository URL for source_url in mix.exs          | (none)  |

`--no-ecto`: Drops DATABASE_URL from .env, excludes Ecto from deps, removes aliases (setup ecto, ci ecto.rollback, test ecto.setup), skips DataCase, removes ecto.rollback from Makefile ci target.

`--with-appsignal`: Adds appsignal_phoenix dep (dev-only for telemetry testing); requires `APPSIGNAL_PUSH_API_KEY` env var at runtime (opt-in, not default).

`--github-url`: Populates `source_url:` line in mix.exs project() block; omitted if not supplied.

### Version Defaults (Dispatcher → Scaffold Flow)

`codegen-scaffold` maintains version pins as the single source of truth. The dispatcher (entry point) initializes version variables with empty strings, then fills them post-flag-parse with two strategies:

1. **Flag-supplied values** — if `--elixir-version`, `--node-version`, `--otp-version` flags are provided, they override defaults
2. **`mise current` fallback** — if a flag is not supplied (and the variable remains empty), `mise current <tool>` is called to resolve the current system version

This approach ensures:
- Explicit flag values are honored (developer control)
- Fresh-box scenarios without explicit flags still populate `.tool-versions.eex` with sensible defaults from the system's current mise environment
- No hardcoded version fallbacks that could drift from reality

Flow: dispatcher version vars → `scaffold.sh` `render` args (L159-161) → `.tool-versions.eex` template substitution.

### First-Run Activation (Classes B & B2)

After scaffold creates the directory tree, `scaffold.sh` automatically:

1. Runs `mise trust` on the generated app's `.mise.toml` (mirrors guarded form in install.sh:595)
2. Renders `.env` with generated `SECRET_KEY_BASE`, `DATABASE_URL` (unless `--no-ecto`), `PHX_HOST`, `PORT`
3. Runs `mix deps.get && mix format` (bootstrap + formatting)
4. Runs `mix setup && mix compile --warnings-as-errors` (self-validation; exits non-zero on compile warnings)
5. Creates initial git commit (`git add -A && git commit -m "Initial commit"`) — commit rides atomic mv; failure aborts scaffold
6. Prints readiness summary to stdout

If any step fails, the trap cleanup (activated at temp-parent assignment) wipes the partial directory and returns non-zero.

### New Templates (codegen 0.5+)

| Template                     | Purpose                                                                      |
| ---------------------------- | ---------------------------------------------------------------------------- |
| `.env.eex`                   | (NEW) Environment overrides: SECRET_KEY_BASE, DATABASE_URL, PHX_HOST, PORT   |
| `.env.sample.eex`            | Populated with placeholder description (previously empty)                    |
| `.env.prod.sample.eex`       | SECRET_KEY_BASE replaced with placeholder (was hardcoded)                    |
| `.claude/gate-config.sh.eex` | (NEW) Per-app instance of gate-control wrapper (dev-port derivation)         |
| `.mcp.json.eex`              | (NEW) Claude MCP config for tidewave mcp-proxy (port from codegen templates) |
| `coveralls.json.eex`         | Updated: minimum_coverage 0 → 35.1 (line 3)                                  |
| `Makefile.eex`               | Gate targets + delegating stubs: gate-status, gate-kill, gate-logs           |

### Machine-Global PLT Cache (B3 — Dormant until full `make ci`)

`scaffold.sh` (lines ~340) initializes a machine-global Dialyzer PLT cache helper:

- Location: `~/.cache/codegen-plt/<otp>-<elixir>-<lockhash>/`
- On first hit: generated app's `.mix_dialyzer_plt/` is populated from cache
- On cache miss: Dialyzer builds the PLT; cache is saved for future runs
- Status: **Dormant** — dialyzer only runs under full `make ci`, which is gated behind credo-clean landing. The lock commit + cache infrastructure is in place; the reuse path activates once full `make ci` is enabled.

### Optimum Templates Submodule

`scaffold.sh` (B5) conditionally adds the optimum_templates submodule:

```bash
git submodule add https://github.com/optimumBA/optimum_templates priv/templates || \
  echo "WARN: git submodule add offline or failed" >&2
```

Non-fatal: warns on offline/failure but does not abort scaffold. Submodule is optional.

### Releases Always-On

`scaffold.sh` (C5) generates release artifacts:

```bash
( cd "$TARGET_DIR" && mix phx.gen.release )
```

Patch `rel/overlays/bin/server` to set `APP_REVISION` env var (reads from `git describe --tags --always`).

### Dependencies & Versions

| Dep               | Version  | Notes                                             |
| ----------------- | -------- | ------------------------------------------------- |
| optimum_credo     | ~> 0.4   | Upgraded 0.3 → 0.4 (adds LiveViewBareMatch check) |
| appsignal_phoenix | (opt-in) | Only if `--with-appsignal` supplied               |

### Fixture Regeneration (B4 — Gate-Affecting)

The fixture `test_harness/mutations/fixtures/phx_new_skeleton/` must stay in sync with live `mix phx.new` output. B4 regeneration:

1. Run `mix phx.new fixture_app --binary-id --no-mailer --no-dashboard --no-agents-md --no-version-check` in a temp directory
2. Prune to only files the fixture needs: `mix.exs`, `.formatter.exs`, `config/config.exs`, `lib/*_web/{router,endpoint,telemetry}.ex`
3. Re-verify every mutation anchor (grep patterns) against regenerated content
4. Delete dead mutation scripts (config_exs.sh, prod_exs.sh, mix_exs Step 1) — grep-confirmed guarded no-ops
5. Run `shared/scaffold/phoenix/run-tests.sh` to completion (all mutation tests pass against new fixture)

**Gate impact**: Fixture changes perturb `make test` (mutation unit tests run vs this fixture via Makefile:123). Highest gate risk if fixture drifts.

## Credo Violations Cleanup (New)

`shared/scaffold/phoenix/mutations/credo_fix.sh` patches FIX-bucket phx.new files to pass credo checks post-generation:

**Scope & Fixes**:

- **FIX bucket** (mutation adds @moduledoc/@spec, fixes ordering; removes from .credo.exs exclusions):
  - `core_components.ex`, `layouts.ex`: add @moduledoc + @spec
  - `<app>_web.ex`: fix alias/import order
  - `page_controller.ex`, `error_html.ex`, `error_json.ex`: add @moduledoc + @spec
- **EXCLUDE bucket** (keep in .credo.exs — irreducible framework one-liners):
  - `application.ex`, `endpoint.ex`, `release.ex`, `telemetry.ex`, `*_case.ex` family
  - Data violations (ImplTrue, Specs, ModuleDependencies) required by framework boilerplate

**Execution timing**: Runs after `data_case.sh`, before Phase 5 `mix format` (scaffold.sh L209→credo_fix→L236). Format normalises whitespace after ordering edits.

**Module ordering rule** (from `shared/recipes/elixir-module-organization-skeleton.md`): `@moduledoc` ALWAYS AFTER `defmodule ... do` and BEFORE `use` — StrictModuleLayout requires `[:shortdoc, :moduledoc, :use, ...]` order.

**Fixture coverage**: `test_harness/mutations/fixtures/phx_new_skeleton/` includes FIX-bucket files at phx.new 1.8 paths:

- `lib/<app>_web.ex`
- `lib/<app>_web/components/{core_components,layouts}.ex`
- `lib/<app>_web/controllers/{page_controller,error_html,error_json}.ex`

See credo_fix_test.sh for idempotency assertions.

### Credo Fix Guard Pattern

`credo_fix.sh` uses **paired guards** for each file injection:
- **PRE-injection guard** (wraps the `python3` heredoc): `grep -q '@moduledoc'` — skips injection if ANY moduledoc already exists (matches both custom doc strings and `@moduledoc false` from phx.new). Broadened to presence-check only (was string-specific).
- **POST-condition guard** (after injection): exact string match on the target moduledoc value (e.g., `'@moduledoc false'`) — validates correct injection. Remains untouched (correct logic).

Both pairs appear in credo_fix.sh at L45/82/124/161/221/278 (PRE) and L71/108/150/210/267/324 (POST). Only PRE guards were broadened during bug-fix; POST guards continue exact-match validation.

### Mise Trust After Move

`mise trust` records are keyed to the config file's **absolute path**. When `codegen-scaffold` uses atomic `mv` to move the app from a temp parent dir to the final location, the trust record recorded against the temp path becomes stale. Re-trust after the move is required:

```bash
# After: mv "$TEMP_PARENT/$SLUG" "$target_dir"
mise trust "$target_dir/.mise.toml" ... || true
```

Non-fatal: `|| true` allows fresh-box scenarios where mise is not yet configured globally. Essential for clean `mise install` on the generated app's first run.

## Portable Sed Idiom (Class A)

All sed rewrites in mutation scripts use **temp-file rewrite**, never `sed -i ''`:

```bash
sed "s|old|new|" "$FILE" >"${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"
```

- **Why**: `sed -i ''` (BSD macOS) is not portable to GNU sed (Linux). Temp-file idiom works on both.
- **Idempotency**: Pairs well with `cmp -s` checks in mutation assertions; if output is byte-identical, the mv is skipped.
- **Reference**: `install.sh` lines 474–483 (mktemp/cmp/mv pattern) is the canonical portable-file-edit reference.

### Post-Render Line Strips (Class B)

When a post-render strip operation (e.g., removing Ecto-related lines under `--no-ecto`) must remove lines matching a pattern and write the result, use **two separate statements** — not a chained `&&`:

```bash
# CORRECT: separate statements
grep -v "pattern" "$FILE" >"${FILE}.tmp"
mv "${FILE}.tmp" "$FILE"

# WRONG: chained &&, causes abort if grep matches all lines
grep -v "pattern" "$FILE" >"${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"
```

**Why**: When `grep -v` matches ALL lines (removes everything), it exits 1 (zero matches remaining). Under `set -e`, the chained `&&` aborts before `mv` runs, leaving the original file intact but aborting the script. Separate statements ensure: if `grep` fails, `set -e` aborts before `mv` touches anything; if `grep` succeeds OR exits non-zero on zero matches, `mv` attempts regardless (and may operate on an empty temp file, which is the desired outcome).

**Post-condition assertion**: Always verify the strip succeeded:

```bash
if grep -qF "stripped-pattern" "$FILE"; then
    echo "[scaffold.sh] ERROR: post-render strip failed — pattern still present" >&2
    exit 1
fi
```

**Cosmetic whitespace artifact**: Post-render strips may leave blank lines where lines were removed (e.g., health_controller.ex Ecto imports). This is harmless (Elixir tolerates blank lines) but cosmetic. The trade-off avoids conditionalizing per-line removal logic in `.eex` templates; templates remain readable, and `mix format` runs at startup (scaffold.sh L131) to normalize output before LLM sees it.

**Reference implementations**:

- Makefile `ecto.rollback` strip: scaffold.sh:187-189
- Health controller Ecto imports strip: scaffold.sh:196-201

## Pitfalls

- **Mutation scripts are order-sensitive** — scaffold.sh runs mutations in a defined sequence; inserting out of order can break the generated app
- **`AGENTS-*.md` vs `AGENTS-*.md.j2`** — `.j2` is the Jinja template; `.md` is the rendered reference copy checked in for human review. Both must stay in sync when changing agent roles or rules
- **`eex_render.sh` variable scope** — variables must be exported before calling `eex_render.sh`; unset vars render as empty string silently
- **Post-condition assertions** — each mutation script validates its own success (lines added, anchors found, placeholders resolved) before returning; see `codegen/rules/_core/bash-discipline.md` § Post-Condition Assertions in Mutations
- **`eex_render.sh` hard-errors on unresolved placeholders** — any leftover `<%= ... %>` in output causes non-zero exit
- **AGENTS-phoenix.md.j2 embeds orchestrator rules** — downstream app templates in `shared/apps/` carry a copy of orchestrator rules; when `orchestrator.md` (rules-roles.md) changes, update these templates too to avoid sync drift. Ensure Phase 3.5 curator always precedes Phase 4 committer. Note: there is no `CLAUDE-phoenix.md.j2` — `CLAUDE-phoenix.md` is a plain file (not a Jinja template)
- **Idempotent .gitignore updates use section markers** — repeated `integrate` runs do not duplicate codegen symlink entries in .gitignore; marker comment detects already-present section
- **Post-condition anchor drift** — after B4 fixture regeneration, re-verify every mutation's `grep -qF` anchor; mutations with drifted anchors will silently skip during tests (idempotency guard matches but post-condition fails). Always pair idempotency guard + post-condition on the same anchor.
- **Fixture regeneration breaks make test** — B4 fixture regen is gate-affecting; fixture file changes → mutation unit tests run against new content. Re-run `shared/scaffold/phoenix/run-tests.sh` after any regen to catch anchor drift or mutation failures.
