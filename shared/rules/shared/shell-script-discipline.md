# Shell Script Authoring Discipline

Every `.sh` file: `#!/usr/bin/env bash` shebang, immediately followed by `set -euo pipefail`.

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

New `INCONCLUSIVE:<reason>` strings need zero case-block edits — existing `INCONCLUSIVE:*)` arm glob-matches all substrings. Reclassify at the source, not each consumer.

## Heredoc Inside Command Substitution — Quote Parsing

A heredoc nested inside `$()`/backticks still has its body quote-parsed by the OUTER shell for balancing — a `case` with single-quoted patterns inside causes outer-shell syntax errors. Fix: avoid single-quoted patterns in nested heredoc bodies; use quote-neutral test forms — `[ -z "$_line" ] && _skip=true` in place of a `case`/`'')` pattern arm.

## POSIX Portable String-Prefix Check

❌ `echo "$_line" | grep -q '^#'` ← subshell overhead, fragile in pipefail
✅ `[ "${_line#\#}" != "$_line" ]` ← parameter expansion, no subshell, portable POSIX across bash/sh/dash.

## pipefail + Early-Exit Consumer → 141 on a MATCH

`pipefail` + early-exit consumer (`grep -q`, `head -n1`, `awk '…{exit}'`) on a still-writing producer → producer SIGPIPEs → 141 even on real match; consumed status reads match as miss.

Discriminator: producer OUTPUT size — fires only if output > pipe buffer (~64 KB). Small-output producer never opens the window.

❌ `x=$(printf '%s\n' "$big" | head -n1)` → ✅ `x=${big%%$'\n'*}`
❌ `x=$(printf '%s\n' "$big" | awk '/^---$/{exit}{print}')` → ✅ `x=$(awk '/^---$/{exit}{print}' "$file")` (reads file)

No pipe-free form → capture then test: `hit=$(producer); [ -n "$hit" ] && ...`. Don't mass-rewrite every `| grep -q` — only large-output/status-consumed sites.

## Trap State Is File-Scope, Never `local`

Trap body runs independent context — `local` in caller is invisible to it. Flag mutated by trap + read by main loop → file-scope var above the fn.
