#!/usr/bin/env bash
# rule-self-ref-no-fetch_test.sh — detect self-referential backtick *.md fetch pointers
#
# A rule file included into a subagent prompt MUST NOT contain a backtick
# pointer used as a fetch/navigation instruction when that file is also
# included in the same role's transitive include set.
#
# A "fetch pointer" is a *.md backtick reference preceded by navigation
# words: see, read, per, check, in, via, →, apply, from, or at.
# Bare filepath mentions (e.g., "new section in `bash-discipline.md`")
# are NOT fetch pointers and are not flagged.
#
# Two error classes detected:
#   (a) Self-ref   — fetch-pointer target is co-inlined in the same role
#   (b) Dangling   — fetch-pointer target does not exist under shared/rules/
#
# Allowlist — targets exempt from both checks (recipes, downstream files,
# example placeholders, Hugo content, etc.):
#
# Usage: bash rule-self-ref-no-fetch_test.sh
# Exit 0 → all pass. Exit 1 → one or more failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SUBAGENTS_DIR="$CODEGEN_DIR/shared/subagents"
RULES_DIR="$CODEGEN_DIR/shared/rules"

pass=0
fail=0

# ── Allowlist ─────────────────────────────────────────────────────────────────
# Basenames of files that are legitimate external references even when not
# found under shared/rules/ and never co-inlined.
ALLOWLIST=(
    "INDEX.md"
    "_INDEX.md"
    "usage_rules_INDEX.md"
    "PLATFORM_INFO.md"
    "PROJECT_CONTEXT.md"
    "STYLE_GUIDE.md"
    "style-caveman-ultra.md"
    "hugo-deep.md"
    "git-commit-flow.md"
    "_index.md"
    "content/_index.md"
    "static-html-base-template.md"
    "static-vite-scaffold.md"
)

is_allowlisted() {
    local target="$1"
    local bn
    bn="$(basename "$target")"
    local item
    for item in "${ALLOWLIST[@]}"; do
        if [ "$bn" = "$(basename "$item")" ] || [ "$target" = "$item" ]; then
            return 0
        fi
    done
    # context/ files are always allowlisted
    if printf '%s' "$target" | grep -qE '^context/'; then
        return 0
    fi
    return 1
}

# Return true (0) if a backtick md reference looks like a fetch/nav pointer.
# Fetch pointer = preceded by a navigation word/symbol: see, read, per, check,
# via, apply, from, at, →
# "in `foo.md`" is flagged ONLY when preceded by navigational context, not
# when it means "inside the file" (e.g., "new section in `bash-discipline.md`").
# The distinguishing heuristic: if the word before "in" is a noun like "section",
# "content", "chapter", "edit", or "new", it's a filepath mention, not a fetch.
is_fetch_pointer() {
    local context_line="$1" # the full line containing the pointer
    local pointer="$2"      # the raw pointer text (no backticks)
    # Explicit navigation words before the backtick reference
    if printf '%s' "$context_line" | grep -qiE \
        '(^|[[:space:]])(see|read|per|check|via|apply|from|at)[[:space:]].*`'"$pointer"'`'; then
        return 0
    fi
    # Arrow pattern: "→ `foo.md`"
    if printf '%s' "$context_line" | grep -qE '→[[:space:]]*`'"$pointer"'`'; then
        return 0
    fi
    # "in `foo.md`" only when NOT preceded by "section", "content", "new", "edit"
    # i.e., "the pattern described in `foo.md`" is fetch; "new section in `foo.md`" is not
    if printf '%s' "$context_line" | grep -qiE '[[:space:]]in[[:space:]]`'"$pointer"'`'; then
        # Exclude: "section in", "content in", "new X in", "edit X in"
        if printf '%s' "$context_line" | grep -qiE '(section|content|new|edit)[[:space:]].*in[[:space:]]`'"$pointer"'`'; then
            return 1 # filepath mention, not a fetch
        fi
        return 0
    fi
    return 1
}

