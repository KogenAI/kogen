#!/bin/bash
# reviewer-no-file-mutation_test.sh — unit tests for reviewer-no-file-mutation.sh
#
# reviewer-no-file-mutation denies two WRITE FORMS across otherwise-allowed
# verbs (sed, awk — kept in reviewer-bash-allowlist for read-only text
# filtering): `sed -i`/`sed --in-place` in-place edits, and shell output
# redirection (`>`, `>>`, and the combined fd+stdout forms `&>`, `&>>`).
# reviewer-bash-allowlist already denies `tee`; this hook closes the two
# forms that slipped past it (Fault 7 / Move 8). A codegen-log write is
# bypassed unconditionally (is_codegen_log_write) since its heredoc body may
# narrate a redirect char as prose, never execute one. A redirect targeting
# exactly /dev/null is a discard, not a file write — it is excluded from the
# redirect branch (tests 9a-9e, 9g) so the extremely common `2>/dev/null`
# idiom (and its combined-form sibling `&> /dev/null`) is not falsely denied
# on ordinary read-only commands. `&>`/`&>>` targeting a real path DENY like
# their bare `>`/`>>` counterparts (tests 9, 9f) — an earlier regex excluded
# any `>` preceded by `&`, which falsely allowed both as a write bypass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/reviewer-no-file-mutation.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    local stdout
    stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

REVIEWER_PHOENIX='reviewer-phoenix'
REVIEWER_STATIC='reviewer-static'
BACKEND='developer-phoenix-backend'

# ── sed -i / sed --in-place: DENY ──────────────────────────────────────────

# 1. sed -i.bak → DENY
run_test "reviewer-phoenix sed -i.bak DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i.bak s/a/b/ lib/foo.ex\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# 2. sed -i (no suffix) → DENY
run_test "reviewer-static sed -i DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i s/a/b/ lib/foo.ex\"},\"agent_type\":\"$REVIEWER_STATIC\",\"agent_id\":\"abc\"}"

# 3. sed --in-place → DENY
run_test "reviewer-phoenix sed --in-place DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed --in-place s/a/b/ lib/foo.ex\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# ── shell output redirection: DENY ─────────────────────────────────────────

# 4. awk ... > file → DENY
run_test "reviewer-phoenix awk redirect to new file DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"awk '{print}' lib/foo.ex > lib/foo.ex.new\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# 5. printf ... >> file → DENY (append)
run_test "reviewer-static printf append redirect DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf 'x' >> log.txt\"},\"agent_type\":\"$REVIEWER_STATIC\",\"agent_id\":\"abc\"}"

# 6. printf ... >> file 2>&1 → DENY (real redirect plus fd-dup on the same line)
run_test "reviewer-phoenix printf append redirect with fd-dup DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf 'x' >> log.txt 2>&1\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# ── fd-dup forms are NOT redirection-to-file: ALLOW; combined &>/&>> forms
#    ARE redirection-to-file (target is a real path, not an fd) and must
#    DENY like bare >/>> — this is the bug this pitch repairs ────────────────

# 7. cmd 2>&1 → ALLOW (fd duplication, not a file write)
run_test "reviewer-phoenix fd-dup 2>&1 ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git diff 2>&1\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# 8. cmd 1>&2 → ALLOW (fd duplication)
run_test "reviewer-static fd-dup 1>&2 ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status 1>&2\"},\"agent_type\":\"$REVIEWER_STATIC\",\"agent_id\":\"abc\"}"

# 9. cmd &> out.log → DENY (combined redirect targeting a real file is still a
#    file write; a prior version of this hook's regex excluded any `>`
#    preceded by `&`, which falsely allowed this and &>> below)
run_test "reviewer-phoenix combined &> redirect to real file DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git log &> out.log\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# 9f. cmd &>> out.log → DENY (combined append redirect to a real file)
run_test "reviewer-static combined &>> append redirect to real file DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git log &>> out.log\"},\"agent_type\":\"$REVIEWER_STATIC\",\"agent_id\":\"abc\"}"

