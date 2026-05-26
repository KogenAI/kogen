#!/usr/bin/env bash
# record-green.sh — write last_green.json with current codegen sha + harness versions.
# Invoked by `make record-green` after `make test` and `make test-stacks` both pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/last_green.json"

SHA="$(git -C "$SCRIPT_DIR/.." rev-parse HEAD 2>/dev/null || echo unknown)"
CLAUDE_V="$(claude --version 2>/dev/null || echo unknown)"
PI_V="$(pi --version 2>/dev/null || echo unknown)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg sha "$SHA" \
  --arg cv "$CLAUDE_V" \
  --arg pv "$PI_V" \
  --arg ts "$TS" \
  '{codegen_sha: $sha, harness_versions: {claude: $cv, pi: $pv}, test_passed_at: $ts, test_command: "make test-all"}' \
  > "$OUTPUT"

echo "wrote $OUTPUT (codegen_sha=$SHA, ts=$TS)"
