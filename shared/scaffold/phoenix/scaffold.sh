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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
MUTATIONS_DIR="$SCRIPT_DIR/mutations"
RENDER_SH="$SCRIPT_DIR/eex_render.sh"

ELIXIR_VERSION="1.19.5"
NODE_VERSION="24.14.0"
OTP_VERSION="28.4.1"

# Parse positional and flag args
APP_NAME=""
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --elixir-version) ELIXIR_VERSION="$2"; shift 2 ;;
    --node-version)   NODE_VERSION="$2";   shift 2 ;;
    --otp-version)    OTP_VERSION="$2";    shift 2 ;;
    -*) echo "[scaffold.sh] Unknown flag: $1" >&2; exit 1 ;;
    *)
      if [ -z "$APP_NAME" ]; then
        APP_NAME="$1"
      elif [ -z "$TARGET_DIR" ]; then
        TARGET_DIR="$1"
      else
        echo "[scaffold.sh] Unexpected argument: $1" >&2; exit 1
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
APP_NAME_MODULE="$(echo "$APP_NAME" | sed 's/_\([a-z]\)/\U\1/g; s/^\([a-z]\)/\U\1/')"

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
mix phx.new "$SLUG" \
  --app "$APP_NAME" \
  --module "$APP_NAME_MODULE" \
  --binary-id \
  --no-mailer \
  --no-dashboard \
  --no-agents-md \
  --no-version-check \
  --install
echo "[scaffold.sh] mix phx.new complete"

# ---------------------------------------------------------------------------
# Phase 1: render standalone templates
# ---------------------------------------------------------------------------
echo "[scaffold.sh] rendering templates..."

render() {
  local template_rel="$1"
  local output_rel="${template_rel%.eex}"  # strip .eex suffix
  # Replace app_name placeholder in output path
  output_rel="${output_rel//app_name_module/$APP_NAME_MODULE}"
  output_rel="${output_rel//app_name/$APP_NAME}"

  "$RENDER_SH" \
    "$TEMPLATES_DIR/$template_rel" \
    "$TARGET_DIR/$output_rel" \
    "app_name=$APP_NAME" \
    "app_name_module=$APP_NAME_MODULE" \
    "elixir_version=$ELIXIR_VERSION" \
    "node_version=$NODE_VERSION" \
    "otp_version=$OTP_VERSION" \
    "otp_major_version=$OTP_MAJOR_VERSION"
}

render "Makefile.eex"
render ".tool-versions.eex"
render ".mise.toml.eex"
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

# ---------------------------------------------------------------------------
# Phase 2: run mutation scripts in fixed order
# ---------------------------------------------------------------------------
echo "[scaffold.sh] running mutations..."

bash "$MUTATIONS_DIR/mix_exs.sh"      "$TARGET_DIR" "$APP_NAME" "$APP_NAME_MODULE"
bash "$MUTATIONS_DIR/config_exs.sh"   "$TARGET_DIR"
bash "$MUTATIONS_DIR/prod_exs.sh"     "$TARGET_DIR"
bash "$MUTATIONS_DIR/formatter_exs.sh" "$TARGET_DIR"
bash "$MUTATIONS_DIR/gitignore.sh"    "$TARGET_DIR"
bash "$MUTATIONS_DIR/router.sh"       "$TARGET_DIR" "$APP_NAME_MODULE"
bash "$MUTATIONS_DIR/endpoint.sh"     "$TARGET_DIR" "$APP_NAME"
bash "$MUTATIONS_DIR/telemetry.sh"    "$TARGET_DIR" "$APP_NAME"
bash "$MUTATIONS_DIR/data_case.sh"    "$TARGET_DIR"

# ---------------------------------------------------------------------------
# Phase 3: ensure priv/plts dir exists
# ---------------------------------------------------------------------------
echo "[scaffold.sh] ensuring priv/plts..."
mkdir -p "$TARGET_DIR/priv/plts"
touch "$TARGET_DIR/priv/plts/.keep"

echo "[scaffold.sh] scaffold complete"
