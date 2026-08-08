#!/usr/bin/env bash
# role-boundary-parity_test.sh — drift-guard: reviewer rule-file "Your
# Boundaries" prose vs shared/enforcement/registry.yaml Bash-allowlist match regex.
#
# Enforcement (subagent-read-discipline.sh, reviewer-bash-allowlist.sh) is the
# backstop and is NEVER edited by this test. This test only guards that the
# hand-authored "upfront methodology" prose in shared/rules/roles/reviewer.md
# keeps mirroring the enforced allowlist tokens in registry.yaml — so the two
# never silently diverge.
#
# The committer half of this test (committer-bash-allowlist parity,
# committer.md prose-parity) was deleted along with the committer role
# entirely — commits are made by a deterministic script (codegen-commit),
# never by an agent, so there is no committer prose or committer allowlist
# left to keep in parity. See pitch "committing is deterministic, not a
# model call".
#
# Two independent parity directions:
#   (a) registry-parity — expected token still present in registry.yaml's match:
#       line for the hook (proves the test's own expectation still matches SoT)
#   (b) prose-parity     — expected token present in the rule .md (proves the
#       prompt mirrors SoT)
#
# Substring trap: git `log` is a substring of `codegen-log`. Prose assertions
# use word-boundary grep (`grep -qE '\b<token>\b'`) so "codegen-log" alone can
# never satisfy a check for the standalone git verb "log".
#
# Tests:
#   1  reviewer  registry-parity (all tokens present in reviewer-bash-allowlist match:)
#   2  reviewer  prose-parity    (all tokens present in reviewer.md, word-boundary)
#   5  clean fixture (registry + md both contain all tokens) → detector exit 0
#   8  detector exit code 1 on failure fixture
#   9  detector exit code 0 on clean fixture
#   10 substring safety: codegen-log present, standalone "log" absent → prose-parity FAILs for git log
#   11 reviewer registry match must NOT contain write verbs (commit/add) — reviewer stays read-only
#   12 missing registry.yaml file → fail loud (non-zero), never silently pass
#   13 word-boundary false-positive guard: token embedded in a larger word does not satisfy
#
# Usage: bash role-boundary-parity_test.sh
# Exit 0 → all pass. Exit 1 → one or more failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

REGISTRY="$CODEGEN_DIR/shared/enforcement/registry.yaml"
REVIEWER_MD="$CODEGEN_DIR/shared/rules/roles/reviewer.md"

pass=0
fail=0

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Expected token sets ───────────────────────────────────────────────────────
REVIEWER_TOKENS=(codegen-log diff status log show echo wc cat ls)
# Fixture-only token set — exercises the shared detector functions
# (match_line/token_in_registry_line/token_in_prose) against a synthetic
# read-write role fixture, independent of any real role's rule file.
FIXTURE_TOKENS=(codegen-log diff status log show commit add rm mv tag checkout switch branch restore reset echo wc cat ls)

# ── Reusable functions ────────────────────────────────────────────────────────

# match_line <registry_file> <hook_id>
# Extracts the first `match:` line after `- id: <hook_id>`.
match_line() {
    local registry_file="$1"
    local hook_id="$2"
    awk -v id="- id: $hook_id" '
    $0 == id { f = 1; next }
    f && /^- id:/ { exit }
    f && /match:/ { print; exit }
  ' "$registry_file"
}

# token_in_registry_line <line> <token>
# Fixed-string substring check against the match: line (regex source text).
token_in_registry_line() {
    local line="$1"
    local token="$2"
    printf '%s' "$line" | grep -qF -- "$token"
}

# token_in_prose <md_file> <token>
# Word-boundary check against rendered prose. Regular `\b` treats `-` as a
# non-word char, so a plain \b check on "log" false-matches inside
# "codegen-log". Use an explicit boundary class that also excludes hyphen, so
# a standalone git verb like "log" is never satisfied by the compound token
# "codegen-log".
token_in_prose() {
    local md_file="$1"
    local token="$2"
    grep -qE "(^|[^a-zA-Z0-9-])${token}([^a-zA-Z0-9-]|\$)" "$md_file"
}

