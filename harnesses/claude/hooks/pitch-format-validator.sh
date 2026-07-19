#!/usr/bin/env bash
# pitch-format-validator.sh — Stop hook that validates ## Questions / ## Answers /
# status markers (YAML frontmatter `status:`, dual-read with the legacy
# `> Status:` blockquote) in the active pitch file for shape, refactor, and
# ops sessions.
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: shape|refactor|ops
# harnesses: all
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Blocks Stop when the active pitch file (last Write/Edit/MultiEdit on
# codegen/pitches/*.md in the session transcript) contains a malformed
# ## Questions block, a bad > Status: value, or a stray ## Answers Q-binding
# that has no matching Question heading.
#
# Skip (exit 0) when:
#   - STOP_HOOK_ACTIVE=true (recursion guard)
#   - role is not shape, refactor, or ops
#   - TRANSCRIPT_PATH unset or unreadable
#   - No pitch file resolved from transcript
#   - Pitch file is unreadable
#   - No ## Questions heading in pitch (optional block — skip)
#
# Validation rules (anchors only — never prose content):
#   (a) YAML frontmatter `status:` key present (leading ---...--- block) OR
#       legacy `> Status:` line present → value MUST be SKELETON, SHAPING, or
#       SHAPED. Frontmatter is checked first; falls back to the blockquote
#       form for pre-existing pitches with no frontmatter (dual-read).
#   (b) ## Questions heading present → MUST have ≥1 ### Q<n>: heading AND each
#       Q heading must be followed by ≥2 "- **<letter>)**" option bullets before
#       the next ### or ## heading
#   (c) BOTH ## Questions AND ## Answers present → every "### Q<n>: " binding
#       line under ## Answers MUST have a matching Q<n> in ## Questions.
#       (Orphan ## Answers with no ## Questions is ALLOWED — resolved+deleted.)

set -euo pipefail

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

session_id="${SESSION_ID:-unknown}"

debug_log pitch-format-validator "session=$session_id"

# Recursion guard
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    debug_log pitch-format-validator "skip: stop_hook_active"
    exit 0
fi

# Only enforce for shape / refactor / ops
role=$(resolve_role)
case "$role" in
shape | refactor | ops) ;;
*)
    debug_log pitch-format-validator "skip: role=$role not shape/refactor/ops"
    exit 0
    ;;
esac

# Transcript guard
if [ -z "${TRANSCRIPT_PATH:-}" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
    debug_log pitch-format-validator "skip: no transcript"
    exit 0
fi

# Resolve active pitch file from transcript
pitch=$(pitch_from_transcript)

if [ -z "$pitch" ]; then
    debug_log pitch-format-validator "skip: no pitch found in transcript"
    exit 0
fi

debug_log pitch-format-validator "resolved pitch=$pitch"

# Pitch must be readable
if [ ! -r "$pitch" ]; then
    debug_log pitch-format-validator "skip: pitch not readable: $pitch"
    exit 0
fi

pitch_content=$(cat "$pitch")

# ── Validation (a): status value (frontmatter status: first, dual-read with
# legacy > Status: blockquote) ──────────────────────────────────────────────
# Frontmatter block is the leading "---"..."---" span (opening delimiter MUST
# be the first line). Extract "status:" from inside it, else fall back to the
# legacy "> Status:" blockquote line.
status_value=""
status_source=""

first_line=${pitch_content%%$'\n'*}
if [ "$first_line" = "---" ]; then
    frontmatter_block=$(awk 'NR==1{next} /^---$/{exit} {print}' "$pitch")
    fm_status_line=$(printf '%s\n' "$frontmatter_block" | grep -m1 '^status:' || true)
    if [ -n "$fm_status_line" ]; then
        status_value=$(printf '%s' "$fm_status_line" | sed 's/^status:[[:space:]]*//' | tr -d '[:space:]')
        status_source="frontmatter status:"
    fi
fi

if [ -z "$status_value" ]; then
    status_line=$(printf '%s' "$pitch_content" | grep -m1 '^> Status:' || true)
    if [ -n "$status_line" ]; then
        status_value=$(printf '%s' "$status_line" | sed 's/^> Status:[[:space:]]*//' | tr -d '[:space:]')
        status_source="legacy \`> Status:\`"
    fi
fi

if [ -n "$status_value" ]; then
    case "$status_value" in
    SKELETON | SHAPING | SHAPED)
        debug_log pitch-format-validator "status=$status_value ok ($status_source)"
        ;;
    *)
        reason="pitch-format-validator: invalid ${status_source} value \"${status_value}\" in ${pitch}. Allowed values: SKELETON, SHAPING, SHAPED. Re-emit the status field with one of those values."
        debug_log pitch-format-validator "BLOCK: bad status=$status_value ($status_source)"
        block "$reason"
        exit 0
        ;;
    esac
