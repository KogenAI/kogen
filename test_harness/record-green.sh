#!/usr/bin/env bash
# record-green.sh — write last_green.json with current codegen sha + harness versions.
# Invoked by `make record-green` after `make test` and `make test-stacks` both pass.
#
# Optional flag: --auto-commit
#   After writing last_green.json, perform a scoped git commit of that file only.
#   Fail-soft: on dirty tree or missing credentials, logs a warning and exits 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/last_green.json"

AUTO_COMMIT=0
for arg in "$@"; do
    if [ "$arg" = "--auto-commit" ]; then
        AUTO_COMMIT=1
    fi
done

SHA="$(git -C "$SCRIPT_DIR/.." rev-parse HEAD 2>/dev/null || echo unknown)"
CLAUDE_V="$(claude --version 2>/dev/null || echo unknown)"
ELIXIR_V="$(elixir --version 2>/dev/null | tr '\n' ' ' || echo unknown)"
OTP_V="$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo unknown)"
NODE_V="$(node --version 2>/dev/null || echo unknown)"
YQ_V="$(yq --version 2>/dev/null || echo unknown)"
OS_V="$(uname -sm 2>/dev/null || echo unknown)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
    --arg sha "$SHA" \
    --arg cv "$CLAUDE_V" \
    --arg ev "$ELIXIR_V" \
    --arg ov "$OTP_V" \
    --arg nv "$NODE_V" \
    --arg yv "$YQ_V" \
    --arg os "$OS_V" \
    --arg ts "$TS" \
    '{codegen_sha: $sha, harness_versions: {claude: $cv}, tool_versions: {elixir: $ev, erlang_otp: $ov, node: $nv, yq: $yv}, os: $os, test_passed_at: $ts, test_command: "make test-all"}' \
    >"$OUTPUT"

echo "wrote $OUTPUT (codegen_sha=$SHA, ts=$TS)"

if [ "$AUTO_COMMIT" = "1" ]; then
    git -C "$SCRIPT_DIR/.." add "$OUTPUT" &&
        git -C "$SCRIPT_DIR/.." commit -m "Refresh green baseline" -- "$OUTPUT" ||
        { echo "record-green: auto-commit skipped (dirty tree / no creds)"; }
fi
