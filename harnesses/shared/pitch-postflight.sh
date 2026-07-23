#!/usr/bin/env bash
# pitch-postflight.sh — foreground-compatible supervisor for an interactive
# Pi investigative session (shape/ops/experiment), running deterministic
# pitch-grammar postflight after a clean exit.
#
# Usage (sourced, then call):
#   source pitch-postflight.sh
#   run_pitch_postflight <mode> <repo-root> -- pi <pi-args...>
#
# Deliberately NOT the build-dispatch supervisor pattern (no `set -m`, no
# process-group TERM, no FIFO stderr capture) — that mechanism is
# specialized for BEAM descendant trees; this wrapper must preserve
# interactive foreground TTY access for Pi's own TUI. Terminal-generated
# signals (Ctrl-C) already reach the shared foreground process group
# natively; this trap only forwards a signal sent DIRECTLY to this shell
# (e.g. `kill -TERM <wrapper-pid>`) on to the child.
#
# Snapshot: before starting Pi, hash every codegen/pitches/{draft,ready,
# shipped}/*.md file (Node crypto — portable Darwin/Linux). After a ZERO Pi
# exit, call pitch-postflight.cjs with the snapshot to validate every
# changed/new pitch. A non-zero Pi exit is preserved AS-IS — postflight
# does not run (nothing to validate if the session itself failed/aborted).
# Temp state is removed on every exit path (trap EXIT).
set -uo pipefail

run_pitch_postflight() {
    local mode="$1"
    local root="$2"
    shift 2
    if [[ "${1:-}" != "--" ]]; then
        echo "pitch-postflight: usage: run_pitch_postflight <mode> <root> -- <cmd...>" >&2
        return 2
    fi
    shift

    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    local snap_file
    snap_file="$(mktemp)"
    trap "rm -f '$snap_file'" EXIT

    if ! command -v node >/dev/null 2>&1; then
        echo "pitch-postflight: node not found in PATH — cannot snapshot/validate pitches" >&2
        return 127
    fi

    node -e '
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const root = process.argv[1];
const out = process.argv[2];
function sha256(t) { return crypto.createHash("sha256").update(t, "utf8").digest("hex"); }
const snapshot = {};
const pitchesDir = path.join(root, "codegen", "pitches");
for (const sub of ["draft", "ready", "shipped"]) {
  const subDir = path.join(pitchesDir, sub);
  if (!fs.existsSync(subDir)) continue;
  for (const f of fs.readdirSync(subDir)) {
    if (!f.endsWith(".md")) continue;
    const rel = path.join("codegen", "pitches", sub, f);
    const full = path.join(root, rel);
    try {
      snapshot[rel] = sha256(fs.readFileSync(full, "utf8"));
    } catch {
      snapshot[rel] = "";
    }
  }
}
fs.writeFileSync(out, JSON.stringify(snapshot));
' "$root" "$snap_file"

    # Foreground-compatible spawn: no `set -m`, no subshell — the child
    # inherits this shell's stdio directly. Forward direct signals to the
    # child PID only (terminal-generated signals already reach the shared
    # foreground process group).
    #
    # Reset INT/TERM to default disposition in the child's own subshell
    # BEFORE backgrounding: when this wrapper's own shell was itself started
    # asynchronously (e.g. via `&` from a caller), POSIX shells inherit
    # SIG_IGN for SIGINT/SIGQUIT at shell startup — a plain `"$@" &` here
    # would silently propagate that inherited ignore to the child, so the
    # child's OWN `trap ... INT` could never override it (the POSIX
    # inherited-ignore carve-out applies to the child's shell startup, not
    # just this wrapper's). `(trap - INT TERM; exec "$@")` clears the
    # disposition in the child's own subshell before it execs, so the
    # child starts with a normal, override-able signal disposition.
    (
        trap - INT TERM
        exec "$@"
    ) &
    local child_pid=$!

    _pitch_postflight_forward() {
        local sig="$1"
        kill -s "$sig" "$child_pid" 2>/dev/null || true
    }
    trap '_pitch_postflight_forward TERM' TERM
    trap '_pitch_postflight_forward INT' INT

    local child_rc=0
    wait "$child_pid" || child_rc=$?

    trap "rm -f '$snap_file'" EXIT
    trap - TERM INT

    if [[ "$child_rc" -ne 0 ]]; then
        # Preserve the child's own exit — postflight does not run on a
        # failed/aborted session (nothing new to validate as successful).
        return "$child_rc"
    fi

    node "$self_dir/pitch-postflight.cjs" --mode "$mode" --root "$root" --snapshot "$snap_file"
    local postflight_rc=$?
    return "$postflight_rc"
}
