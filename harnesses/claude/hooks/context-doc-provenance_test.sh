#!/usr/bin/env bash
# context-doc-provenance_test.sh — scan context docs for raw line-cites and
# provenance contradictions (a doc calling a backticked path hand-authored /
# NOT symlinked / edit directly while git reports the path as a 120000 symlink).
#
# Two violation classes:
#   (a) raw line-number citation: <path>.<ext>:<N>, "line <N>", :<N>-<N>
#   (b) provenance contradiction: contradiction-phrase NEAR a backticked path
#       whose `git ls-files --stage` mode is 120000 (symlink)
#
# Hermetic: fixture-driven via synthetic temp .md files. Also scans the real
# corpus (context/*.md + PROJECT_CONTEXT.md). No positional args.
# Exit 0 → all pass. Exit 1 → one or more failures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
fail=0

# Detect raw line-number citations in a single file. Echoes matching lines.
detect_line_cites() {
    local file="$1"
    grep -nE '\.(sh|md|j2|py|yaml|txt|exs|ex):[0-9]+|line [0-9]+|:[0-9]+-[0-9]+' "$file" 2>/dev/null || true
}

# Detect provenance contradiction in a single file. Echoes a count.
# git_mode_fn: function taking <path>, echoing the stage mode (injected so
# fixtures can shim git without touching the real index).
detect_provenance_contradiction() {
    local file="$1"
    local git_mode_fn="$2"
    local found=0 line p mode
    while IFS= read -r line; do
        p="$(printf '%s' "$line" | grep -oE '`[A-Za-z0-9_./-]+`' | head -1 | tr -d '`')" || true
        [ -z "$p" ] && continue
        mode="$("$git_mode_fn" "$p")"
        [ "$mode" = "120000" ] && found=$((found + 1))
    done < <(grep -iE 'hand-authored|not symlinked|edit directly|do not regenerate' "$file" 2>/dev/null || true)
    printf '%d\n' "$found"
}

# Real-index git mode lookup (real-corpus scan).
real_git_mode() {
    git -C "$CODEGEN_DIR" ls-files --stage "$1" 2>/dev/null | awk '{print $1}'
}

# ── Real-corpus scan: context/*.md + PROJECT_CONTEXT.md + shared/rules/**/*.md ─
# (a) line-cites
{
    corpus_fail=0
    for f in "$CODEGEN_DIR"/context/*.md "$CODEGEN_DIR/PROJECT_CONTEXT.md"; do
        [ -f "$f" ] || continue
        if detect_line_cites "$f" | grep -q .; then
            printf 'FAIL: raw line-citation in %s\n' "$f"
            detect_line_cites "$f"
            corpus_fail=$((corpus_fail + 1))
        fi
    done
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if detect_line_cites "$f" | grep -q .; then
            printf 'FAIL: raw line-citation in %s\n' "$f"
            detect_line_cites "$f"
            corpus_fail=$((corpus_fail + 1))
        fi
    done < <(find "$CODEGEN_DIR/shared/rules" -name '*.md')
    if [ "$corpus_fail" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + corpus_fail)); fi
}
# (b) provenance contradictions
{
    corpus_fail=0
    for f in "$CODEGEN_DIR"/context/*.md "$CODEGEN_DIR/PROJECT_CONTEXT.md"; do
        [ -f "$f" ] || continue
        n="$(detect_provenance_contradiction "$f" real_git_mode)"
        if [ "$n" -gt 0 ]; then
            printf 'FAIL: provenance contradiction in %s (%d)\n' "$f" "$n"
            corpus_fail=$((corpus_fail + 1))
        fi
    done
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        n="$(detect_provenance_contradiction "$f" real_git_mode)"
        if [ "$n" -gt 0 ]; then
            printf 'FAIL: provenance contradiction in %s (%d)\n' "$f" "$n"
            corpus_fail=$((corpus_fail + 1))
        fi
    done < <(find "$CODEGEN_DIR/shared/rules" -name '*.md')
    if [ "$corpus_fail" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + corpus_fail)); fi
}

# ── Synthetic fixtures ───────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Fixture git-mode shim: 120000 for a path named "fake-symlink", 100644 else.
fixture_git_mode() {
    case "$1" in
    *fake-symlink*) printf '120000\n' ;;
    *) printf '100644\n' ;;
    esac
}

# F1: line-cite .sh:42 → detected
printf 'See foo.sh:42 for details.\n' >"$TMP_DIR/f1.md"
if detect_line_cites "$TMP_DIR/f1.md" | grep -q .; then pass=$((pass + 1)); else
    printf 'FAIL: F1 .sh:NN not detected\n'
    fail=$((fail + 1))
fi

# F2: "line 109" → detected
printf 'The rule at line 109 says X.\n' >"$TMP_DIR/f2.md"
if detect_line_cites "$TMP_DIR/f2.md" | grep -q .; then pass=$((pass + 1)); else
    printf 'FAIL: F2 line NN not detected\n'
    fail=$((fail + 1))
fi

# F3: range :120-130 → detected
printf 'See block :120-130 here.\n' >"$TMP_DIR/f3.md"
if detect_line_cites "$TMP_DIR/f3.md" | grep -q .; then pass=$((pass + 1)); else
    printf 'FAIL: F3 range not detected\n'
    fail=$((fail + 1))
fi

# F4: clean doc → no detection
printf 'A clean sentence referencing a file by name only.\n' >"$TMP_DIR/f4.md"
if detect_line_cites "$TMP_DIR/f4.md" | grep -q .; then
    printf 'FAIL: F4 clean doc flagged\n'
    fail=$((fail + 1))
else pass=$((pass + 1)); fi

# F5: provenance contradiction on a 120000 path → detected
printf 'The file `fake-symlink` is hand-authored, NOT symlinked — edit directly.\n' >"$TMP_DIR/f5.md"
if [ "$(detect_provenance_contradiction "$TMP_DIR/f5.md" fixture_git_mode)" -gt 0 ]; then pass=$((pass + 1)); else
    printf 'FAIL: F5 contradiction not detected\n'
    fail=$((fail + 1))
fi

# F6: hand-authored claim on a non-symlink (100644) path → no contradiction
printf 'The file `real-file.md` is hand-authored — edit directly.\n' >"$TMP_DIR/f6.md"
if [ "$(detect_provenance_contradiction "$TMP_DIR/f6.md" fixture_git_mode)" -eq 0 ]; then pass=$((pass + 1)); else
    printf 'FAIL: F6 false contradiction on non-symlink\n'
    fail=$((fail + 1))
fi

# F7: rule-file-style line-cite mod.py:329 → detected
printf 'See mod.py:329 for the flag.\n' >"$TMP_DIR/f7.md"
if detect_line_cites "$TMP_DIR/f7.md" | grep -q .; then pass=$((pass + 1)); else
    printf 'FAIL: F7 rule-file .py:NN not detected\n'
    fail=$((fail + 1))
fi

# F8: clean rule-file text → no detection
printf 'A rule referencing run-tests.sh by name only, no line number.\n' >"$TMP_DIR/f8.md"
if detect_line_cites "$TMP_DIR/f8.md" | grep -q .; then
    printf 'FAIL: F8 clean rule file flagged\n'
    fail=$((fail + 1))
else pass=$((pass + 1)); fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -gt 0 ] && exit 1
exit 0