# 9g. cmd &> /dev/null → ALLOW (combined discard of both streams — not a file
#     write; the /dev/null exclusion applies here exactly as it does to `>`)
run_test "reviewer-phoenix combined &> /dev/null NOT falsely denied" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"some_cmd &> /dev/null\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# ── /dev/null redirect: ALLOW (discard, never a file write — the reviewer's
#    review-blocking false positive caught live during this pitch's review) ─

# 9a. cmd 2>/dev/null → ALLOW (stderr discard, an extremely common idiom —
#     this exact form falsely denied ordinary read-only grep/investigation
#     commands during review of this pitch)
run_test "reviewer-phoenix 2>/dev/null NOT falsely denied" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"grep -rn foo lib/ 2>/dev/null\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# 9b. cmd 1>/dev/null → ALLOW (stdout discard)
run_test "reviewer-static 1>/dev/null NOT falsely denied" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"some_cmd 1>/dev/null\"},\"agent_type\":\"$REVIEWER_STATIC\",\"agent_id\":\"abc\"}"

# 9c. cmd > /dev/null 2>&1 → ALLOW (discard both streams, space before target)
run_test "reviewer-phoenix > /dev/null 2>&1 NOT falsely denied" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"some_cmd > /dev/null 2>&1\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# 9d. cmd 2>/dev/null > realfile.txt → DENY (a REAL target is also present —
#     the /dev/null exclusion must not blanket-allow the whole command)
run_test "reviewer-static real target alongside /dev/null discard DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"some_cmd 2>/dev/null > realfile.txt\"},\"agent_type\":\"$REVIEWER_STATIC\",\"agent_id\":\"abc\"}"

# 9e. cmd > /dev/nullish → DENY (a DIFFERENT path that merely starts with the
#     /dev/null literal must still be treated as a real write target)
run_test "reviewer-phoenix distinct /dev/nullish path DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"some_cmd > /dev/nullish\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# ── read-only sed/awk/git: ALLOW (unaffected by this hook) ────────────────

# 10. sed -n (read-only) → ALLOW
run_test "reviewer-phoenix sed -n read-only ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -n '1,5p' lib/foo.ex\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# 11. git diff → ALLOW
run_test "reviewer-static git diff ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git diff lib/foo.ex\"},\"agent_type\":\"$REVIEWER_STATIC\",\"agent_id\":\"abc\"}"

# ── ignore_quoted: a `>` inside a quoted filter string is a MENTION, not a
#    redirection — must not be denied ─────────────────────────────────────

# 12. jq filter containing '>' inside single quotes → ALLOW
run_test "reviewer-phoenix jq filter with quoted > ALLOWED (mention, not invocation)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"jq '.a > 5' file.json\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

# ── codegen-log carve-out: a piped body narrating a redirect char is prose,
#    never executed — ALLOW unconditionally ────────────────────────────────

# 13. codegen-log body prose containing a redirect char → ALLOW
run_test "reviewer-static codegen-log body with redirect char prose ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf '%s' \\\"cmd > output.log for reference\\\" | codegen-log section --body @-\"},\"agent_type\":\"$REVIEWER_STATIC\",\"agent_id\":\"abc\"}"

# ── Pass-through: non-reviewer agents, non-Bash tool ───────────────────────

# 14. developer-phoenix-backend sed -i → ALLOW (not this hook's job)
run_test "non-reviewer sed -i ALLOWED (pass-through)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i s/a/b/ lib/foo.ex\"},\"agent_type\":\"$BACKEND\",\"agent_id\":\"abc\"}"

# 15. Write tool passes through (not Bash)
run_test "reviewer-phoenix Write tool ALLOWED (not Bash, different hook)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"lib/foo.ex\"},\"agent_type\":\"$REVIEWER_PHOENIX\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
