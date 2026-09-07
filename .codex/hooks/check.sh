#!/bin/sh
# Kogen's Codex Stop hook. It runs only for the Developer role, records the
# provider-free Check result, and blocks a failed turn so Codex can fix it.
set -u

if [ "${KOGEN_ROLE:-}" != "developer" ]; then
  printf '{"continue":true}\n'
  exit 0
fi

input="$(cat)"

extract_field() {
  field="$1"
  printf '%s' "$input" |
    sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" |
    head -n 1
}

json_escape() {
  printf '%s' "$1" |
    awk '
      BEGIN {
        for (code = 1; code < 32; code++) {
          escaped[sprintf("%c", code)] = sprintf("\\u%04x", code)
        }

        escaped[sprintf("%c", 8)] = "\\b"
        escaped[sprintf("%c", 9)] = "\\t"
        escaped[sprintf("%c", 12)] = "\\f"
        escaped[sprintf("%c", 13)] = "\\r"
        escaped[sprintf("%c", 34)] = sprintf("%c%c", 92, 34)
        escaped[sprintf("%c", 92)] = sprintf("%c%c", 92, 92)
      }

      {
        if (NR > 1) {
          printf "\\n"
        }

        for (i = 1; i <= length($0); i++) {
          char = substr($0, i, 1)

          if (char in escaped) {
            printf "%s", escaped[char]
          } else {
            printf "%s", char
          }
        }
      }
    '
}

session_id="$(extract_field session_id)"

if [ -z "$session_id" ]; then
  printf '{"decision":"block","reason":"Kogen Stop Check did not receive the Developer session id."}\n'
  exit 0
fi

root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf '{"decision":"block","reason":"Kogen Stop Check could not find the Git repository."}\n'
  exit 0
}
cd "$root" || {
  printf '{"decision":"block","reason":"Kogen Stop Check could not enter the Git repository."}\n'
  exit 0
}

runtime_dir="$root/.kogen/runtime"
mkdir -p "$runtime_dir" || exit 1
record="$runtime_dir/verification.json"
history="$runtime_dir/verification-history.jsonl"
check_log="$runtime_dir/stop-check.log"

candidate=""
candidate_error=""
tmp_index="$(mktemp "${TMPDIR:-/tmp}/kogen-hook-index.XXXXXX")" || candidate_error="could not create private Git index"

if [ -z "$candidate_error" ]; then
  rm -f "$tmp_index"
  index_path="$(git rev-parse --git-path index 2>&1)" || candidate_error="$index_path"
fi

if [ -z "$candidate_error" ] && ! cp "$index_path" "$tmp_index" 2>/dev/null; then
  candidate_error="could not copy Git index"
fi

if [ -z "$candidate_error" ] && ! GIT_INDEX_FILE="$tmp_index" git add -A >"$check_log" 2>&1; then
  candidate_error="git add -A failed: $(tail -n 20 "$check_log")"
fi

if [ -z "$candidate_error" ]; then
  candidate="$(GIT_INDEX_FILE="$tmp_index" git write-tree 2>&1)" || candidate_error="$candidate"
fi

rm -f "${tmp_index:-}"

if [ -z "$candidate_error" ] && make -C "$root" check >"$check_log" 2>&1; then
  status="passed"
  exit_code=0
  reason_raw="$(tail -n 40 "$check_log")"
else
  status="failed"
  exit_code=1
  reason_raw="${candidate_error:-$(tail -n 40 "$check_log")}"
fi

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
candidate_esc="$(json_escape "$candidate")"
session_esc="$(json_escape "$session_id")"
reason_esc="$(json_escape "$reason_raw")"
record_line="$(printf '{"candidate":"%s","status":"%s","target":"check","session_id":"%s","exit_code":%s,"finished_at":"%s","reason":"%s"}' "$candidate_esc" "$status" "$session_esc" "$exit_code" "$finished_at" "$reason_esc")"

printf '%s\n' "$record_line" >"$record"
printf '%s\n' "$record_line" >>"$history"

if [ "$exit_code" -ne 0 ]; then
  printf '{"decision":"block","reason":"Kogen Stop Check failed. Read .kogen/runtime/stop-check.log, fix the Candidate, and finish only after this hook passes."}\n'
else
  printf '{"continue":true}\n'
fi
