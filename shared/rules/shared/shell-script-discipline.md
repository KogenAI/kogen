# Shell Script Authoring Discipline

Every `.sh` file: `#!/usr/bin/env bash` + `set -euo pipefail` on line 2.

Quote all expansions: `"$var"`, `"${arr[@]}"`. Empty-array-safe splice: `"${ARR[@]+"${ARR[@]}"}"`

Explicit exit codes: 0 = ok, 2 = usage error, 127 = binary missing.

mktemp → `TMP=$(mktemp)` + `trap 'rm -f "$TMP"' EXIT` immediately after.

Subprocess env isolation: `env -u SECRET_KEY_BASE -u CLAUDECODE exec subcmd` — strip sensitive vars before exec.

❌ `subcmd $arg`
✅ `env -u SECRET_KEY "subcmd" "$arg"`

Agent Bash-command discipline (forbidden tokens, COMMON_FLAGS, ports) — see the Bash-command discipline rules in this prompt.

## Derive Root, Never Hardcode

Codegen root differs per machine/OS (Linux servers + operator Macs). NOTHING hardcodes it.

✅ `CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` ← derive from the script's own location
❌ `CODEGEN_DIR="$HOME/Areas/Optimum/codegen"` ← hardcoded; breaks on every other box

Caveat: no blind `/..` — derivation depends on the script's installed location relative to the root. A script two levels deep derives differently than one at root. `OCG_CODEGEN_DIR` is an override for edge cases, not the default path. See `context/deployment-topology.md`.

## Verdict String Routing through Case Arms

When a helper function generates verdict strings and feeds a `case "$verdict"` block with an `INCONCLUSIVE:*` arm, adding new `INCONCLUSIVE:<reason>` strings requires **zero edits to the case block**. The existing `INCONCLUSIVE:*)` pattern arm absorbs all new substrings automatically (shell glob match).

✅ Reclassify at the source (where verdict is generated).
❌ Edit each downstream case consumer.

Example: `run_phoenix_render_check` returns `INCONCLUSIVE:render-check-cmd-missing` or `INCONCLUSIVE:render-check-cmd-failed`. The calling case block at `phoenix-dev-gate.sh:414` and `:675` already has `INCONCLUSIVE:*)` arms routing all INCONCLUSIVE variants correctly — no case edits needed when new reasons are added.