# ── Test 1 (live): reviewer registry-parity ──────────────────────────────────
{
    line=$(match_line "$REGISTRY" "reviewer-bash-allowlist")
    missing=()
    for t in "${REVIEWER_TOKENS[@]}"; do
        token_in_registry_line "$line" "$t" || missing+=("$t")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: registry allowlist changed — token(s) %s no longer in reviewer-bash-allowlist\n' "${missing[*]}"
        fail=$((fail + 1))
    fi
}

# ── Test 2 (live): reviewer prose-parity ─────────────────────────────────────
{
    missing=()
    for t in "${REVIEWER_TOKENS[@]}"; do
        token_in_prose "$REVIEWER_MD" "$t" || missing+=("$t")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: rule file %s missing allowlist token(s): %s\n' "$REVIEWER_MD" "${missing[*]}"
        fail=$((fail + 1))
    fi
}

# ── Fixture: clean registry + md, all tokens present (synthetic read-write
# role, exercises the detector functions independent of any real role) ──────
make_clean_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    cat >"$dir/registry.yaml" <<'EOF'
- id: fixture-bash-allowlist
  generated: true
  match: "^\\s*(git\\s+(diff|status|log|show|commit|add|rm|mv|tag|checkout|switch|branch|restore|reset)\\b|codegen-log\\b|echo\\b|wc\\b|cat\\b|ls\\b)"
  role: fixture-role

- id: reviewer-bash-allowlist
  generated: true
  match: "(^|\\s|/)codegen-log\\b|^\\s*(git\\s+(diff|status|log|show)\\b|echo\\b|wc\\b|cat\\b|ls\\b)"
  role: reviewer-phoenix
EOF
    cat >"$dir/fixture.md" <<'EOF'
## Your Boundaries

Bash: git diff, status, log, show, commit, add, rm, mv, tag, checkout, switch,
branch, restore, reset, codegen-log, echo, wc, cat, ls.
EOF
    cat >"$dir/reviewer.md" <<'EOF'
## Your Boundaries

Bash: codegen-log, git diff, status, log, show, echo, wc, cat, ls.
EOF
}

