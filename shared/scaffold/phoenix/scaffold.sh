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
# Standalone shell usage (no combobulate):
#   scaffold.sh my_app /tmp/my_app && cd /tmp/my_app && mix deps.get && mix phx.server
#
# Combobulate usage: combobulate calls this script once and lets it own the full scaffold.
#   The caller must NOT pre-run mix phx.new — scaffold.sh owns that step.
#
# Flags:
#   --elixir-version <v>   default: 1.19.5
#   --node-version <v>     default: 24.14.0
#   --otp-version <v>      default: 28.4.1
#   --no-ecto              skip Ecto/DB setup
#   --with-appsignal       add AppSignal monitoring
#   --github-url <url>     set source_url in mix.exs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
MUTATIONS_DIR="$SCRIPT_DIR/mutations"
RENDER_SH="$SCRIPT_DIR/eex_render.sh"

# Parse positional and flag args
# Note: version defaults are NOT set here — callers (codegen-scaffold) always pass them explicitly.
ELIXIR_VERSION=""
NODE_VERSION=""
OTP_VERSION=""
NO_ECTO=""
WITH_APPSIGNAL=""
GITHUB_URL=""

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
(cd "$PARENT_DIR" && mix phx.new "$SLUG" "${PHX_NEW_FLAGS[@]}")
echo "[scaffold.sh] mix phx.new complete"

# ---------------------------------------------------------------------------
# Phase 1: render standalone templates
# ---------------------------------------------------------------------------
echo "[scaffold.sh] rendering templates..."

render() {
    local template_rel="$1"
    local output_rel="${template_rel%.eex}" # strip .eex suffix
    # Replace app_name placeholder in output path
    output_rel="${output_rel//app_name_module/$APP_NAME_MODULE}"
    output_rel="${output_rel//app_name/$APP_NAME}"

    # Ensure parent directory exists (handles nested paths like .claude/gate-config.sh)
    mkdir -p "$TARGET_DIR/$(dirname "$output_rel")"

    # Generate SECRET_KEY_BASE if rendering .env
    local secret_key_base=""
    if [[ "$template_rel" == ".env.eex" ]]; then
        secret_key_base="$(mix phx.gen.secret 2>/dev/null || echo "REPLACE_with_mix_phx.gen.secret_output")"
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
        "secret_key_base=$secret_key_base"
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
    grep -v 'ecto.rollback' "$TARGET_DIR/Makefile" >"$TARGET_DIR/Makefile.tmp" && mv "$TARGET_DIR/Makefile.tmp" "$TARGET_DIR/Makefile"
fi

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
bash "$MUTATIONS_DIR/formatter_exs.sh" "$TARGET_DIR"
bash "$MUTATIONS_DIR/gitignore.sh" "$TARGET_DIR"
bash "$MUTATIONS_DIR/router.sh" "$TARGET_DIR" "$APP_NAME_MODULE"
bash "$MUTATIONS_DIR/endpoint.sh" "$TARGET_DIR" "$APP_NAME"
bash "$MUTATIONS_DIR/telemetry.sh" "$TARGET_DIR" "$APP_NAME"
bash "$MUTATIONS_DIR/data_case.sh" "$TARGET_DIR" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"
bash "$MUTATIONS_DIR/credo_fix.sh" "$TARGET_DIR" "$APP_NAME_MODULE" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"

# ---------------------------------------------------------------------------
# Phase 3: ensure priv/plts dir exists
# ---------------------------------------------------------------------------
echo "[scaffold.sh] ensuring priv/plts..."
mkdir -p "$TARGET_DIR/priv/plts"
touch "$TARGET_DIR/priv/plts/.keep"

# ---------------------------------------------------------------------------
# Phase 4: mise trust
# ---------------------------------------------------------------------------
if command -v mise >/dev/null 2>&1; then
    echo "[scaffold.sh] trusting mise toolchain..."
    mise trust "$TARGET_DIR/.mise.toml" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Phase 5: deps.get + format
# ---------------------------------------------------------------------------
echo "[scaffold.sh] running mix deps.get..."
(cd "$TARGET_DIR" && mix deps.get) || {
    echo "[scaffold.sh] ERROR: mix deps.get failed" >&2
    exit 1
}

echo "[scaffold.sh] running mix format (best-effort)..."
(cd "$TARGET_DIR" && mix format) || true

# ---------------------------------------------------------------------------
# Phase 6: releases + optimum_templates submodule
# ---------------------------------------------------------------------------
echo "[scaffold.sh] generating releases..."
(cd "$TARGET_DIR" && mix phx.gen.release) || echo "[scaffold.sh] WARN: mix phx.gen.release failed — skipping" >&2

echo "[scaffold.sh] adding optimum_templates submodule..."
(cd "$TARGET_DIR" && git submodule add https://github.com/optimumBA/optimum_templates priv/templates) ||
    echo "[scaffold.sh] WARN: optimum_templates submodule add failed — add manually" >&2

# Check mcp-proxy availability
if ! command -v mcp-proxy >/dev/null 2>&1; then
    echo "[scaffold.sh] WARN: mcp-proxy not found — Tidewave MCP disabled. Install: npm install -g mcp-proxy" >&2
fi

# ---------------------------------------------------------------------------
# Phase 7: self-validation — setup + compile
# ---------------------------------------------------------------------------
echo "[scaffold.sh] running mix setup..."
(cd "$TARGET_DIR" && mix setup) || {
    echo "[scaffold.sh] ERROR: mix setup failed" >&2
    exit 1
}

echo "[scaffold.sh] running mix compile --warnings-as-errors..."
(cd "$TARGET_DIR" && mix compile --warnings-as-errors) ||
    {
        echo "[scaffold.sh] ERROR: mix compile --warnings-as-errors failed" >&2
        exit 1
    }

# ---------------------------------------------------------------------------
# Phase 8: initial git commit
# ---------------------------------------------------------------------------
echo "[scaffold.sh] creating initial git commit..."
(cd "$TARGET_DIR" && git add -A && git commit -m "Initial commit") ||
    {
        echo "[scaffold.sh] ERROR: initial git commit failed" >&2
        exit 1
    }

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
echo "[scaffold.sh] =========================================="
echo "[scaffold.sh] scaffold complete"
