#!/usr/bin/env bash
# Test: dual-render produces @-imports for claude, → See pointers for pi.
# Usage: bash test_dual_render.sh
# Exit 0 = pass, non-zero = fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$SCRIPT_DIR/test_fixtures/dual_render.md.j2"

# Stub OCG_CONTEXT_DIR to a temp dir (fixture has no {% include %} calls).
export OCG_CONTEXT_DIR="${TMPDIR:-/tmp}/ocg_test_context_$$"
mkdir -p "$OCG_CONTEXT_DIR"

claude_out=$("$SCRIPT_DIR/process_template.py" "$FIXTURE" claude false)
pi_out=$("$SCRIPT_DIR/process_template.py" "$FIXTURE" pi false)

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

# Pi: must contain → See lines.
if ! echo "$pi_out" | grep -q "→ See \`context/rules/_core/output-style.md\`"; then
    echo "FAIL: pi mode missing → See for style-caveman-ultra.md"
    fail=1
fi
if ! echo "$pi_out" | grep -q "→ See \`context/rules/_core/session-log.md\`"; then
    echo "FAIL: pi mode missing → See for session-management.md"
    fail=1
fi

# Pi: must NOT contain @ lines.
if echo "$pi_out" | grep -q "^@"; then
    echo "FAIL: pi mode contains @-import line (should not)"
    fail=1
fi

# Both: shared body text.
for out_var in "$claude_out" "$pi_out"; do
    if ! echo "$out_var" | grep -q "Body text that appears in both modes."; then
        echo "FAIL: shared body text missing"
        fail=1
    fi
done

# Diff: only difference should be @-vs-→See lines.
diff_lines=$(diff <(echo "$claude_out") <(echo "$pi_out") | grep "^[<>]" | grep -v "^[<>] $" || true)
echo "--- diff (changed lines only) ---"
echo "$diff_lines"
echo "---------------------------------"

rm -rf "$OCG_CONTEXT_DIR"

pass=$(( fail == 0 ? 1 : 0 ))
fail=$(( fail > 0 ? 1 : 0 ))
echo "$pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
    echo "PASS: dual-render produces correct @-imports (claude) and → See pointers (pi)"
    exit 0
else
    exit 1
fi
