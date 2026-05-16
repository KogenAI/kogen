#!/bin/bash
# llm-test-guard.sh — PreToolUse hook: deny unbounded `mix test --only llm_integration`.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: all
#
# Blocks: `mix test --only llm_integration` UNLESS the command ALSO contains
#         literal `MIX_TEST_PARTITION=1` AND `MIX_TEST_PARTITIONS=1` AND a
#         `.exs` path token.
#
# The single-partition+single-partitions+path combination is the signature of
# `make llm-single FILE=<path>`. Any other composition (e.g. PARTITION=3
# PARTITIONS=10) is a dev attempting to drive the suite directly.
#
# Allows: `make llm-single`, `make llm`, `make llm-phoenix` (those don't
#         contain `mix test --only llm_integration` literally).

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log llm-test-guard "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only act when command contains `mix test` with `--only llm_integration`.
if ! printf '%s' "$COMMAND" | grep -qE 'mix[[:space:]]+test.*--only[[:space:]]+llm_integration|mix[[:space:]]+test.*--only=llm_integration'; then
    exit 0
fi

# Check for the three required tokens: MIX_TEST_PARTITION=1, MIX_TEST_PARTITIONS=1, and a .exs path.
has_partition_1=$(printf '%s' "$COMMAND" | grep -o 'MIX_TEST_PARTITION=1\b' | head -1 || true)
has_partitions_1=$(printf '%s' "$COMMAND" | grep -o 'MIX_TEST_PARTITIONS=1\b' | head -1 || true)
has_exs_path=$(printf '%s' "$COMMAND" | grep -oE '[^[:space:]]+\.exs' | head -1 || true)

if [ -n "$has_partition_1" ] && [ -n "$has_partitions_1" ] && [ -n "$has_exs_path" ]; then
    # Looks like `make llm-single FILE=<path>` expansion — allow.
    exit 0
fi

deny "Unbounded \`mix test --only llm_integration\` runs the LLM suite without partitioning. Use \`make llm\` (10-partition parallel) for the full suite, or \`make llm-single FILE=test/.../foo_test.exs\` for one file."
exit 0
