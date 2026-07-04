#!/usr/bin/env bash
# context-index-coverage_test.sh — assert PROJECT_CONTEXT.md Domain table covers
# the full context/ tree and that context/ holds no non-.md clutter.
#   (a) every context/*.md basename appears in the PROJECT_CONTEXT.md Domain table
#   (b) context/ contains no non-.md files (.bak, .DS_Store, swapfiles, etc.)
#   (c) every context/*.md contains a `## Trigger Keywords` section
#   (d) each context/*.md in-file Trigger Keywords set == its PROJECT_CONTEXT.md
#       index "Load when prompt mentions..." cell set
# Pure filesystem + grep — hermetic, no install run.
set -euo pipefail

passed=0
failed=0
fail_lines=()

pass() { passed=$((passed + 1)); }
fail() {
    failed=$((failed + 1))
    fail_lines+=("FAIL: $1")
}

# Normalize a comma-list to a sorted unique set of lowercased trimmed tokens (one per line).
norm() {
    tr ',' '\n' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
        tr '[:upper:]' '[:lower:]' |
        grep -v '^$' |
        sort -u
}

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CTX_DIR="$CODEGEN_DIR/context"
PC="$CODEGEN_DIR/PROJECT_CONTEXT.md"

# Basenames referenced in the Domain table (col-1 backtick pattern `context/<name>.md`).
listed="$(grep -oE '`context/[a-z0-9_-]+\.md`' "$PC" | sed 's|`context/||; s|`||' | sort -u)"

# (a) coverage: every on-disk context/*.md is listed
# (c) every on-disk context/*.md has a ## Trigger Keywords section
while IFS= read -r f; do
    base="$(basename "$f")"
    if printf '%s\n' "$listed" | grep -qxF "$base"; then
        pass
    else
        fail "context/$base missing from PROJECT_CONTEXT.md Domain table"
    fi

    if grep -qE '^## Trigger Keywords$' "$f"; then
        pass
    else
        fail "context/$base missing ## Trigger Keywords section"
    fi

    # (d) in-file Trigger Keywords set == index "Load when prompt mentions..." cell set
    file_kw="$(awk '/^## Trigger Keywords$/{getline; while ($0 ~ /^[[:space:]]*$/) getline; print; exit}' "$f" | norm)"
    idx_kw="$(grep -F "\`context/$base\`" "$PC" | awk -F'|' '{print $4}' | norm)"
    if [ "$file_kw" = "$idx_kw" ]; then
        pass
    else
        fo="$(comm -23 <(printf '%s\n' "$file_kw") <(printf '%s\n' "$idx_kw") | paste -sd',' - | sed 's/,/, /g')"
        io="$(comm -13 <(printf '%s\n' "$file_kw") <(printf '%s\n' "$idx_kw") | paste -sd',' - | sed 's/,/, /g')"
        fail "context/$base keyword drift — file-only: {$fo}; index-only: {$io}"
    fi
done < <(find "$CTX_DIR" -maxdepth 1 -name '*.md' -type f)

# (b) no non-.md clutter in context/
clutter="$(find "$CTX_DIR" -maxdepth 1 -type f ! -name '*.md')"
if [ -z "$clutter" ]; then
    pass
else
    while IFS= read -r c; do
        fail "non-.md clutter in context/: $(basename "$c")"
    done <<<"$clutter"
fi

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