# Extract all backtick *.md tokens from a file, paired with their source line.
# Outputs: POINTER<TAB>SOURCE_LINE
extract_md_pointers() {
    local file="$1"
    # For each line, extract all backtick-quoted *.md tokens and emit them
    # with their source line for context detection
    grep -nE '\`[a-zA-Z0-9_/.-]+\.md\`' "$file" 2>/dev/null | while IFS=: read -r lineno rest; do
        # Extract each token on this line
        printf '%s' "$rest" | grep -oE '\`[a-zA-Z0-9_/.-]+\.md\`' | while IFS= read -r token; do
            local tok="${token#\`}"
            tok="${tok%\`}"
            printf '%s\t%s\n' "$tok" "$rest"
        done
    done || true
}

# Resolve the transitive include set for a template (one level of partials).
# Outputs newline-separated list of include paths as they appear in templates,
# e.g. "rules/_core/cwd-discipline.md" or "subagents/_phoenix_developer_common.md.j2"
resolve_includes() {
    local template="$1"
    grep -oE "\{%[[:space:]]*include[[:space:]]*'([^']+)'[[:space:]]*%\}" "$template" |
        grep -oE "'[^']+'" | tr -d "'" 2>/dev/null || true
    # One-level recursion into subagent partials
    local partial
    while IFS= read -r partial; do
        if printf '%s' "$partial" | grep -qE '\.md\.j2$'; then
            local partial_path="$CODEGEN_DIR/shared/$partial"
            if [ -f "$partial_path" ]; then
                grep -oE "\{%[[:space:]]*include[[:space:]]*'([^']+)'[[:space:]]*%\}" "$partial_path" |
                    grep -oE "'[^']+'" | tr -d "'" 2>/dev/null || true
            fi
        fi
    done < <(grep -oE "\{%[[:space:]]*include[[:space:]]*'([^']+)'[[:space:]]*%\}" "$template" |
        grep -oE "'[^']+'" | tr -d "'" 2>/dev/null || true)
}

