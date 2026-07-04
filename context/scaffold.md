# Scaffold Domain — Scaffolding for Downstream Apps

The scaffold domain produces the initial file tree for new downstream Phoenix or static-site projects. `codegen-scaffold` (top-level) delegates to `shared/scaffold/<stack>/scaffold.sh` which applies `mutations/` (bash scripts that write individual files) and `eex_render.sh` (renders `.eex` templates). The result is a runnable app with AGENTS.md, PROJECT_CONTEXT.md, and all boilerplate pre-wired for AI-agent workflows.

`shared/apps/` contains the human-readable template documents (`AGENTS-phoenix.md.j2`, `PROJECT_CONTEXT-phoenix-template.md`) used as both scaffold output and reference for new project setup.

## Trigger Keywords

scaffold.sh, eex_render, mutations, AGENTS.md.j2, PROJECT_CONTEXT.md.j2, ocg setup, codegen-scaffold, downstream app scaffolding, static SEO baseline, vite publicDir, robots.txt

## Components

| File / Dir                                        | Purpose                                                                        |
| ------------------------------------------------- | ------------------------------------------------------------------------------ |
| `shared/scaffold/phoenix/scaffold.sh`             | Phoenix scaffold entry — creates new Phoenix app via mutations                 |
| `shared/scaffold/phoenix/mutations/`              | Per-file bash mutation scripts (config_exs.sh, mix_exs.sh, credo_fix.sh, etc.) |
| `shared/scaffold/phoenix/eex_render.sh`           | Renders `.eex` templates with variable substitution                            |
| `shared/scaffold/phoenix/scaffold_cache.sh`       | Machine-global scaffold cache (deps/\_build/PLT reuse); sourced by scaffold.sh |
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
  restart_server.sh.eex  ← NEW: generic restart template
  usage_rules_INDEX.md   ← NEW: phoenix-only dep index
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
- **rules**: `AGENTS-phoenix.md` encodes the downstream-app session loop (self-orchestration fallback for interactive/resumable sessions only; non-interactive builds use the deterministic `OrchestrationLoop`) — see `context/rules-roles.md` and `context/test-harness.md`
- **test-harness**: ExUnit tests in `test_harness/test/stacks/` validate scaffold output — scaffold changes require test updates; see `context/test-harness.md`
- **development**: `codegen-scaffold` is invoked via make targets — see `context/development.md` make-target index

## Mix Aliases & Compile Ordering

Mix aliases in `shared/scaffold/phoenix/templates/aliases.txt.eex` define the `setup`, `assets.build`, and `assets.deploy` targets. **Critical**: both `assets.build` and `assets.deploy` aliases MUST include `"compile"` as the first element:

```elixir
"assets.build": ["compile", "cmd npm run build --prefix assets"],
"assets.deploy": ["compile", "cmd npm run deploy --prefix assets"],
```

**Why**: esbuild processes imports like `import { Phoenix } from 'phoenix_live_view'` — but the `phoenix-colocated` import in the generated app's `app.js` is not installed until `mix compile` runs. Without compile-first, esbuild fails to resolve the import. This is guarded by `assert_assets_deploy!/1` in the test harness (session 20260610\_\* wired it into `no_ecto_scaffold_test.exs`).

The `--no-ecto` post-render strip (`scaffold.sh` lines 187-201) must NOT remove these aliases — it only removes `"ecto."` prefix lines and rewrites the `test:` alias to `["test"]` (single element, no Ecto prefix). `mix_exs.sh` enforces this with a Python transform, not blanket `grep -v`.

## Stack-Specific Implementation Details

