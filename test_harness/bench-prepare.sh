#!/usr/bin/env bash
set -euo pipefail

# bench-prepare.sh — creates a benchmark run directory, writes reason.txt and
# an initial manifest.json, then prints BENCH_RUN_DIR on the last line of stdout
# (Makefile captures this via command substitution).
#
# Exit codes:
#   0 — success; BENCH_RUN_DIR path printed to stdout
#   2 — BENCH=1 but REASON is empty
#   3 — run dir already exists (double-invoke in same second)

if [ "${BENCH:-}" != "1" ]; then
    echo "bench-prepare.sh: BENCH is not set to 1 — nothing to do" >&2
    exit 0
fi

if [ -z "${REASON:-}" ]; then
    echo "bench-prepare.sh: BENCH=1 requires REASON to be set (e.g. REASON=\"dev smoke\")" >&2
    exit 2
fi

# Resolve repo root (two levels up from test_harness/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BENCH_RUN_DIR="${REPO_ROOT}/codegen/benchmarks/$(date -u +%Y%m%d_%H%M%S)"

if [ -d "${BENCH_RUN_DIR}" ]; then
    echo "bench-prepare.sh: run dir already exists: ${BENCH_RUN_DIR} (double-invoke in same second?)" >&2
    exit 3
fi

mkdir -p \
    "${BENCH_RUN_DIR}/runs/claude/phoenix" \
    "${BENCH_RUN_DIR}/runs/claude/static" \
    "${BENCH_RUN_DIR}/runs/claude/modes"

printf '%s' "${REASON}" >"${BENCH_RUN_DIR}/reason.txt"

CODEGEN_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "")"
# advisory: CLAUDE_VERSION feeds manifest.json harness_versions as
# diagnostic metadata only. A missing harness binary yielding "" is a benign
# informational gap (bench still runs) — NOT a required-value mask. Keep
# soft per fail-loud-rule justified-advisory carve-out.
CLAUDE_VERSION="$(claude --version 2>&1 || echo "")"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat >"${BENCH_RUN_DIR}/manifest.json" <<JSON
{
  "codegen_sha": "${CODEGEN_SHA}",
  "harness_versions": {
    "claude": "${CLAUDE_VERSION}"
  },
  "started_at": "${STARTED_AT}",
  "model_resolution": {}
}
JSON

# Last line of stdout — captured by Makefile
echo "${BENCH_RUN_DIR}"
