# Scaffold Mutations — Guard Tests, Credo Cleanup, Portable Sed

## Mutation Flag Discipline

Mutation scripts are invoked from `scaffold.sh` Phase 2 with conditional flags. Each mutation MUST only accept the flags it understands:

- `formatter_exs.sh` — accepts `--no-ecto` flag only. Passing broader `EXTRA_FLAGS` (e.g., `--with-appsignal`, `--github-url`) causes exit 1.
- Pattern: use scoped flag variables (e.g., `FORMATTER_FLAGS`) rather than forwarding the full `EXTRA_FLAGS` array.
- Wire at call site: `scaffold.sh:252` passes `formatter_exs.sh` with `--no-ecto` only when `NO_ECTO` is set, using the `FORMATTER_FLAGS[@]` idiom.

This prevents mutations from failing when they encounter unrecognized flags intended for other scripts.

## Guard Test Discovery

Bash unit tests for mutations are auto-discovered by `shared/scaffold/phoenix/run-tests.sh`, which globs `mutations/*_test.sh` (plus `eex_render_test.sh`). A NEW guard test MUST land under `mutations/` to be picked up by the `make test` gate (`Makefile:166`, `scaffold-phoenix` parallel job).

Inline `--no-ecto` cleanup blocks in `scaffold.sh` (mix.lock strip, migrate-overlay delete) are NOT bash-unit-testable because mix.lock + rel/overlays don't exist until AFTER Phase 6 phx.gen.release. Their coverage rides the slow `no_ecto_scaffold_test.exs` (`make test-stacks`), not the fast gate.

## Credo Violations Cleanup

`shared/scaffold/phoenix/mutations/credo_fix.sh` patches FIX-bucket phx.new files to pass credo checks post-generation.

### Credo Strategy: Config-Relaxation for phx.new Boilerplate

The scaffold-owned `.credo.exs` (rendered from `templates/.credo.exs.eex`) uses **file exclusions** to suppress inappropriate checks on phx.new framework-boilerplate files. This is the repo-idiomatic approach: `.credo.exs.eex` excludes `endpoint/telemetry/application/release/data_case/conn_case/channel_case` from `Specs/AliasOrder/ImportOrder/UnusedVariableNames`; the six phx.new boilerplate files extend the same lists.

**The three `_live.ex` exclusions have been removed.** LiveView modules are held to full strict Credo. The prior exclusion of `*_live.ex` from `Readability.Specs`, `Refactor.VariableRebinding`, and `Consistency.UnusedVariableNames` was a misdiagnosis:

- **`Readability.Specs`** already exempts `@impl` callbacks by design — no `@spec` is expected on `mount/3`, `handle_event/3`, etc. The churn loop was phantom.
- **`Refactor.VariableRebinding`** is satisfiable: use `then/2` pipeline pattern for socket rebinding in LiveView code, same as any other module.
- **`Consistency.UnusedVariableNames`**: the real ambiguity was which mode (`meaningful` vs `with_value` vs `prefix_only`) to enforce. Resolved by pinning `force: :meaningful` — deterministic and matches the `_view/_html` idiom used in the codebase.

With `force: :meaningful`, `UnusedVariableNames` is deterministic: variables that carry no semantic meaning (bare `_`) are allowed; variables prefixed with `_` that carry a name (e.g., `_socket`, `_params`) are treated as intentionally named. This matches the codebase idiom and avoids false-positive churn without LiveView-specific exclusions.

**Why config-exclusion, not @spec injection**: phx.new macro functions (e.g. `<app>_web.ex` router/controller/live_view helpers) return `quote do ... end` — a meaningful spec would be `Macro.t()`, which is boilerplate. Controllers (error_html, error_json, page_controller) are phx.new-owned and change per Phoenix release. Injecting @spec is version-brittle; config exclusion is stable and declarative.

**Excluded files per check** (defined in `templates/.credo.exs.eex`):