**Phoenix vs Static variable naming**: Phoenix `scaffold.sh` uses `$TARGET_DIR` throughout (the final app directory); Static `scaffold.sh` uses `$CWD` (the current working directory). When authoring loops or directory operations for static scaffold, use loop-variable names like `_d` to avoid collision with globally-expected names (phoenix's `TARGET_DIR` pattern). Both approaches work; the distinction reflects historical stack porting and must be preserved for stack consistency — do not unify to one pattern across both stacks in a single commit without explicit stack-parity acceptance.

**Gitkeep vs keep files**: Both `.gitkeep` and `.keep` are valid gitignore-boundary markers in lifecycle directories (`codegen/pitches/{draft,ready,shipped}`). Existing asset dirs use `.keep`; newly-added lifecycle dirs use `.gitkeep` for clarity of purpose. No need to homogenize across the project — either is acceptable.

## Static Stack — Vite Scaffold

**Vanilla Vite by default**: The static stack scaffold emits a minimal Vite project without any framework. Framework opt-in (React/Vue/Svelte) is added only when the planner explicitly calls for it (documented in `shared/recipes/static-vite-scaffold.md` as an add-on). Scaffold logic is deterministic: files written directly via `cat >` / `printf` (never `npm create vite` — interactive hang). Output must be prettier-clean (2-space JSON indent, LF line endings) to pass `npm run build && npx prettier --check .` in the downstream `make ci` gate.

**Key files and config**:

- `vite.config.js`: sets `build: { outDir: "public" }` + `publicDir: "static"` (copies static/\* to public/ at build) + `@tailwindcss/vite` plugin (Tailwind v4)
- `package.json`: scripts `build: "vite build"`, `serve: "vite build && python3 -u -m http.server --directory public 0"`, `dev: "vite"` + `"type": "module"` + devDeps `vite`, `@tailwindcss/vite`, `tailwindcss`
- `index.html` (root): `<head>` carries SEO baseline by default — `<meta name="description">`, four `og:*` tags (title/description/type/image), `<link rel="canonical">`, one `<script type="application/ld+json">` WebSite block; all absolute-URL fields use the literal `SITE_URL_PLACEHOLDER` host (patched post-build by the platform); `<script type="module" src="/src/main.js">` + app name + `<div id="app">` container
- `static/robots.txt`: written by scaffold with `User-agent: * / Allow: /` template; copied to public/ via vite's `publicDir: "static"` at build
- src/main.js: ES module entry that imports ./style.css
- `src/style.css`: `@import "tailwindcss";` (Tailwind v4 directive)
- `run_integrate_stage` appends to `.gitignore`: `/node_modules/`, `/public/`, marker blocks for `current`, `public-*`, `.DS_Store`, `/package-lock.json`

**Serve invariant**: The `static-site-build-check.sh` hook expects the `serve` script to end with the literal regex `python3 -u -m http\.server --directory public 0$` (exact tail match). Any deviation breaks the downstream gate.

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

## Idempotency Testing Pattern

When extending scaffold injection (e.g., adding new recipe lines to a Makefile target), idempotency tests use `grep -c` to count key substrings. **Safe injection**: new lines must NOT contain any substring that existing count-asserts are monitoring. Example: `scaffold_test.sh` block (y) idempotency test counts occurrences of `npm run build` and `npx prettier --check .` via `grep -c`. A new guard line `@[ -d node_modules ] || mise exec -- npm install` is safe because it carries neither substring, so existing count assertions stay green (both return 1). New test assertions covering the added line are added to block (x) without disturbing block (y) counts.

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

| Subcommand  | Purpose                                                | Use case                                                        |
| ----------- | ------------------------------------------------------ | --------------------------------------------------------------- |
| `create`    | Full scaffold (phx.new or static scaffold + integrate) | Initial app provisioning                                        |
| `integrate` | Wire symlinks + Makefile + README + .gitignore only    | Add codegen to existing app; skipped when codegen builds itself |

Both accept `--stack=<phoenix|static>` and `--cwd=<dir>`. `create` requires `--slug=<name>` and version pins; `integrate` auto-derives `--slug` from `--cwd` basename if not provided. Version pins (`--elixir-version`, `--node-version`, `--otp-version`) are stored in `codegen-scaffold` itself as single source of truth — not duplicated in mutation scripts.

The `create` path uses **transactional temp-parent + trap**: all mutations run in a temp sibling dir; if any fails, cleanup is automatic; on success, move is atomic into final position. See `codegen/rules/_core/bash-discipline.md` § Transactional Multi-Step File Creation.

### Git Ownership & Rendering Order (codegen 0.6+)

Since `scaffold-codegen-side` pitch (`codegen/pitches/`), **single-commit pattern** for both stacks:

1. Stack-specific scaffold.sh runs (phx.new for Phoenix; inline heredocs for static)
2. `codegen-scaffold run_integrate_stage` renders cross-stack files (PROJECT_CONTEXT, restart_server.sh, usage_rules_INDEX)
3. **Single `git add -A && git commit -m "Initial commit"`** in `codegen-scaffold do_create` AFTER integrate-stage, BEFORE atomic mv
4. Static gets `git init` (first-time only); Phoenix phx.new pre-initializes

Why this order: PROJECT_CONTEXT + restart + usage_rules_INDEX render in integrate-stage → must be committed by a single commit point that captures all integrate-stage writes for both stacks. Prior: Phoenix committed inside its scaffold.sh Phase 8 → dirty-tree race when integrate-stage files (PROJECT_CONTEXT) were written AFTER the phoenix commit. Single commit in codegen-scaffold eliminates the race and satisfies the clean-tree invariant.

`--restart-rpc-cmd` flag threads through codegen-scaffold → run_integrate_stage → restart_server.sh.eex render. Absent → restart script has local-dev branch only (no platform branch).

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

`--no-ecto`: Drops DATABASE_URL from .env, excludes Ecto from deps, condionalizes aliases (setup/ecto elements removed; test: alias rewritten to ["test"] instead of deleted), skips DataCase, removes ecto.rollback from Makefile ci target.

**Critical**: The `test:` alias is load-bearing for Ecto TEST DB bootstrap — it runs `ecto.create --quiet` + migrations before tests. Under `--no-ecto`, this alias MUST survive but rewritten to the empty form `["test"]` (single-element list). Deleting it loses the bootstrap for Ecto apps. See mix_exs.sh --no-ecto branch for implementation (Python transform, not blanket grep -v).

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

1. Runs `mise trust` on the generated app's `.mise.toml` (mirrors the guarded `mise trust` block in `install.sh`, search `mise trust`)
2. Renders `.env` with generated `SECRET_KEY_BASE`, `DATABASE_URL` (unless `--no-ecto`), `PHX_HOST`, `PORT`
3. Runs `mix deps.get && mix format` (bootstrap + formatting)
4. Runs `mix setup` (dependency install + aliases bootstrap)
5. **Phase 7: Self-Check & Formatting**
   - Runs `npx prettier --write .` on generated root files (must run AFTER mix setup — setup installs prettier plugin)
   - Runs conditional `make ci` (Ecto apps only; skipped under `--no-ecto`) → full CI gate validates generated app structure
   - If `make ci` fails, scaffold hard-fails (do not swallow); developer fixes scaffold templates/mutations and re-runs
6. Creates initial git commit (`git add -A && git commit -m "Initial commit"`) — commit rides atomic mv; failure aborts scaffold
7. Prints readiness summary to stdout

If any step fails, the trap cleanup (activated at temp-parent assignment) wipes the partial directory and returns non-zero.

**scaffold.sh self-clean EXIT trap**: `scaffold.sh` installs a `SCAFFOLD_OK`-guarded EXIT trap immediately after `mix phx.new` completes, BEFORE Phase 1. The trap removes `$TARGET_DIR` on any non-zero exit if `SCAFFOLD_OK` is still empty. `SCAFFOLD_OK` is set to `"1"` only after the Phase-8 git commit succeeds — any failure in Phase 1–8 triggers cleanup. This provides defense-in-depth for bare `scaffold.sh` invocations (no outer `codegen-scaffold` trap). On the normal `codegen-scaffold` path, both traps fire: scaffold.sh removes `$TEMP_PARENT/$SLUG`, then codegen-scaffold removes `$TEMP_PARENT`. SIGKILL is the only uncovered case (accepted). The trap is installed AFTER the pre-existing-dir guard so that guard's `exit 1` never deletes a pre-existing user directory.

**Phase 7 ordering constraint**: prettier-write MUST execute after `mix setup` (setup installs the prettier plugin). The generated Makefile's `ci:` target runs `npx prettier -c .` — unformatted root files will fail the check. Prettier-write precedes `make ci` to ensure formatted output before the ci gate runs.

### New Templates (codegen 0.5+)

| Template                     | Purpose                                                                                                                            |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `.env.eex`                   | (NEW) Environment overrides: SECRET_KEY_BASE, DATABASE_URL, PHX_HOST, PORT                                                         |
| `.env.sample.eex`            | Populated with placeholder description (previously empty)                                                                          |
| `.env.prod.sample.eex`       | SECRET_KEY_BASE replaced with placeholder (was hardcoded)                                                                          |
| `.claude/gate-config.sh.eex` | (NEW) Per-app instance of gate-control wrapper (dev-port derivation)                                                               |
| `.mcp.json.eex`              | (NEW) Claude MCP config for tidewave mcp-proxy (port from codegen templates)                                                       |
| `coveralls.json.eex`         | Updated: minimum_coverage set to 30.0 (fresh phx.new boilerplate ~33.7%; no ratchet — downstream teams may regress and still pass) |
| `Makefile.eex`               | Gate targets + delegating stubs: gate-status, gate-kill, gate-logs                                                                 |

### Machine-Global Scaffold Cache

`shared/scaffold/phoenix/scaffold_cache.sh` (sourced by `scaffold.sh`) implements a transparent, machine-global cache for the Phoenix scaffold path so repeated same-toolchain+lockfile `codegen-scaffold create --stack=phoenix` runs skip the expensive deps-compile + Dialyzer PLT-build steps.

- **Location**: `${XDG_CACHE_HOME:-$HOME/.cache}/codegen-scaffold/<key>/` — standard XDG cache dir, no new env var.
- **Key**: `<otp>-<elixir>-<sha256(mix.lock)>` — `$OTP_VERSION`/`$ELIXIR_VERSION` scaffold vars (not a runtime `elixir --version` probe) + a sha256 hash of the generated app's `mix.lock` (`sha256sum` on Linux, `shasum -a 256` fallback on macOS). Computable only once `mix.lock` exists (after `mix phx.new` + mutations, before Phase 5's `mix deps.get`); absent lockfile → key not computable → cold run.
- **Three cached layers**: (1) `deps/` + `_build/*/lib/<dep>` for hex deps only — every `_build/*/` env dir (dev, test, …) is globbed, but the app's own `_build/*/lib/<app_name>` is NEVER cached; (2) `priv/plts/dialyzer.plt`; (3) population-on-miss after a successful `make ci`.
- **`make ci` stays unconditional** — dialyzer always runs; the cache never gates or skips it, it only pre-seeds inputs.
- **Restore** (Phase 5, before `mix deps.get`): on a hit, `cp -R` copies the three layers into the target dir; `deps.get`/`mix setup` still run unconditionally afterward (cheap no-ops when already warm; they validate the lock and catch drift).
- **Self-heal on a warm-run failure**: if `make ci` fails on a restored (hit) run, `scaffold.sh` purges the restored `deps/`, `_build/`, and `priv/plts/dialyzer.plt`, writes a `disabled` sentinel into `<root>/<key>/`, and re-runs the full cold path (`deps.get` → `setup` → `prettier` → `make ci`). A cold-run `make ci` failure stays fatal — it signals a real template/mutation bug, not a cache problem.
- **Disable sentinel**: `<root>/<key>/disabled` blocks BOTH restore and save for that key; only an operator manually deleting the entry clears it.
- **Save**: best-effort and atomic — writes to a temp dir (`<root>/<key>.tmp.$$`), then `mv`s into place; runs only after a cold miss's successful `make ci` (skipped on hit/disabled). On an unwritable cache root or disk-full, it warns on stderr (`WARN: scaffold cache save failed — next scaffold will be cold`) and returns 0 — it never fails the scaffold.
- **Readiness summary** line (one of): `Cache: hit (key <short>)`, `Cache: miss — populated`, `Cache: miss — save failed`, `Cache: disabled (key <short>) — cold`.
- **No auto-eviction** — the cache grows unboundedly across toolchain/lockfile combinations; pruning stale entries under `<root>/` is a manual operator task, accepted as a known caveat.

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
2. Prune to only files the fixture needs: `mix.exs`, `.formatter.exs`, config/config.exs, `lib/*_web/{router,endpoint,telemetry}.ex`
3. Re-verify every mutation anchor (grep patterns) against regenerated content
4. Delete dead mutation scripts (config_exs.sh, prod_exs.sh, mix_exs Step 1) — grep-confirmed guarded no-ops
5. Run `shared/scaffold/phoenix/run-tests.sh` to completion (all mutation tests pass against new fixture)

**Gate impact**: Fixture changes perturb `make test` (mutation unit tests run vs this fixture via Makefile:123). Highest gate risk if fixture drifts.

Mutation scripts, guard-test discovery, fixture regeneration, credo cleanup, portable-sed idiom: → see `context/scaffold-mutations.md`.