# Check one template for self-ref and dangling fetch pointers.
check_template() {
    local label="$1"
    local template="$2"
    local template_fail=0

    # Build the set of co-inlined rule file basenames
    local included_basenames=()
    local inc
    while IFS= read -r inc; do
        if printf '%s' "$inc" | grep -qE '^rules/'; then
            included_basenames+=("$(basename "$inc")")
        fi
    done < <(resolve_includes "$template")

    # Collect all prose files (template + included rule files)
    local prose_files=()
    prose_files+=("$template")
    while IFS= read -r inc; do
        if printf '%s' "$inc" | grep -qE '^rules/'; then
            local rule_path="$RULES_DIR/${inc#rules/}"
            if [ -f "$rule_path" ]; then
                prose_files+=("$rule_path")
            fi
        fi
    done < <(resolve_includes "$template")

    # Scan prose for fetch pointers
    local pfile
    for pfile in "${prose_files[@]}"; do
        [ -f "$pfile" ] || continue
        local pointer source_line
        while IFS=$'\t' read -r pointer source_line; do
            [ -z "$pointer" ] && continue

            # Allowlist check
            if is_allowlisted "$pointer"; then
                continue
            fi

            # Only flag if this looks like a fetch/nav pointer
            if ! is_fetch_pointer "$source_line" "$pointer"; then
                continue
            fi

            local bn_pointer
            bn_pointer="$(basename "$pointer")"

            # (a) Self-ref check
            local self_ref=false
            local inc_file
            for inc_file in "${included_basenames[@]}"; do
                if [ "$inc_file" = "$bn_pointer" ]; then
                    self_ref=true
                    break
                fi
            done

            if [ "$self_ref" = true ]; then
                printf 'FAIL: %s — self-ref fetch pointer `%s` targets co-inlined rule file\n' \
                    "$label" "$pointer"
                template_fail=$((template_fail + 1))
                fail=$((fail + 1))
                continue
            fi

            # (b) Dangling check — must exist under shared/rules/
            local candidate=""
            if printf '%s' "$pointer" | grep -q '/'; then
                candidate="$RULES_DIR/$pointer"
            else
                candidate=$(find "$RULES_DIR" -name "$bn_pointer" -type f 2>/dev/null | head -1 || true)
            fi

            if [ -z "$candidate" ] || [ ! -f "$candidate" ]; then
                printf 'FAIL: %s — dangling fetch pointer `%s` does not exist under shared/rules/\n' \
                    "$label" "$pointer"
                template_fail=$((template_fail + 1))
                fail=$((fail + 1))
            fi

        done < <(extract_md_pointers "$pfile")
    done

    if [ "$template_fail" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s — no self-ref or dangling fetch pointers\n' "$label"
        pass=$((pass + 1))
    fi
}

# ── Real template checks ──────────────────────────────────────────────────────

for tmpl in \
    "$SUBAGENTS_DIR/shared/committer.md.j2" \
    "$SUBAGENTS_DIR/shared/context-curator.md.j2" \
    "$SUBAGENTS_DIR/phoenix/developer-phoenix-backend.md.j2" \
    "$SUBAGENTS_DIR/phoenix/developer-phoenix-frontend.md.j2" \
    "$SUBAGENTS_DIR/phoenix/reviewer-phoenix.md.j2" \
    "$SUBAGENTS_DIR/phoenix/planner-phoenix.md.j2" \
    "$SUBAGENTS_DIR/static/developer-static.md.j2" \
    "$SUBAGENTS_DIR/static/reviewer-static.md.j2" \
    "$SUBAGENTS_DIR/static/planner-static.md.j2" \
    "$SUBAGENTS_DIR/_phoenix_developer_common.md.j2" \
    "$SUBAGENTS_DIR/_static_developer_common.md.j2"; do
    if [ -f "$tmpl" ]; then
        label="$(basename "$tmpl" .md.j2)"
        check_template "$label" "$tmpl"
    fi
done

# ── Synthetic-fixture tests ───────────────────────────────────────────────────

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Helper: run the core detection logic on fixture files.
# Writes "FAIL_COUNT:<n>" to stdout.
run_fixture_check() {
    local template="$1"
    local rules_root="$2"

    # Build included basenames
    local included_basenames=()
    local inc
    while IFS= read -r inc; do
        if printf '%s' "$inc" | grep -qE '^rules/'; then
            included_basenames+=("$(basename "$inc")")
        fi
    done < <(grep -oE "\{%[[:space:]]*include[[:space:]]*'([^']+)'[[:space:]]*%\}" "$template" |
        grep -oE "'[^']+'" | tr -d "'" 2>/dev/null || true)

    # Build prose files
    local prose_files=("$template")
    while IFS= read -r inc; do
        if printf '%s' "$inc" | grep -qE '^rules/'; then
            local rule_path="$rules_root/${inc#rules/}"
            if [ -f "$rule_path" ]; then
                prose_files+=("$rule_path")
            fi
        fi
    done < <(grep -oE "\{%[[:space:]]*include[[:space:]]*'([^']+)'[[:space:]]*%\}" "$template" |
        grep -oE "'[^']+'" | tr -d "'" 2>/dev/null || true)

    local count=0
    local pfile
    for pfile in "${prose_files[@]}"; do
        [ -f "$pfile" ] || continue
        local pointer source_line
        while IFS=$'\t' read -r pointer source_line; do
            [ -z "$pointer" ] && continue
            if is_allowlisted "$pointer"; then
                continue
            fi
            if ! is_fetch_pointer "$source_line" "$pointer"; then
                continue
            fi
            local bn_pointer
            bn_pointer="$(basename "$pointer")"

            local self_ref=false
            local inc_file
            for inc_file in "${included_basenames[@]}"; do
                if [ "$inc_file" = "$bn_pointer" ]; then
                    self_ref=true
                    break
                fi
            done

            if [ "$self_ref" = true ]; then
                count=$((count + 1))
                continue
            fi

            local candidate=""
            if printf '%s' "$pointer" | grep -q '/'; then
                candidate="$rules_root/$pointer"
            else
                candidate=$(find "$rules_root" -name "$bn_pointer" -type f 2>/dev/null | head -1 || true)
            fi

            if [ -z "$candidate" ] || [ ! -f "$candidate" ]; then
                count=$((count + 1))
            fi
        done < <(extract_md_pointers "$pfile")
    done
    printf 'FAIL_COUNT:%d\n' "$count"
}

# ── Test F1: Self-ref fetch pointer → FAIL ───────────────────────────────────
# A rule file included in the template has "See `testing.md` for details."
# and testing.md is also included in the template → self-ref.
{
    f1_rules="$TMP_DIR/f1/rules/stacks/phoenix"
    mkdir -p "$f1_rules"
    printf '# Testing\nSome testing content here.\n' >"$f1_rules/testing.md"
    # developer.md has a fetch pointer to testing.md
    printf '# Developer\nSee `testing.md` for test setup details.\n' >"$f1_rules/developer.md"

    f1_tmpl="$TMP_DIR/f1/template.md.j2"
    printf "{%% include 'rules/stacks/phoenix/testing.md' %%}\n{%% include 'rules/stacks/phoenix/developer.md' %%}\n" \
        >"$f1_tmpl"

    f1_out=$(run_fixture_check "$f1_tmpl" "$TMP_DIR/f1/rules")
    f1_count="${f1_out#FAIL_COUNT:}"

    if [ "$f1_count" -gt 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test F1 — self-ref fetch pointer detected\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test F1 — self-ref fetch pointer was NOT detected\n'
        fail=$((fail + 1))
    fi
}

# ── Test F2: Dangling fetch pointer → FAIL ───────────────────────────────────
# A rule file says "See `nonexistent-rule.md` for the pattern."
# and nonexistent-rule.md does not exist under shared/rules/
{
    f2_rules="$TMP_DIR/f2/rules/stacks/phoenix"
    mkdir -p "$f2_rules"
    printf '# Developer\nSee `nonexistent-rule.md` for the pattern.\n' \
        >"$f2_rules/developer.md"

    f2_tmpl="$TMP_DIR/f2/template.md.j2"
    printf "{%% include 'rules/stacks/phoenix/developer.md' %%}\n" >"$f2_tmpl"

    f2_out=$(run_fixture_check "$f2_tmpl" "$TMP_DIR/f2/rules")
    f2_count="${f2_out#FAIL_COUNT:}"

    if [ "$f2_count" -gt 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test F2 — dangling fetch pointer detected\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test F2 — dangling fetch pointer was NOT detected\n'
        fail=$((fail + 1))
    fi
}

# ── Test F3: Allowlisted pointer → PASS ──────────────────────────────────────
# `PROJECT_CONTEXT.md` is allowlisted — never flagged even if non-existent in rules/
{
    f3_rules="$TMP_DIR/f3/rules/stacks/phoenix"
    mkdir -p "$f3_rules"
    printf '# Developer\nRead `PROJECT_CONTEXT.md` for context.\n' >"$f3_rules/developer.md"

    f3_tmpl="$TMP_DIR/f3/template.md.j2"
    printf "{%% include 'rules/stacks/phoenix/developer.md' %%}\n" >"$f3_tmpl"

    f3_out=$(run_fixture_check "$f3_tmpl" "$TMP_DIR/f3/rules")
    f3_count="${f3_out#FAIL_COUNT:}"

    if [ "$f3_count" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test F3 — allowlisted pointer is exempt\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test F3 — allowlisted pointer incorrectly flagged (%d)\n' "$f3_count"
        fail=$((fail + 1))
    fi
}

# ── Test F4: Existing non-co-inlined rule ref as fetch pointer → also PASS ───
# `other-rule.md` exists under rules/ but is NOT co-inlined.
# A fetch pointer to it is NOT a self-ref and NOT dangling — should PASS.
{
    f4_rules="$TMP_DIR/f4/rules/stacks/phoenix"
    mkdir -p "$f4_rules"
    printf '# Other Rule\nSome content.\n' >"$f4_rules/other-rule.md"
    # developer.md has a fetch pointer to other-rule.md (exists, not co-inlined)
    printf '# Developer\nSee `other-rule.md` in the stacks docs.\n' >"$f4_rules/developer.md"

    f4_tmpl="$TMP_DIR/f4/template.md.j2"
    # Only includes developer.md, NOT other-rule.md
    printf "{%% include 'rules/stacks/phoenix/developer.md' %%}\n" >"$f4_tmpl"

    f4_out=$(run_fixture_check "$f4_tmpl" "$TMP_DIR/f4/rules")
    f4_count="${f4_out#FAIL_COUNT:}"

    if [ "$f4_count" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test F4 — existing non-co-inlined pointer is not flagged\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test F4 — valid external pointer incorrectly flagged (%d)\n' "$f4_count"
        fail=$((fail + 1))
    fi
}

# ── Test F5: Bare path mention (not fetch pointer) → PASS ────────────────────
# "new section in `bash-discipline.md`; symlink to..." — not a fetch pointer
# because the surrounding words don't match navigation patterns.
{
    f5_rules="$TMP_DIR/f5/rules/_core"
    mkdir -p "$f5_rules"
    printf '# Bash Discipline\nContent here.\n' >"$f5_rules/bash-discipline.md"
    # Curator rule mentions it as a file path reference, not a fetch instruction
    f5_curator="$TMP_DIR/f5/rules/roles"
    mkdir -p "$f5_curator"
    printf '# Curator\nEdit `bash-discipline.md`; symlink to shared/rules/.\n' \
        >"$f5_curator/curator.md"

    f5_tmpl="$TMP_DIR/f5/template.md.j2"
    printf "{%% include 'rules/_core/bash-discipline.md' %%}\n{%% include 'rules/roles/curator.md' %%}\n" \
        >"$f5_tmpl"

    f5_out=$(run_fixture_check "$f5_tmpl" "$TMP_DIR/f5/rules")
    f5_count="${f5_out#FAIL_COUNT:}"

    if [ "$f5_count" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test F5 — bare path mention is exempt (not a fetch pointer)\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test F5 — bare path mention incorrectly flagged as fetch pointer (%d)\n' "$f5_count"
        fail=$((fail + 1))
    fi
}

# ── Test F6: Arrow fetch pointer self-ref → FAIL ─────────────────────────────
# "→ `bash-discipline.md`" is a fetch pointer via arrow pattern
{
    f6_rules="$TMP_DIR/f6/rules/_core"
    mkdir -p "$f6_rules"
    printf '# Bash Discipline\nContent here.\n' >"$f6_rules/bash-discipline.md"
    f6_other="$TMP_DIR/f6/rules/shared"
    mkdir -p "$f6_other"
    # shell-discipline uses arrow pointer to bash-discipline
    printf '# Shell Discipline\nAgent discipline → `bash-discipline.md`.\n' \
        >"$f6_other/shell-discipline.md"

    f6_tmpl="$TMP_DIR/f6/template.md.j2"
    printf "{%% include 'rules/_core/bash-discipline.md' %%}\n{%% include 'rules/shared/shell-discipline.md' %%}\n" \
        >"$f6_tmpl"

    f6_out=$(run_fixture_check "$f6_tmpl" "$TMP_DIR/f6/rules")
    f6_count="${f6_out#FAIL_COUNT:}"

    if [ "$f6_count" -gt 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: Test F6 — arrow fetch pointer self-ref detected\n'
        pass=$((pass + 1))
    else
        printf 'FAIL: Test F6 — arrow fetch pointer self-ref was NOT detected\n'
        fail=$((fail + 1))
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