| Check                                                 | Files excluded (phx.new boilerplate)                                                                  |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `Credo.Check.Readability.Specs`                       | `_web.ex`, `page_controller.ex`, `error_html.ex`, `error_json.ex`, `core_components.ex`, `layouts.ex` |
| `Credo.Check.Readability.AliasOrder`                  | `_web.ex`                                                                                             |
| `OptimumCredo.Check.Readability.ImportOrder`          | `_web.ex`                                                                                             |
| `OptimumCredo.Check.Readability.ExtractableSpecTypes` | `page_controller.ex`, `error_html.ex`, `error_json.ex`                                                |
| `Credo.Check.Consistency.UnusedVariableNames`         | `core_components.ex` (plus `force: :meaningful` for all files)                                        |
| `Credo.Check.Refactor.VariableRebinding`              | (none — applies to all files including LiveViews)                                                     |
| `Credo.Check.Design.AliasUsage`                       | `_web.ex`, `core_components.ex`                                                                       |

`~r"_web\.ex$"` matches only `lib/<app>_web.ex` (top-level), not `lib/<app>_web/...` subdirectory files. The existing `channel_case/conn_case/data_case` anchors in each check are preserved — `data_case.sh` mutation anchors on `~r"/channel_case\.ex$"` in `ImportOrder`.

**Scope & Fixes**:

- **FIX bucket** (`credo_fix.sh` adds @moduledoc; `.credo.exs.eex` config-excludes inappropriate checks):
  - `core_components.ex`, `layouts.ex`: add @moduledoc
  - `<app>_web.ex`: add @moduledoc false
  - `page_controller.ex`, `error_html.ex`, `error_json.ex`: add @moduledoc false
- **EXCLUDE bucket** (keep in .credo.exs — irreducible framework one-liners):
  - `application.ex`, `endpoint.ex`, `release.ex`, `telemetry.ex`, `*_case.ex` family
  - Data violations (ImplTrue, Specs, ModuleDependencies) required by framework boilerplate

**Execution timing**: Runs after `data_case.sh`, before Phase 5 `mix format` (scaffold.sh L209→credo_fix→L236). Format normalises whitespace after ordering edits.

**Template rendering note**: The `.credo.exs` file is rendered from `templates/.credo.exs.eex` via `eex_render.sh` at scaffold time (scaffold.sh L185), not baked into agent prompts by `make install`. This means `.credo.exs.eex` changes take effect immediately in newly-scaffolded apps without requiring a `make install` regeneration cycle — contrast with shared rule files (`shared/rules/`), which must be regenerated into agent prompts via `make install` before agents see them.

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

## Router Mutation — PageController Route Stripping

Phoenix's default `mix phx.new` (no `--no-html`) generates:

- `lib/<app>_web/controllers/page_controller.ex`
- `lib/<app>_web/components/page_html.ex`
- `lib/<app>_web/router.ex` with route: `get "/", PageController, :home`

The scaffold mutations delete the first two files unconditionally (`router.sh:223-237`). The dangling route referencing the deleted controller must also be stripped, or the compiled app fails dialyzer/typecheck on an undefined module reference.

**Implementation**: `shared/scaffold/phoenix/mutations/router.sh` deletes any `get "/", PageController, :home` root route in the same block that inserts the `/health` endpoint (keeps one owner of router mutations). Post-condition: assert zero `PageController` route lines remain.

This is order-independent (router.sh owns all scope-"/" surgery); idempotent (grep guard skips if already stripped).

## Release Overlay Cleanup on `--no-ecto`

`mix phx.gen.release` generates `rel/overlays/bin/migrate` and `rel/overlays/bin/migrate.bat` unconditionally, even when `mix phx.new --no-ecto` was used (which omits `Release.migrate/0` from the generated releases module).

A DB-free release omits the `migrate/0` callback, making the overlay broken — invoking `/opt/app/bin/migrate` will fail at runtime. **Solution**: Delete both overlay files under `--no-ecto`. **Timing**: After Phase 6 phx.gen.release (scaffold.sh:291), inline block deletes `rel/overlays/bin/migrate*`.

This is not unit-testable in bash (overlays only exist post-phx.gen.release); coverage rides the slow no-ecto scaffold test.

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
