#!/usr/bin/env bash
# Test: dual-render produces @-imports for claude, → See pointers for codex.
# Usage: bash test_dual_render.sh
# Exit 0 = pass, non-zero = fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$SCRIPT_DIR/test_fixtures/dual_render.md.j2"

# Stub OCG_CONTEXT_DIR to a temp dir (fixture has no {% include %} calls).
export OCG_CONTEXT_DIR="${TMPDIR:-/tmp}/ocg_test_context_$$"
mkdir -p "$OCG_CONTEXT_DIR"

claude_out=$("$SCRIPT_DIR/process_template.py" "$FIXTURE" claude false)
codex_out=$("$SCRIPT_DIR/process_template.py" "$FIXTURE" codex false)

fail=0

# Claude: must contain @ lines.
if ! echo "$claude_out" | grep -q "^@context/rules/_core/output-style.md"; then
    echo "FAIL: claude mode missing @-import for style-caveman-ultra.md"
    fail=1
fi
if ! echo "$claude_out" | grep -q "^@context/rules/_core/session-log.md"; then
    echo "FAIL: claude mode missing @-import for session-management.md"
    fail=1
fi

# Claude: must NOT contain → See lines.
if echo "$claude_out" | grep -q "→ See"; then
    echo "FAIL: claude mode contains → See line (should not)"
    fail=1
fi

# Codex: must contain → See lines.
if ! echo "$codex_out" | grep -q "→ See \`context/rules/_core/output-style.md\`"; then
    echo "FAIL: codex mode missing → See for style-caveman-ultra.md"
    fail=1
fi
if ! echo "$codex_out" | grep -q "→ See \`context/rules/_core/session-log.md\`"; then
    echo "FAIL: codex mode missing → See for session-management.md"
    fail=1
fi

# Codex: must NOT contain @ lines.
if echo "$codex_out" | grep -q "^@"; then
    echo "FAIL: codex mode contains @-import line (should not)"
    fail=1
fi

# Both: shared body text.
for out_var in "$claude_out" "$codex_out"; do
    if ! echo "$out_var" | grep -q "Body text that appears in both modes."; then
        echo "FAIL: shared body text missing"
        fail=1
    fi
done

# Diff: only difference should be @-vs-→See lines.
diff_lines=$(diff <(echo "$claude_out") <(echo "$codex_out") | grep "^[<>]" | grep -v "^[<>] $" || true)
echo "--- diff (changed lines only) ---"
echo "$diff_lines"
echo "---------------------------------"

rm -rf "$OCG_CONTEXT_DIR"

if [ $fail -eq 0 ]; then
    echo "PASS: dual-render produces correct @-imports (claude) and → See pointers (codex)"
    exit 0
else
    exit 1
fi
