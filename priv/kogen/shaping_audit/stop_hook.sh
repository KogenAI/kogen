#!/bin/sh
# Shaper Stop hook. Skips a repeat audit on an unchanged package byte-for-byte
# at the same HEAD via a cheap shell-computed skip key; every other case
# defers to `mix kogen.audit --stop-hook` (Kogen.ShapingAudit.StopHook).
set -u

# Native Codex uses private discovery paths; restore ordinary shell-tool
# HOME/XDG semantics before running anything else.
if [ "${KOGEN_ENV_RESTORE_PENDING:-}" = "1" ]; then
  exec python3 "$(dirname "$0")/../../../.codex/hooks/environment.py" sh "$0"
fi

if [ "${KOGEN_ROLE:-}" != "shaper" ]; then
  printf '{"continue":true}\n'
  exit 0
fi

PYTHON_BIN="python3"
if [ -n "${KOGEN_SHAPING_TOOLCHAIN_PATH:-}" ]; then
  PATH="${KOGEN_SHAPING_TOOLCHAIN_PATH}:${PATH}"
  export PATH
  # The toolchain is a PATH list, so resolve the first executable Python from
  # it rather than assuming the list names one directory.
  resolved_python="$(command -v python3 2>/dev/null || true)"
  if [ -n "$resolved_python" ] && [ -x "$resolved_python" ]; then
    PYTHON_BIN="$resolved_python"
  fi
fi

root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf '{"continue":true,"systemMessage":"could not find the Git repository"}\n'
  exit 0
}
root="$(cd "$root" && pwd -P)"

intent_id="${KOGEN_SHAPING_INTENT_ID:-}"
state_dir=""
pkg_dir=""

if [ -n "$intent_id" ]; then
  for base in "$root/.kogen/intents/drafts" "$root/.kogen/intents/approved"; do
    [ -d "$base" ] || continue
    while IFS= read -r candidate; do
      if grep -q "^id: ${intent_id}\$" "$candidate" 2>/dev/null; then
        pkg_dir="$(dirname "$candidate")"
        slug="$(basename "$pkg_dir")"
        state_dir="$root/.kogen/runtime/shaping-audits/$slug"
      fi
    done <<EOF
$(find -P "$base" -mindepth 2 -maxdepth 2 -type f -name intent.yaml -print 2>/dev/null)
EOF
  done
fi

run_mix() {
  out="$(mktemp "${TMPDIR:-/tmp}/kogen-stop-hook.XXXXXX")"
  (cd "$root" && KOGEN_SHAPING_HOOK_OUTPUT="$out" KOGEN_SHAPING_SKIP_KEY="${1:-}" \
    mix kogen.audit --stop-hook >/dev/null 2>&1)
  if [ -s "$out" ]; then
    cat "$out"
  else
    printf '{"continue":true,"systemMessage":"the Stop hook produced no decision"}\n'
  fi
  rm -f "$out"
}

if [ -z "$pkg_dir" ] || [ -z "$state_dir" ]; then
  # No package resolvable from the shell side yet (or no intent id): let the
  # Elixir hook make the "no package" decision itself.
  run_mix ""
  exit 0
fi

non_regular="$(find -P "$pkg_dir" -mindepth 1 ! -type f ! -type d -print 2>/dev/null)"

if [ -n "$non_regular" ]; then
  run_mix ""
  exit 0
fi

head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo "no-head")"
bytes_hash="$(
  find -P "$pkg_dir" -type f -print 2>/dev/null |
    while IFS= read -r file; do
      rel="${file#"$pkg_dir"/}"
      printf '%s  %s\n' "$(shasum -a 256 "$file" | awk '{print $1}')" "$rel"
    done |
    LC_ALL=C sort |
    shasum -a 256 | awk '{print $1}'
)"
skip_key="${head_sha}:${bytes_hash}"

# hook-state.json (Elixir's source of truth) holds both the skip key and
# the last decision it produced for it; read it with python3 (guaranteed on
# PATH once KOGEN_SHAPING_TOOLCHAIN_PATH is applied above) rather than
# parsing JSON by hand in POSIX sh.
hook_state_file="$state_dir/hook-state.json"

if [ -f "$hook_state_file" ]; then
  cached="$($PYTHON_BIN -c '
import json, sys

path, want_key = sys.argv[1], sys.argv[2]
try:
    with open(path) as handle:
        state = json.load(handle)
except Exception:
    sys.exit(1)

decision = state.get("decision")
if state.get("skip_key") == want_key and decision is not None:
    print(json.dumps(decision))
else:
    sys.exit(1)
' "$hook_state_file" "$skip_key" 2>/dev/null)"

  if [ -n "$cached" ]; then
    printf '%s\n' "$cached"
    exit 0
  fi
fi

run_mix "$skip_key"
