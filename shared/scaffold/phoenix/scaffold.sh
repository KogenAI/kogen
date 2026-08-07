#!/usr/bin/env bash
# scaffold.sh — Phoenix app scaffold entrypoint.
# Runs phx.new, renders 14 templates, runs 9 mutation scripts.
#
# Usage: scaffold.sh <app_name> <target_dir> [flags]
#   app_name    snake_case slug (e.g. my-app or my_app; hyphens normalised to underscores)
#   target_dir  absolute path where the scaffolded app will live after this script runs.
#               scaffold.sh derives the parent directory and runs `mix phx.new <app_name>`
#               from there, producing <target_dir> as output.
#               PRE-CONDITION: <target_dir> must NOT exist — mix phx.new refuses to scaffold
#               into an existing directory. Remove it first if re-running.
#
# Standalone shell usage:
#   scaffold.sh my_app /tmp/my_app && cd /tmp/my_app && mix deps.get && mix phx.server
#
# Caller usage: the caller invokes this script once and lets it own the full scaffold.
#   The caller must NOT pre-run mix phx.new — scaffold.sh owns that step.
#
# Flags:
#   --elixir-version <v>   default: 1.19.5
#   --node-version <v>     default: 24.14.0
#   --otp-version <v>      default: 28.4.1
#   --no-ecto              skip Ecto/DB setup
#   --with-appsignal       add AppSignal monitoring
#   --github-url <url>     set source_url in mix.exs
#   -- <phx.new flags>     raw passthrough, appended AFTER codegen's own phx.new
#                          defaults (last-wins). --database <db> is additionally
#                          captured to pick the right .env DB var (DATABASE_URL
#                          vs sqlite3's DATABASE_PATH).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
MUTATIONS_DIR="$SCRIPT_DIR/mutations"
RENDER_SH="$SCRIPT_DIR/eex_render.sh"

# shellcheck source=./scaffold_cache.sh
source "$SCRIPT_DIR/scaffold_cache.sh"

# Machine-global scaffold cache state (module scope; populated in Phase 5).
CACHE_STATUS=""
CACHE_KEY_SHORT=""
CACHE_ROOT="$(scaffold_cache_root)"
CACHE_KEY=""

# Parse positional and flag args
# Note: version defaults are NOT set here — callers (codegen-scaffold) always pass them explicitly.
ELIXIR_VERSION=""
NODE_VERSION=""
OTP_VERSION=""
NO_ECTO=""
WITH_APPSIGNAL=""
GITHUB_URL=""
PHX_PASSTHROUGH_DATABASE=""
PHX_PASSTHROUGH_FLAGS=()

APP_NAME=""
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    --elixir-version)
        ELIXIR_VERSION="$2"
        shift 2
        ;;
    --node-version)
        NODE_VERSION="$2"
        shift 2
        ;;
    --otp-version)
        OTP_VERSION="$2"
        shift 2
        ;;
    --no-ecto)
        NO_ECTO="1"
        shift
        ;;
    --with-appsignal)
        WITH_APPSIGNAL="1"
        shift
        ;;
    --github-url)
        GITHUB_URL="$2"
        shift 2
        ;;
    --)
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
            --database=*)
                PHX_PASSTHROUGH_DATABASE="${1#--database=}"
                PHX_PASSTHROUGH_FLAGS+=("$1")
                shift
                ;;
            --database)
                PHX_PASSTHROUGH_DATABASE="${2:-}"
                PHX_PASSTHROUGH_FLAGS+=("$1" "${2:-}")
                shift 2
                ;;
            *)
                PHX_PASSTHROUGH_FLAGS+=("$1")
                shift
                ;;
            esac
        done
        ;;
    -*)
        echo "[scaffold.sh] Unknown flag: $1" >&2
        exit 1
        ;;
    *)
        if [ -z "$APP_NAME" ]; then
            APP_NAME="$1"
        elif [ -z "$TARGET_DIR" ]; then
            TARGET_DIR="$1"
        else
            echo "[scaffold.sh] Unexpected argument: $1" >&2
            exit 1
        fi
        shift
        ;;
    esac
done

if [ -z "$APP_NAME" ] || [ -z "$TARGET_DIR" ]; then
    echo "Usage: scaffold.sh <app_name> <target_dir> [--elixir-version <v>] [--node-version <v>] [--otp-version <v>]" >&2
    exit 1
