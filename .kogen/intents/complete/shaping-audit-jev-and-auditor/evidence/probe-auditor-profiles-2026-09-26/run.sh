#!/bin/bash
set -u
SCRATCH="/private/tmp/claude-501/-Users-almirsarajcic-Areas-Kogen-kogen/3643c45e-1f35-4957-8a04-6a7493b74338/scratchpad/audit-r13"
CODEX="/Users/almirsarajcic/Library/Application Support/Kogen/codex/runtimes/0.156.1-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
PROJECT_ROOT="/Users/almirsarajcic/Areas/Kogen/kogen"
VARIANT=A
GEN="$SCRATCH/gen_$VARIANT"
REAL_HOME="$HOME"
OUT_JSON="$SCRATCH/${VARIANT}_events.jsonl"
LAST_MSG="$SCRATCH/${VARIANT}_last_message.json"
LOG="$SCRATCH/${VARIANT}_run.log"

: > "$OUT_JSON"
: > "$LAST_MSG"

EXTRA_DISABLE=()
if true; then
  EXTRA_DISABLE=(--disable multi_agent)
fi

export CODEX_HOME="/private/tmp/claude-501/-Users-almirsarajcic-Areas-Kogen-kogen/3643c45e-1f35-4957-8a04-6a7493b74338/scratchpad/probe-auditor-ab/codex_home"
export HOME="$GEN/home"
export XDG_CONFIG_HOME="$GEN/xdg-config"
export XDG_DATA_HOME="$GEN/xdg-data"
export XDG_CACHE_HOME="$GEN/xdg-cache"
export XDG_STATE_HOME="$GEN/xdg-state"
export SQLITE_HOME="$GEN/sqlite"
export KOGEN_CALLER_HOME="$REAL_HOME"
export KOGEN_CODEX_EXECUTOR_ENTRYPOINT="$GEN/executor"
export KOGEN_CODEX_EXECUTABLE="$CODEX"
export KOGEN_CODEX_EXECUTOR_LAUNCH_MARKER="1"

START=$(date +%s.%N)

perl -e '
  alarm(180);
  exec @ARGV or die "exec failed: $!";
' "$CODEX" exec \
  -c 'cli_auth_credentials_store="file"' \
  -c 'check_for_update_on_startup=false' \
  -c 'project_root_markers=[".git"]' \
  -c "projects.\"$PROJECT_ROOT\".trust_level=\"trusted\"" \
  -c 'shell_environment_policy.inherit="all"' \
  -c 'shell_environment_policy.exclude=["XDG_CONFIG_HOME","XDG_DATA_HOME","XDG_CACHE_HOME","XDG_STATE_HOME"]' \
  -c "shell_environment_policy.set.HOME=\"$REAL_HOME\"" \
  -c 'shell_environment_policy.experimental_use_profile=false' \
  -c "sqlite_home=\"$GEN/sqlite\"" \
  -c 'tool_output_token_limit=4000' \
  --disable apps --disable plugins --disable shell_snapshot \
  ${EXTRA_DISABLE[@]+"${EXTRA_DISABLE[@]}"} \
  --sandbox read-only \
  --ephemeral \
  --skip-git-repo-check \
  -C "$PROJECT_ROOT" \
  -m gpt-6-sol \
  -c 'model_reasoning_effort="high"' \
  --output-schema "$SCRATCH/schema.json" \
  --output-last-message "$LAST_MSG" \
  --json \
  - < "$SCRATCH/prompt.txt" > "$OUT_JSON" 2> "$LOG"

STATUS=$?
END=$(date +%s.%N)
WALL=$(echo "$END - $START" | bc)

echo "variant=$VARIANT status=$STATUS wall=$WALL" 