# ── Test 5: clean fixture → all parity checks PASS ───────────────────────────
{
    t="$TMP_DIR/t5"
    make_clean_fixture "$t"
    line=$(match_line "$t/registry.yaml" "fixture-bash-allowlist")
    ok=1
    for tok in "${FIXTURE_TOKENS[@]}"; do
        token_in_registry_line "$line" "$tok" || ok=0
        token_in_prose "$t/fixture.md" "$tok" || ok=0
    done
    if [ "$ok" -eq 1 ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 5 — clean fixture should satisfy all parity checks\n'
        fail=$((fail + 1))
    fi
}

# ── Test 8: detector exit code 1 on failure fixture ──────────────────────────
{
    t="$TMP_DIR/t8"
    make_clean_fixture "$t"
    sed 's/commit|add/add/' "$t/registry.yaml" >"$t/registry.yaml.tmp" && mv "$t/registry.yaml.tmp" "$t/registry.yaml"

    rc=0
    (
        set -euo pipefail
        line=$(match_line "$t/registry.yaml" "fixture-bash-allowlist")
        for tok in "${FIXTURE_TOKENS[@]}"; do
            token_in_registry_line "$line" "$tok" || exit 1
        done
        exit 0
    ) || rc=$?

    if [ "$rc" -eq 1 ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 8 — detector should exit 1 on failure fixture, got exit %d\n' "$rc"
        fail=$((fail + 1))
    fi
}

# ── Test 9: detector exit code 0 on clean fixture ────────────────────────────
{
    t="$TMP_DIR/t9"
    make_clean_fixture "$t"

    rc=0
    (
        set -euo pipefail
        line=$(match_line "$t/registry.yaml" "fixture-bash-allowlist")
        for tok in "${FIXTURE_TOKENS[@]}"; do
            token_in_registry_line "$line" "$tok" || exit 1
            token_in_prose "$t/fixture.md" "$tok" || exit 1
        done
        exit 0
    ) || rc=$?

    if [ "$rc" -eq 0 ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 9 — detector should exit 0 on clean fixture, got exit %d\n' "$rc"
        fail=$((fail + 1))
    fi
}

# ── Test 10 (substring safety): codegen-log present, standalone "log" absent ─
{
    t="$TMP_DIR/t10"
    mkdir -p "$t"
    cat >"$t/fixture.md" <<'EOF'
## Your Boundaries

Bash: codegen-log, git diff, status, show, commit, add, rm, mv, tag,
checkout, switch, branch, restore, reset, echo, wc, cat, ls.
EOF
    # "log" (standalone git verb) intentionally omitted; only codegen-log present.
    # Assertion: word-boundary "log" must NOT match on this codegen-log-only fixture.
    if token_in_prose "$t/fixture.md" "log"; then
        printf 'FAIL: Test 10 — word-boundary "log" should NOT be satisfied by "codegen-log" alone\n'
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

# ── Test 11 (live): reviewer registry match must NOT contain write verbs ─────
{
    line=$(match_line "$REGISTRY" "reviewer-bash-allowlist")
    if printf '%s' "$line" | grep -qE '\b(commit|add)\b'; then
        printf 'FAIL: Test 11 — reviewer-bash-allowlist match line unexpectedly contains a write verb: %s\n' "$line"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

# ── Test 12: missing registry.yaml → fail loud, never silently pass ──────────
{
    t="$TMP_DIR/t12"
    mkdir -p "$t"
    rc=0
    (
        set -euo pipefail
        match_line "$t/registry.yaml" "fixture-bash-allowlist" >/dev/null
    ) 2>/dev/null || rc=$?

    if [ "$rc" -ne 0 ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 12 — missing registry.yaml should fail loud (non-zero), got exit 0\n'
        fail=$((fail + 1))
    fi
}

# ── Test 13: word-boundary false-positive guard ──────────────────────────────
{
    t="$TMP_DIR/t13"
    mkdir -p "$t"
    cat >"$t/fake.md" <<'EOF'
This mentions "restoration" and "addition" but never the standalone verbs.
EOF
    if token_in_prose "$t/fake.md" "restore" || token_in_prose "$t/fake.md" "add"; then
        printf 'FAIL: Test 13 — word-boundary check falsely matched a substring inside a larger word\n'
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

# ── Test 14 (live): reviewer.md must not FALSELY NARROW the real allowlist ──
# The incident this guards: reviewer.md once said "Nothing else — grep is out
# of scope" while the registry's match: line already permitted grep (and 19
# other read-only verbs). A reviewer that believes the false narrower prose
# misreads its own harness. Extract every bare-word verb token from the
# registry's match: alternation and require each to appear in reviewer.md's
# prose (word-boundary) — this is a STRICTER, FULLER check than Test 2's
# fixed REVIEWER_TOKENS subset, and catches drift Test 2 cannot: a NEW verb
# added to the registry that never makes it into the prose.
{
    line=$(match_line "$REGISTRY" "reviewer-bash-allowlist")
    # Extract bare alternation tokens: word chars only, each followed by \b
    # in the regex source (e.g. "grep\\b" -> "grep"). Skip multi-word/group
    # constructs (git\s+(...)) — those are covered by REVIEWER_TOKENS above.
    verbs=$(printf '%s' "$line" | grep -oE '[a-z_]+\\\\b' | sed 's/\\\\b$//' | sort -u)
    missing=()
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        token_in_prose "$REVIEWER_MD" "$v" || missing+=("$v")
    done <<<"$verbs"
    if [ "${#missing[@]}" -eq 0 ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 14 — reviewer.md prose is missing registry-permitted verb(s): %s (false narrowing — the prose claims a smaller surface than the hook actually allows)\n' "${missing[*]}"
        fail=$((fail + 1))
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