fi

# Normalise app_name: hyphens → underscores
APP_NAME="${APP_NAME//-/_}"

# Derive CamelCase module name (MyApp from my_app)
APP_NAME_MODULE="$(python3 -c "print(''.join(w.capitalize() for w in '$APP_NAME'.split('_')))")"

# Derive OTP major version (28 from 28.4.1)
OTP_MAJOR_VERSION="${OTP_VERSION%%.*}"

PARENT_DIR="$(dirname "$TARGET_DIR")"
SLUG="$(basename "$TARGET_DIR")"

echo "[scaffold.sh] app_name=$APP_NAME module=$APP_NAME_MODULE target=$TARGET_DIR"

if [ -d "$TARGET_DIR" ]; then
    echo "[scaffold.sh] ERROR: target_dir already exists: $TARGET_DIR (mix phx.new would refuse — remove it first)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 0: run mix phx.new
# ---------------------------------------------------------------------------
echo "[scaffold.sh] running mix phx.new $SLUG..."
mkdir -p "$PARENT_DIR"
PHX_NEW_FLAGS=(
    --app "$APP_NAME"
    --module "$APP_NAME_MODULE"
    --binary-id
    --no-mailer
    --no-dashboard
    --no-agents-md
    --no-version-check
    --install
)
[[ -n "$NO_ECTO" ]] && PHX_NEW_FLAGS+=(--no-ecto)
if [[ ${#PHX_PASSTHROUGH_FLAGS[@]} -gt 0 ]]; then
    PHX_NEW_FLAGS+=("${PHX_PASSTHROUGH_FLAGS[@]}")
fi
(cd "$PARENT_DIR" && mix phx.new "$SLUG" "${PHX_NEW_FLAGS[@]}")
echo "[scaffold.sh] mix phx.new complete"

# Guard that controls the EXIT trap below: empty = scaffold incomplete (clean up);
# set to "1" after Phase 8 (scaffold complete) = keep dir.
SCAFFOLD_OK=""
cleanup_partial() {
    if [[ -z "$SCAFFOLD_OK" && -n "${TARGET_DIR:-}" && -d "$TARGET_DIR" ]]; then
        echo "[scaffold.sh] cleanup: removing partial target $TARGET_DIR (non-zero exit)" >&2
        rm -rf "$TARGET_DIR"
    fi
}
trap cleanup_partial EXIT

# ---------------------------------------------------------------------------
# Phase 1: render standalone templates
# ---------------------------------------------------------------------------
echo "[scaffold.sh] rendering templates..."

# DB adapter drives which env var the generated app's own runtime.exs reads:
# postgres/mysql/mssql read DATABASE_URL; sqlite3 reads DATABASE_PATH (its
# config/dev.exs uses a filesystem path, not a connection URL). Default
# postgres matches codegen's prior fixed --binary-id / no --database flag.
DB_ADAPTER="${PHX_PASSTHROUGH_DATABASE:-postgres}"
if [[ "$DB_ADAPTER" == "sqlite3" ]]; then
    DB_ENV_LINE_DEV="DATABASE_PATH=${APP_NAME}_dev.db"
    DB_ENV_LINE_PROD="DATABASE_PATH=${APP_NAME}_prod.db"
else
    DB_ENV_LINE_DEV="DATABASE_URL=ecto://postgres:postgres@localhost/${APP_NAME}_dev"
    DB_ENV_LINE_PROD="DATABASE_URL=postgresql://postgres:postgres@localhost:5432/${APP_NAME}_prod"
fi

render() {
    local template_rel="$1"
    local output_rel="${template_rel%.eex}" # strip .eex suffix
    # Replace app_name placeholder in output path
    output_rel="${output_rel//app_name_module/$APP_NAME_MODULE}"
    output_rel="${output_rel//app_name/$APP_NAME}"

    # Ensure parent directory exists (handles nested paths like .claude/gate-config.sh)
    mkdir -p "$TARGET_DIR/$(dirname "$output_rel")"

    # Generate SECRET_KEY_BASE if rendering .env
    # Required-for-correctness value: a placeholder here ships as a live secret
    # in every scaffolded app. mix phx.gen.secret only exists as a task INSIDE
    # the app dir (mix.exs must be found) — every other mix/npx/git invocation
    # in this file already wraps (cd "$TARGET_DIR" && ...); this is that same
    # form. Failure is fatal, not a silent placeholder substitution.
    local secret_key_base=""
    if [[ "$template_rel" == ".env.eex" ]]; then
        local secret_stderr_file
        secret_stderr_file="$(mktemp)"
        if ! secret_key_base="$(cd "$TARGET_DIR" && mix phx.gen.secret 2>"$secret_stderr_file")"; then
            echo "[scaffold.sh] ERROR: mix phx.gen.secret failed — cannot generate a real SECRET_KEY_BASE; real stderr:" >&2
            cat "$secret_stderr_file" >&2
            rm -f "$secret_stderr_file"
            exit 1
        fi
        rm -f "$secret_stderr_file"
    fi

    "$RENDER_SH" \
        "$TEMPLATES_DIR/$template_rel" \
        "$TARGET_DIR/$output_rel" \
        "app_name=$APP_NAME" \
        "app_name_module=$APP_NAME_MODULE" \
        "elixir_version=$ELIXIR_VERSION" \
        "node_version=$NODE_VERSION" \
        "otp_version=$OTP_VERSION" \
        "otp_major_version=$OTP_MAJOR_VERSION" \
        "slug=$SLUG" \
        "dev_port=4000" \
        "secret_key_base=$secret_key_base" \
        "db_env_line_dev=$DB_ENV_LINE_DEV" \
        "db_env_line_prod=$DB_ENV_LINE_PROD"
}

render "Makefile.eex"
render ".tool-versions.eex"
render ".mise.toml.eex"
render ".env.eex"
render ".env.sample.eex"
render ".env.prod.sample.eex"
render ".credo.exs.eex"
render ".dialyzer_ignore.exs.eex"
render ".sobelow-conf.eex"
render ".prettierignore.eex"
render ".prettierrc.js.eex"
render "coveralls.json.eex"
render "README.md.eex"
render "lib/app_name_web/controllers/health_controller.ex.eex"
render "test/app_name_web/controllers/health_controller_test.exs.eex"
render ".claude/gate-config.sh.eex"
render ".mcp.json.eex"

# If --no-ecto, remove ecto.rollback line from Makefile
if [[ -n "$NO_ECTO" ]] && [[ -f "$TARGET_DIR/Makefile" ]]; then
    # grep -v exits 1 when no lines match (impossible here — file always has other
    # lines), but splitting grep and mv avoids the `&&` short-circuit that would
    # abort under set -e before mv runs, leaving an empty .tmp in place of the
    # original. Unconditional mv is safe.
    grep -v 'ecto.rollback' "$TARGET_DIR/Makefile" >"$TARGET_DIR/Makefile.tmp"
    mv "$TARGET_DIR/Makefile.tmp" "$TARGET_DIR/Makefile"
    # Post-condition: the ecto.rollback line must actually be gone
    if grep -q 'ecto.rollback' "$TARGET_DIR/Makefile"; then
        echo "[scaffold.sh] ERROR: --no-ecto strip failed — ecto.rollback line remains in Makefile" >&2
        exit 1
    fi
fi

# If --no-ecto, strip the two Ecto lines from the health controller
# (mix phx.new --no-ecto generates no Repo module → SQL.query!/alias would fail compile).
# Pattern set is unique to health_controller across all templates (verified, zero false positives).
HEALTH_CONTROLLER="$TARGET_DIR/lib/${APP_NAME}_web/controllers/health_controller.ex"
if [[ -n "$NO_ECTO" ]] && [[ -f "$HEALTH_CONTROLLER" ]]; then
    # grep -v exits 1 when no lines match (impossible here — file always has other lines),
    # but splitting grep and mv avoids the `&&` short-circuit that would abort under set -e
    # before mv runs, leaving an empty .tmp in place of the original. Unconditional mv is safe.
    # Note: mix format ran before Phase 1 (line ~131), so extra blank lines left by stripping
    # these two Ecto lines remain in the generated file — cosmetic, Elixir-tolerant, harmless.
    grep -vE 'alias Ecto\.Adapters\.SQL|SQL\.query!' "$HEALTH_CONTROLLER" \
        >"$HEALTH_CONTROLLER.tmp"
    mv "$HEALTH_CONTROLLER.tmp" "$HEALTH_CONTROLLER"
    # Post-condition: both Ecto references must be gone
    if grep -qE 'alias Ecto\.Adapters\.SQL|SQL\.query!' "$HEALTH_CONTROLLER"; then
        echo "[scaffold.sh] ERROR: --no-ecto strip failed — Ecto refs remain in health_controller.ex" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Phase 1b: remove default page controller files
# phx.new generates a page_controller.ex + page_html.ex + page_controller_test.exs
# that assert "Peace of mind from prototype to production" at GET /.
# Our scaffold always uses a LiveView at /, so these files become stale and
# fail mix test once the AI replaces the root route. Delete them unconditionally.
# ---------------------------------------------------------------------------
PAGE_CTRL="$TARGET_DIR/lib/${APP_NAME}_web/controllers/page_controller.ex"
PAGE_HTML="$TARGET_DIR/lib/${APP_NAME}_web/controllers/page_html.ex"
PAGE_HTML_DIR="$TARGET_DIR/lib/${APP_NAME}_web/controllers/page_html"
PAGE_CTRL_TEST="$TARGET_DIR/test/${APP_NAME}_web/controllers/page_controller_test.exs"

for f in "$PAGE_CTRL" "$PAGE_HTML" "$PAGE_CTRL_TEST"; do
    [[ -f "$f" ]] && rm -f "$f" && echo "[scaffold.sh] removed $f"
done
[[ -d "$PAGE_HTML_DIR" ]] && rm -rf "$PAGE_HTML_DIR" && echo "[scaffold.sh] removed $PAGE_HTML_DIR"

# ---------------------------------------------------------------------------
# Phase 2: run mutation scripts in fixed order
# ---------------------------------------------------------------------------
echo "[scaffold.sh] running mutations..."

EXTRA_FLAGS=()
[[ -n "$NO_ECTO" ]] && EXTRA_FLAGS+=(--no-ecto)
[[ -n "$WITH_APPSIGNAL" ]] && EXTRA_FLAGS+=(--with-appsignal)
[[ -n "$GITHUB_URL" ]] && EXTRA_FLAGS+=(--github-url "$GITHUB_URL")

bash "$MUTATIONS_DIR/mix_exs.sh" "$TARGET_DIR" "$APP_NAME" "$APP_NAME_MODULE" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"
bash "$MUTATIONS_DIR/config_exs.sh" "$TARGET_DIR"
bash "$MUTATIONS_DIR/prod_exs.sh" "$TARGET_DIR"
FORMATTER_FLAGS=()
[[ -n "$NO_ECTO" ]] && FORMATTER_FLAGS+=(--no-ecto)
bash "$MUTATIONS_DIR/formatter_exs.sh" "$TARGET_DIR" "${FORMATTER_FLAGS[@]+"${FORMATTER_FLAGS[@]}"}"
bash "$MUTATIONS_DIR/gitignore.sh" "$TARGET_DIR"
bash "$MUTATIONS_DIR/router.sh" "$TARGET_DIR" "$APP_NAME_MODULE"
bash "$MUTATIONS_DIR/endpoint.sh" "$TARGET_DIR" "$APP_NAME"
bash "$MUTATIONS_DIR/telemetry.sh" "$TARGET_DIR" "$APP_NAME"
bash "$MUTATIONS_DIR/data_case.sh" "$TARGET_DIR" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"
bash "$MUTATIONS_DIR/credo_fix.sh" "$TARGET_DIR" "$APP_NAME_MODULE" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"

# ---------------------------------------------------------------------------
# Phase 3: ensure priv/plts dir exists
# ---------------------------------------------------------------------------
# No sentinel: priv/plts/ sits under the same unnegated /priv/plts/ .gitignore
# boundary as codegen/ above — a .keep file there cannot survive a clone
# either. run_integrate_stage (codegen-scaffold) recreates this dir on every
# integrate; the mkdir here only covers first-provision.
echo "[scaffold.sh] ensuring priv/plts..."
mkdir -p "$TARGET_DIR/priv/plts"

# ---------------------------------------------------------------------------
# Phase 3b: ensure codegen/pitches lifecycle dirs exist
# ---------------------------------------------------------------------------
# codegen/pitches/{draft,ready,shipped}/ are created here so first provision
# doesn't depend on a later build running codegen-scaffold integrate — but
# they live under an unnegated .gitignore boundary (/codegen/), so a sentinel
# file cannot survive a clone. run_integrate_stage (codegen-scaffold) is the
# durable owner that recreates these on every integrate; no sentinel is
# written here (see context/scaffold.md § clone survivability).
echo "[scaffold.sh] ensuring codegen/pitches/{draft,ready,shipped}/ dirs..."
for _d in draft ready shipped; do
    mkdir -p "$TARGET_DIR/codegen/pitches/$_d"
done

# ---------------------------------------------------------------------------
# Phase 4: mise trust
# ---------------------------------------------------------------------------
# Tool ABSENCE stays a quiet skip (prerequisite-policy question, out of
# scope). Tool FAILURE (mise present but trust fails — e.g. corrupt config,
# permission error) is fatal: an untrusted .mise.toml means .env never loads
# locally (.mise.toml's [env] _.file = '.env' is the only local .env loader),
# so a scaffolded app silently boots with no config.
if command -v mise >/dev/null 2>&1; then
    echo "[scaffold.sh] trusting mise toolchain..."
    _mise_trust_stderr_file="$(mktemp)"
    if ! mise trust "$TARGET_DIR/.mise.toml" >/dev/null 2>"$_mise_trust_stderr_file"; then
        echo "[scaffold.sh] ERROR: mise trust failed — .mise.toml will not load .env; real stderr:" >&2
        cat "$_mise_trust_stderr_file" >&2
        rm -f "$_mise_trust_stderr_file"
        exit 1
    fi
    rm -f "$_mise_trust_stderr_file"
fi

# ---------------------------------------------------------------------------
# Phase 5: deps.get (always, to produce the REAL lock), then scaffold cache
# restore attempt keyed on that lock, then format
# ---------------------------------------------------------------------------
# Cache key ordering: mutations (Phase 2) inject optimum deps into mix.exs,
# but mix.lock is not updated until deps.get resolves it. Computing the key
# from mix.lock BEFORE deps.get (the previous ordering) hashed the STOCK
# phx.new lock — every scaffolded app's key ignored the injected deps
# entirely, and a "cache hit" printed a warm-cache line while deps.get went
# on to fetch every optimum package cold. deps.get must run first, always;
# the key (and the restore attempt) come after, against the lock the app
# actually builds against. This restore only saves compiled-artifact time
# (_build/*/lib/<dep>, PLT) — deps.get itself is not skippable by this cache.
echo "[scaffold.sh] running mix deps.get..."
(cd "$TARGET_DIR" && mix deps.get) || {
    echo "[scaffold.sh] ERROR: mix deps.get failed" >&2
    exit 1
}

echo "[scaffold.sh] checking scaffold cache..."
if key="$(scaffold_cache_key "$TARGET_DIR" "$OTP_VERSION" "$ELIXIR_VERSION" 2>/dev/null)"; then
    CACHE_KEY="$key"
    CACHE_KEY_SHORT="${CACHE_KEY:0:12}"
    if scaffold_cache_is_disabled "$CACHE_ROOT" "$CACHE_KEY"; then
        CACHE_STATUS="disabled"
        echo "[scaffold.sh] scaffold cache disabled for key $CACHE_KEY_SHORT — cold run" >&2
    elif scaffold_cache_restore "$TARGET_DIR" "$CACHE_ROOT" "$CACHE_KEY"; then
        CACHE_STATUS="hit"
        echo "[scaffold.sh] scaffold cache hit (key $CACHE_KEY_SHORT) — restored deps/_build/plt"
    else
        CACHE_STATUS="miss"
        echo "[scaffold.sh] scaffold cache miss (key $CACHE_KEY_SHORT) — cold run, will populate on success"
    fi
else
    CACHE_STATUS="miss"
    echo "[scaffold.sh] scaffold cache key not computable (mix.lock absent) — cold run" >&2
fi

echo "[scaffold.sh] running mix format (best-effort)..."
(cd "$TARGET_DIR" && mix format) || true

# ---------------------------------------------------------------------------
# Phase 5b: generate missing usage_rules docs
# ---------------------------------------------------------------------------
if command -v codegen-document >/dev/null 2>&1; then
    echo "[scaffold.sh] generating usage_rules docs for new app deps..."
    # Fail-loud: codegen-document IS present but FAILING would silently leave
    # usage_rules docs missing from the scaffolded app — a correctness gap,
    # not a benign skip. Fatal per the fail-closed-everywhere ruling.
    if ! (cd "$TARGET_DIR" && codegen-document); then
        echo "[scaffold.sh] FATAL: codegen-document failed — usage_rules docs would be silently missing from the scaffolded app. Fail-loud per fail-closed ruling." >&2
        exit 1
    fi
else
    # advisory: codegen-document is an optional provisioning tool; absence is
    # a legitimate skip, distinct from a present-tool FAILURE (fatal above).
    echo "[scaffold.sh] WARN: codegen-document not on PATH — skipping usage_rules generation" >&2
fi

# ---------------------------------------------------------------------------
# Phase 6: releases + optimum_templates submodule
# ---------------------------------------------------------------------------
echo "[scaffold.sh] generating releases..."
(cd "$TARGET_DIR" && mix phx.gen.release) || {
    echo "[scaffold.sh] ERROR: mix phx.gen.release failed" >&2
    exit 1
}

# Post-condition: rel/ must exist after a successful phx.gen.release
if [[ ! -d "$TARGET_DIR/rel" ]]; then
    echo "[scaffold.sh] ERROR: mix phx.gen.release reported success but rel/ is missing" >&2
    exit 1
fi

# Under --no-ecto, remove the migrate overlay that phx.gen.release emits unconditionally.
# The overlay calls <App>.Release.migrate/0 which phx.new --no-ecto omits → broken release overlay.
if [[ -n "$NO_ECTO" ]]; then
    rm -f "$TARGET_DIR/rel/overlays/bin/migrate"
    rm -f "$TARGET_DIR/rel/overlays/bin/migrate.bat"
fi

echo "[scaffold.sh] adding optimum_templates submodule..."
(cd "$TARGET_DIR" && git submodule add https://github.com/optimumBA/optimum_templates priv/templates) || {
    echo "[scaffold.sh] ERROR: optimum_templates submodule add failed" >&2
    exit 1
}

# Post-condition: priv/templates must exist and be non-empty after a successful submodule add
if [[ ! -d "$TARGET_DIR/priv/templates" ]] || [[ -z "$(ls -A "$TARGET_DIR/priv/templates" 2>/dev/null)" ]]; then
    echo "[scaffold.sh] ERROR: optimum_templates submodule add reported success but priv/templates is missing/empty" >&2
    exit 1
fi

# Check mcp-proxy availability
if ! command -v mcp-proxy >/dev/null 2>&1; then
    echo "[scaffold.sh] WARN: mcp-proxy not found — Tidewave MCP disabled. Install: npm install -g mcp-proxy" >&2
fi

# Under --no-ecto, strip Ecto-family lock entries from mix.lock.
# phx.new --no-ecto never adds ecto/ecto_sql/postgrex/phoenix_ecto/db_connection/decimal deps,
# but mix phx.gen.release can leave residue. Strip is belt-and-suspenders + ensures clean lock.
if [[ -n "$NO_ECTO" ]] && [[ -f "$TARGET_DIR/mix.lock" ]]; then
    grep -vE '"(ecto|ecto_sql|postgrex|phoenix_ecto|db_connection|decimal)":' "$TARGET_DIR/mix.lock" >"$TARGET_DIR/mix.lock.tmp" && mv "$TARGET_DIR/mix.lock.tmp" "$TARGET_DIR/mix.lock"
fi

# ---------------------------------------------------------------------------
# Phase 7: self-validation — setup + prettier + make ci
# ---------------------------------------------------------------------------
echo "[scaffold.sh] running mix setup..."
(cd "$TARGET_DIR" && mix setup) || {
    echo "[scaffold.sh] ERROR: mix setup failed" >&2
    exit 1
}

echo "[scaffold.sh] running npx prettier --write ."
(cd "$TARGET_DIR" && npx prettier --write .) || {
    echo "[scaffold.sh] ERROR: npx prettier --write . failed" >&2
    exit 1
}

echo "[scaffold.sh] running make ci..."
if ! (cd "$TARGET_DIR" && make ci); then
    if [[ "$CACHE_STATUS" == "hit" ]]; then
        # Self-heal: a warm (restored) run failed make ci. The cached deps/PLT
        # may be stale or corrupt — purge, disable the cache entry, and
        # re-run the full cold path. A cold-run make ci failure below is a
        # real template/mutation bug and stays fatal (existing behavior).
        echo "[scaffold.sh] WARN: make ci failed on a warm cache run (key $CACHE_KEY_SHORT) — purging cache entry and retrying cold" >&2
        rm -rf "$TARGET_DIR/deps" "$TARGET_DIR/_build" "$TARGET_DIR/priv/plts/dialyzer.plt"
        scaffold_cache_disable "$CACHE_ROOT" "$CACHE_KEY"
        CACHE_STATUS="disabled"

        echo "[scaffold.sh] re-running mix deps.get (cold)..."
        (cd "$TARGET_DIR" && mix deps.get) || {
            echo "[scaffold.sh] ERROR: mix deps.get failed on cold retry" >&2
            exit 1
        }

        echo "[scaffold.sh] re-running mix setup (cold)..."
        (cd "$TARGET_DIR" && mix setup) || {
            echo "[scaffold.sh] ERROR: mix setup failed on cold retry" >&2
            exit 1
        }

        echo "[scaffold.sh] re-running npx prettier --write . (cold)..."
        (cd "$TARGET_DIR" && npx prettier --write .) || {
            echo "[scaffold.sh] ERROR: npx prettier --write . failed on cold retry" >&2
            exit 1
        }

        echo "[scaffold.sh] re-running make ci (cold)..."
        (cd "$TARGET_DIR" && make ci) || {
            echo "[scaffold.sh] ERROR: make ci failed on cold retry — this is a real template/mutation bug" >&2
            exit 1
        }
    else
        echo "[scaffold.sh] ERROR: make ci failed" >&2
        exit 1
    fi
fi

# make ci succeeded. On a cold miss (not disabled), populate the cache for
# future runs. Best-effort; scaffold_cache_save never returns non-zero.
if [[ "$CACHE_STATUS" == "miss" ]]; then
    scaffold_cache_save "$TARGET_DIR" "$CACHE_ROOT" "$CACHE_KEY" "$APP_NAME"
    if [[ -d "$CACHE_ROOT/$CACHE_KEY" ]]; then
        CACHE_STATUS="miss-saved"
    else
        CACHE_STATUS="miss-save-failed"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 8: git commit — owned by codegen-scaffold (runs after integrate stage)
# ---------------------------------------------------------------------------
# Note: the initial git commit is now done in codegen-scaffold's do_create,
# AFTER run_integrate_stage, so that PROJECT_CONTEXT.md, restart_server.sh,
# and usage_rules_INDEX.md are all included in the initial commit.

# Scaffold completed successfully — disarm the cleanup trap so the app dir is kept.
SCAFFOLD_OK="1"

# ---------------------------------------------------------------------------
# Readiness summary
# ---------------------------------------------------------------------------
echo ""
echo "[scaffold.sh] =========================================="
echo "[scaffold.sh] Scaffold complete!"
echo "[scaffold.sh]   App: $APP_NAME ($APP_NAME_MODULE)"
echo "[scaffold.sh]   Path: $TARGET_DIR"
echo "[scaffold.sh]   Elixir: $ELIXIR_VERSION / OTP: $OTP_VERSION"
echo "[scaffold.sh]   Next: cd $TARGET_DIR && mix phx.server"
case "$CACHE_STATUS" in
hit)
    echo "[scaffold.sh]   Cache: hit (key $CACHE_KEY_SHORT)"
    ;;
miss-saved)
    echo "[scaffold.sh]   Cache: miss — populated"
    ;;
miss-save-failed)
    echo "[scaffold.sh]   Cache: miss — save failed"
    ;;
disabled)
    echo "[scaffold.sh]   Cache: disabled (key $CACHE_KEY_SHORT) — cold"
    ;;
esac
echo "[scaffold.sh] =========================================="
echo "[scaffold.sh] scaffold complete"