fi

# ── Validation (b) + (c): ## Questions / ## Answers blocks ─────────────────

has_questions=$(printf '%s' "$pitch_content" | grep -c '^## Questions' || true)
has_answers=$(printf '%s' "$pitch_content" | grep -c '^## Answers' || true)

# No ## Questions block → skip Q/A validation
if [ "$has_questions" -eq 0 ]; then
    debug_log pitch-format-validator "allow: no ## Questions block"
    exit 0
fi

# ── (b): ## Questions must have ≥1 ### Q<n>: heading ───────────────────────
# Extract content of the ## Questions section (up to next ## heading)
questions_section=$(printf '%s' "$pitch_content" | awk '/^## Questions/{found=1; next} found && /^## /{found=0} found{print}')

q_headings=$(printf '%s' "$questions_section" | grep -E '^### Q[0-9]+:' || true)
q_count=$(printf '%s' "$q_headings" | grep -cE '^### Q[0-9]+:' || true)

if [ "$q_count" -eq 0 ]; then
    reason="pitch-format-validator: \`## Questions\` block in ${pitch} has no \`### Q<n>:\` headings. Each question must use \`### Q1:\`, \`### Q2:\`, etc. Re-emit the ## Questions/## Answers block following the pitch-format grammar."
    debug_log pitch-format-validator "BLOCK: no Q headings in Questions block"
    block "$reason"
    exit 0
fi

# ── (b): Each ### Q<n>: must have ≥2 "- **<letter>)**" option bullets ──────
# Walk through questions_section line by line, tracking current Q heading
# and counting option bullets.
in_q=false
current_q=""
bullet_count=0
block_reason=""

while IFS= read -r line; do
    if printf '%s' "$line" | grep -qE '^### Q[0-9]+:'; then
        # Finish checking previous Q if any
        if [ "$in_q" = "true" ] && [ "$bullet_count" -lt 2 ]; then
            block_reason="pitch-format-validator: question \`${current_q}\` in \`## Questions\` of ${pitch} has fewer than 2 option bullets (\`- **<letter>)**\`). Each question must have ≥2 concrete options. Re-emit the ## Questions/## Answers block following the pitch-format grammar."
            break
        fi
        in_q=true
        current_q=$(printf '%s' "$line" | sed 's/^### //')
        bullet_count=0
    elif printf '%s' "$line" | grep -qE '^\- \*\*[a-zA-Z]\)\*\*'; then
        if [ "$in_q" = "true" ]; then
            bullet_count=$((bullet_count + 1))
        fi
    fi
done <<EOF
$(printf '%s\n' "$questions_section")
EOF

# Check the last Q if we didn't break early
if [ -z "$block_reason" ] && [ "$in_q" = "true" ] && [ "$bullet_count" -lt 2 ]; then
    block_reason="pitch-format-validator: question \`${current_q}\` in \`## Questions\` of ${pitch} has fewer than 2 option bullets (\`- **<letter>)**\`). Each question must have ≥2 concrete options. Re-emit the ## Questions/## Answers block following the pitch-format grammar."
fi

if [ -n "$block_reason" ]; then
    debug_log pitch-format-validator "BLOCK: Q option bullet count < 2"
    block "$block_reason"
    exit 0
fi

# ── (c): ## Answers Q-bindings must match Questions ─────────────────────────
# Only if BOTH ## Questions AND ## Answers are present.
if [ "$has_answers" -gt 0 ]; then
    answers_section=$(printf '%s' "$pitch_content" | awk '/^## Answers/{found=1; next} found && /^## /{found=0} found{print}')

    # Extract Q<n> numbers from Questions headings
    q_nums=$(printf '%s' "$q_headings" | grep -oE 'Q[0-9]+' || true)

    # Extract Q<n> references from Answers headings (### Q<n>: ...)
    answer_q_refs=$(printf '%s' "$answers_section" | grep -oE '^### Q[0-9]+' | grep -oE 'Q[0-9]+' || true)

    # Check each answer Q-ref has a matching question
    while IFS= read -r ans_q; do
        [ -z "$ans_q" ] && continue
        if ! printf '%s' "$q_nums" | grep -qxF "$ans_q"; then
            reason="pitch-format-validator: \`## Answers\` in ${pitch} contains binding for \`${ans_q}\` but \`## Questions\` has no matching \`### ${ans_q}:\` heading. Remove the stray answer or add the corresponding question. Re-emit the ## Questions/## Answers block following the pitch-format grammar."
            debug_log pitch-format-validator "BLOCK: stray answer ref $ans_q"
            block "$reason"
            exit 0
        fi
    done <<EOF
$(printf '%s\n' "$answer_q_refs")
EOF
fi

debug_log pitch-format-validator "allow: pitch=$pitch"
exit 0
