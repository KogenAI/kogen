#!/bin/sh
# Developer Stop hook. Protocol and durable evidence live in stop_runner.py.
set -u
if [ "${KOGEN_ROLE:-}" != "developer" ]; then
  printf '{"continue":true}\n'
  exit 0
fi
root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf '{"decision":"block","reason":"Kogen Stop Check could not find the Git repository."}\n'
  exit 0
}
exec python3 "$root/.codex/hooks/stop_runner.py"
