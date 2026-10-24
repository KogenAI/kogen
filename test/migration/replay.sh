#!/bin/sh
# Bounded production-transition replay: sh test/migration/replay.sh <kogen> <out>
# Runs four real production journeys with the given installed kogen against a scripted local provider, turns what
# happened into Quint `run` tests over spec/quint/build.qnt and runs `quint test` on them; then builds five
# production mutants from an isolated copy of cli/, runs the matching journey with each and requires its trace
# to fail. Results: <out>/replay.json. Needs Go, Node 22+ and git on PATH (Go and Node through mise when absent)
# and Quint in spec/node_modules (npm ci there when missing).
set -eu
[ $# -eq 2 ] || { echo "usage: sh test/migration/replay.sh <kogen> <out>" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
kogen=$1
out=$2
case "$kogen" in /*) ;; *) kogen="$PWD/$kogen" ;; esac
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
[ -x "$kogen" ] || { echo "replay: $kogen is not an executable kogen" >&2; exit 2; }

# Node 22 or newer, Go: from PATH, else through mise.
node=$(command -v node 2>/dev/null || true)
if [ -z "$node" ] || [ "$("$node" -p 'process.versions.node.split(".")[0] >= 22' 2>/dev/null || true)" != true ]; then
  node=$(mise exec -- sh -c 'command -v node' 2>/dev/null || true)
fi
[ -n "$node" ] || { echo "replay: node 22 or newer is neither on PATH nor available through mise" >&2; exit 1; }
if ! command -v go >/dev/null 2>&1; then
  go=$(mise exec go@1.27.2 -- sh -c 'command -v go' 2>/dev/null || true)
  [ -n "$go" ] || { echo "replay: go is neither on PATH nor available through mise" >&2; exit 1; }
  PATH="$(dirname "$go"):$PATH"; export PATH
fi
command -v git >/dev/null 2>&1 || { echo "replay: git is not on PATH" >&2; exit 1; }

if [ ! -f "$repo/spec/node_modules/@informalsystems/quint/dist/src/cli.js" ]; then
  (cd "$repo/spec" && PATH="$(dirname "$node"):$PATH" npm ci --ignore-scripts --no-audit --no-fund --silent) >&2
fi

mkdir -p "$out"
exec "$node" "$here/replay/run.js" "$kogen" "$out"
