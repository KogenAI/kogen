#!/usr/bin/env bash
# rules-index-parity_test.sh — bidirectional file-SET parity: shared/rules vs INDEX.md
#
# Verifies that every .md file under shared/rules/ (excluding INDEX.md) has a
# corresponding row in INDEX.md §"Folder Layout", and every row in that section
# corresponds to an existing file on disk.
#
# Uses relative-path (not basename) comparison to detect collisions such as
# roles/developer.md vs phoenix/developer.md being treated as the same entry.
#
# Tests:
#   Test 1 (live) — add-parity:    no file on disk is missing from INDEX Folder Layout
#   Test 2 (live) — delete-parity: no INDEX Folder Layout row lacks a file on disk
#   Test 3 (fixture) — clean fixture → both parity checks pass
#   Test 4 (fixture) — file on disk, no row → add-parity FAIL naming the path
#   Test 5 (fixture) — row present, file absent → delete-parity FAIL naming the path
#   Test 6 (fixture, DECISIVE) — basename collision: roles/developer.md deleted but
#       phoenix/developer.md remains; delete-parity MUST FAIL naming roles/developer.md
#   Test 7 (fixture) — nested 3-level depth (stacks/phoenix/_core.md at indent 6)
#   Test 8 (fixture) — folder line in INDEX (no .md) is not emitted as a path → PASS
#   Test 9 (fixture) — description text after token is stripped; path still correct
#   Test 10 (fixture) — top-level file (STYLE_GUIDE.md at indent 2) has no folder prefix
#   Test 11 (fixture) — exit code 1 when parity failure detected
#   Test 12 (fixture) — exit code 0 when fixture is clean
#
# Usage: bash rules-index-parity_test.sh
# Exit 0 → all pass. Exit 1 → one or more failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

RULES_DIR="$CODEGEN_DIR/shared/rules"
INDEX="$RULES_DIR/INDEX.md"

pass=0
fail=0

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Reusable functions ────────────────────────────────────────────────────────

# listed_paths <index_file>
# Reconstructs relative paths from INDEX.md §"Folder Layout" fenced block.
listed_paths() {
    local index_file="$1"
    awk '
    /^## Folder Layout[[:space:]]*$/ { inhdr=1; next }
    inhdr && /^```[[:space:]]*$/ { if (infence) { exit } else { infence=1; next } }
    !infence { next }
    {
      line=$0
      n=0; while (substr(line,n+1,1)==" ") n++   # leading-space count
      depth=int(n/2)                              # 2 spaces per nesting level
      tok=line; sub(/^[[:space:]]+/,"",tok); sub(/[[:space:]].*$/,"",tok)  # first token
      if (tok ~ /\/$/) {                          # folder line: push, drop deeper
        for (d in stack) if (d>=depth) delete stack[d]
        name=tok; sub(/\/$/,"",name); stack[depth]=name
      } else if (tok ~ /\.md$/) {                 # file line: emit reconstructed path
        path=""
        for (d=1; d<depth; d++) if (d in stack) path=path stack[d] "/"
        print path tok
      }
    }
  ' "$index_file" | sort
}

# disk_paths <rules_dir>
# Returns sorted relative paths of all .md files except INDEX.md.
disk_paths() {
    local rules_dir="$1"
    find "$rules_dir" -name '*.md' -type f ! -name 'INDEX.md' |
        sed "s#^$rules_dir/##" |
        sort
}

# ── Test 1 (live): add-parity — no disk file missing from INDEX ──────────────
{
    missing=$(comm -23 <(disk_paths "$RULES_DIR") <(listed_paths "$INDEX"))
    if [ -z "$missing" ]; then
        pass=$((pass + 1))
    else
        while IFS= read -r path; do
            printf 'FAIL: file on disk missing from INDEX Folder Layout: %s\n' "$path"
        done <<<"$missing"
        fail=$((fail + 1))
    fi
}

# ── Test 2 (live): delete-parity — no INDEX row lacks a file on disk ─────────
{
    stale=$(comm -13 <(disk_paths "$RULES_DIR") <(listed_paths "$INDEX"))
    if [ -z "$stale" ]; then
        pass=$((pass + 1))
    else
        while IFS= read -r path; do
            printf 'FAIL: INDEX Folder Layout lists a file absent on disk: %s\n' "$path"
        done <<<"$stale"
        fail=$((fail + 1))
    fi
}

# ── Test 3: clean fixture → both parity checks PASS ──────────────────────────
{
    t="$TMP_DIR/t3"
    mkdir -p "$t/rules/roles"
    touch "$t/rules/roles/developer.md"
    cat >"$t/rules/INDEX.md" <<'EOF'
# Rules Index

## Folder Layout

```
rules/
  roles/
    developer.md   implementation guide
```
EOF

    missing=$(comm -23 <(disk_paths "$t/rules") <(listed_paths "$t/rules/INDEX.md"))
    stale=$(comm -13 <(disk_paths "$t/rules") <(listed_paths "$t/rules/INDEX.md"))
    if [ -z "$missing" ] && [ -z "$stale" ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 3 — clean fixture should produce no mismatches\n'
        fail=$((fail + 1))
    fi
}

# ── Test 4: file on disk, no INDEX row → add-parity FAIL ─────────────────────
{
    t="$TMP_DIR/t4"
    mkdir -p "$t/rules/roles"
    touch "$t/rules/roles/developer.md"
    touch "$t/rules/roles/committer.md"
    cat >"$t/rules/INDEX.md" <<'EOF'
# Rules Index

## Folder Layout

```
rules/
  roles/
    developer.md   implementation guide
```
EOF

    missing=$(comm -23 <(disk_paths "$t/rules") <(listed_paths "$t/rules/INDEX.md"))
    if echo "$missing" | grep -qF 'roles/committer.md'; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 4 — add-parity should name roles/committer.md as missing from INDEX. Got: %s\n' "$missing"
        fail=$((fail + 1))
    fi
}

# ── Test 5: row present, file absent → delete-parity FAIL ────────────────────
{
    t="$TMP_DIR/t5"
    mkdir -p "$t/rules/roles"
    touch "$t/rules/roles/developer.md"
    cat >"$t/rules/INDEX.md" <<'EOF'
# Rules Index

## Folder Layout

```
rules/
  roles/
    developer.md   implementation guide
    committer.md   commit message rules
```
EOF

    stale=$(comm -13 <(disk_paths "$t/rules") <(listed_paths "$t/rules/INDEX.md"))
    if echo "$stale" | grep -qF 'roles/committer.md'; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 5 — delete-parity should name roles/committer.md as stale in INDEX. Got: %s\n' "$stale"
        fail=$((fail + 1))
    fi
}

# ── Test 6 (DECISIVE): basename collision → relative-path discrimination ──────
# disk: roles/developer.md + phoenix/developer.md
# INDEX: both listed
# after removing roles/developer.md from disk, delete-parity MUST name roles/developer.md
{
    t="$TMP_DIR/t6"
    mkdir -p "$t/rules/roles" "$t/rules/phoenix"
    touch "$t/rules/phoenix/developer.md"
    # roles/developer.md is intentionally NOT on disk (simulating a delete)
    cat >"$t/rules/INDEX.md" <<'EOF'
# Rules Index

## Folder Layout

```
rules/
  roles/
    developer.md   role developer
  phoenix/
    developer.md   phoenix developer
```
EOF

    stale=$(comm -13 <(disk_paths "$t/rules") <(listed_paths "$t/rules/INDEX.md"))
    if echo "$stale" | grep -qF 'roles/developer.md'; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 6 — delete-parity must name roles/developer.md even though phoenix/developer.md exists on disk. Got stale: %s\n' "$stale"
        fail=$((fail + 1))
    fi
}

# ── Test 7: nested 3-level depth (stacks/phoenix/_core.md at indent 6) ───────
{
    t="$TMP_DIR/t7"
    mkdir -p "$t/rules/stacks/phoenix"
    touch "$t/rules/stacks/phoenix/_core.md"
    cat >"$t/rules/INDEX.md" <<'EOF'
# Rules Index

## Folder Layout

```
rules/
  stacks/
    phoenix/
      _core.md   idioms
```
EOF

    missing=$(comm -23 <(disk_paths "$t/rules") <(listed_paths "$t/rules/INDEX.md"))
    stale=$(comm -13 <(disk_paths "$t/rules") <(listed_paths "$t/rules/INDEX.md"))
    if [ -z "$missing" ] && [ -z "$stale" ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 7 — 3-level nested path should reconstruct correctly. missing=%s stale=%s\n' "$missing" "$stale"
        fail=$((fail + 1))
    fi
}

# ── Test 8: folder line (no .md) is NOT emitted as a path ────────────────────
{
    t="$TMP_DIR/t8"
    mkdir -p "$t/rules/phoenix"
    touch "$t/rules/phoenix/developer.md"
    cat >"$t/rules/INDEX.md" <<'EOF'
# Rules Index

## Folder Layout

```
rules/
  phoenix/
    developer.md   phoenix developer
```
EOF

    listed=$(listed_paths "$t/rules/INDEX.md")
    # Folder lines end with '/' but NOT '.md' — check that no path is exactly a bare folder token
    if echo "$listed" | grep -qE '^[^/]+/$'; then
        printf 'FAIL: Test 8 — folder line should NOT appear as a listed path. Got: %s\n' "$listed"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

# ── Test 9: description text after token is stripped; path still correct ──────
{
    t="$TMP_DIR/t9"
    mkdir -p "$t/rules/_core"
    touch "$t/rules/_core/output-style.md"
    cat >"$t/rules/INDEX.md" <<'EOF'
# Rules Index

## Folder Layout

```
rules/
  _core/
    output-style.md   caveman ultra, many tokens, important rule
```
EOF

    listed=$(listed_paths "$t/rules/INDEX.md")
    if [ "$listed" = "_core/output-style.md" ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 9 — description text must be stripped; expected _core/output-style.md, got: %s\n' "$listed"
        fail=$((fail + 1))
    fi
}

# ── Test 10: top-level file (STYLE_GUIDE.md at indent 2) has no folder prefix ─
{
    t="$TMP_DIR/t10"
    mkdir -p "$t/rules"
    touch "$t/rules/STYLE_GUIDE.md"
    cat >"$t/rules/INDEX.md" <<'EOF'
# Rules Index

## Folder Layout

```
rules/
  STYLE_GUIDE.md   rule authoring style
```
EOF

    listed=$(listed_paths "$t/rules/INDEX.md")
    if [ "$listed" = "STYLE_GUIDE.md" ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 10 — top-level file should have no folder prefix, got: %s\n' "$listed"
        fail=$((fail + 1))
    fi
}

# ── Test 11: exit code 1 when parity failure detected ────────────────────────
{
    t="$TMP_DIR/t11"
    mkdir -p "$t/rules/roles"
    touch "$t/rules/roles/developer.md"
    touch "$t/rules/roles/committer.md"
    cat >"$t/rules/INDEX.md" <<'EOF'
# Rules Index

## Folder Layout

```
rules/
  roles/
    developer.md   implementation guide
```
EOF

    rc=0
    (
        set -euo pipefail
        missing=$(comm -23 <(disk_paths "$t/rules") <(listed_paths "$t/rules/INDEX.md"))
        if [ -n "$missing" ]; then
            exit 1
        fi
        exit 0
    ) || rc=$?

    if [ "$rc" -eq 1 ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 11 — detector should exit 1 when add-parity fails, got exit %d\n' "$rc"
        fail=$((fail + 1))
    fi
}

# ── Test 12: exit code 0 on clean fixture ────────────────────────────────────
{
    t="$TMP_DIR/t12"
    mkdir -p "$t/rules/roles"
    touch "$t/rules/roles/developer.md"
    cat >"$t/rules/INDEX.md" <<'EOF'
# Rules Index

## Folder Layout

```
rules/
  roles/
    developer.md   implementation guide
```
EOF

    rc=0
    (
        set -euo pipefail
        missing=$(comm -23 <(disk_paths "$t/rules") <(listed_paths "$t/rules/INDEX.md"))
        stale=$(comm -13 <(disk_paths "$t/rules") <(listed_paths "$t/rules/INDEX.md"))
        if [ -n "$missing" ] || [ -n "$stale" ]; then
            exit 1
        fi
        exit 0
    ) || rc=$?

    if [ "$rc" -eq 0 ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: Test 12 — clean fixture should exit 0, got exit %d\n' "$rc"
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
