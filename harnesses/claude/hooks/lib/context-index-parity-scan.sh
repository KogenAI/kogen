#!/usr/bin/env bash
# context-index-parity-scan.sh — standalone WORKING-TREE index-parity scan.
#
# Detects `context/*.md` files Added or Deleted in the WORKING TREE (vs
# HEAD — uncommitted, the curator's own turn) that lack semantic parity
# with the repo's index doc (PROJECT_CONTEXT.md — platform layout, or
# codegen/PROJECT_CONTEXT.md — user-app layout). Extracted from the
# commit-time context-index-parity.sh so the SAME parity primitive can run
# both pre-invoke (seeding a same-cycle violation into the curator's FIRST
# prompt) and end-of-turn (in-loop OrchestrationLoop.run_curator_doc_check,
# the backstop), reading on-disk content instead of the staged git index —
# the curator's edits are still uncommitted at this point (the committer
# runs after).
#
# Usage: context-index-parity-scan.sh <repo_root>
#
# Exit 0: clean (no violations). Prints nothing.
# Exit 1: violations found. Prints one violation per line to stdout.
#
# No hook I/O — no parse_input, no deny/block. Pure scan.
#
# ADD direction — a context/*.md file exists on disk but did NOT exist at
#   HEAD → the index body (on-disk PROJECT_CONTEXT.md / codegen/PROJECT_CONTEXT.md)
#   must mention `context/<basename>.md`. Missing → violation.
# DELETE direction — a context/*.md file existed at HEAD but is now absent
#   from disk → the index body must NOT mention `context/<basename>.md`.
#   Still present → violation (stale row).
# Phantom-ref pass — every `context/<name>.md` referenced in the on-disk
#   index body must exist on disk. Missing → violation.
#
# Fail-open (exit 0, no violations printed):
#   - repo_root not a git repo, or unborn branch (no HEAD commit yet)
#   - repo_root has neither PROJECT_CONTEXT.md nor codegen/PROJECT_CONTEXT.md
#   - No context/*.md add/delete and no phantom refs

set -uo pipefail

repo_root="${1:-}"

if [ -z "$repo_root" ]; then
    printf 'context-index-parity-scan: usage: context-index-parity-scan.sh <repo_root>\n' >&2
    exit 0
fi

if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

resolved_root=$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$resolved_root" ]; then
    exit 0
fi
repo_root="$resolved_root"

# Detect layout (same priority as context-factcheck-scan.sh / context-index-parity.sh).
if [ -f "$repo_root/PROJECT_CONTEXT.md" ]; then
    index_path="PROJECT_CONTEXT.md"
elif [ -f "$repo_root/codegen/PROJECT_CONTEXT.md" ]; then
    index_path="codegen/PROJECT_CONTEXT.md"
else
    exit 0
fi

# Unborn branch (no HEAD commit yet) — nothing to diff against; fail-open.
if ! git -C "$repo_root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    exit 0
fi

nl="
"

# Working-tree diff vs HEAD, filtered to direct-child context/*.md adds/deletes.
# `git diff HEAD` alone misses brand-new UNTRACKED files (e.g. a context/*.md
# the curator Write'd this turn but never `git add`ed) — union in
# `ls-files --others` (untracked) as synthetic "A\t<path>" lines so a new
# file that is not yet staged/committed is still caught as an ADD.
name_status=$(git -C "$repo_root" diff HEAD --name-status -- 'context/*.md' 2>/dev/null || true)
untracked=$(git -C "$repo_root" ls-files --others --exclude-standard -- 'context/*.md' 2>/dev/null || true)
untracked_lines=""
while IFS= read -r u; do
    [ -z "$u" ] && continue
    untracked_lines="${untracked_lines}${untracked_lines:+$nl}A	${u}"
done <<UNTRACKED
$untracked
UNTRACKED
combined_status="${name_status}${name_status:+$nl}${untracked_lines}"
orphan_lines=$(printf '%s\n' "$combined_status" | grep -E '^[AD][[:space:]]+context/[^/]+\.md$' | sort -u || true)

# Index body on disk (working tree — the curator's own uncommitted edits).
index_body=""
if [ -f "$repo_root/$index_path" ]; then
    index_body=$(cat "$repo_root/$index_path" 2>/dev/null || true)
fi

violations=""

while IFS= read -r line; do
    [ -z "$line" ] && continue
    status="${line%%[[:space:]]*}"
    fpath="${line#*$'\t'}"
    [ "$fpath" = "$line" ] && fpath=$(printf '%s' "$line" | awk '{print $2}')
    basename="${fpath%.md}"
    basename="${basename##*/}"

    if [ "$status" = "A" ]; then
        if ! printf '%s' "$index_body" | grep -qF "\`context/${basename}.md\`"; then
            violations="${violations}${violations:+$nl}context-index-parity-scan: context/${basename}.md added but no index row mentions \"${basename}\" in ${index_path} § Domain Context Files. Add a \"Load when prompt mentions...\" row."
        fi
    elif [ "$status" = "D" ]; then
        if printf '%s' "$index_body" | grep -qF "\`context/${basename}.md\`"; then
            violations="${violations}${violations:+$nl}context-index-parity-scan: context/${basename}.md deleted but a stale index row still mentions \"${basename}\". Remove it."
        fi
    fi
done <<EOF
$orphan_lines
EOF

# Phantom-ref pass: every context/<name>.md referenced in the on-disk index
# body must exist on disk.
if [ -n "$index_body" ]; then
    ref_names=$(printf '%s' "$index_body" | grep -oE 'context/[a-z0-9_-]+\.md' | sort -u || true)
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        if [ ! -f "$repo_root/$ref" ]; then
            violations="${violations}${violations:+$nl}context-index-parity-scan: $index_path row references $ref which does not exist. Add the file or remove the row."
        fi
    done <<EOF2
$ref_names
EOF2
fi

# Full-tree parity pass — codegen SELF-BUILD ONLY. Root-layout detection
# alone (PROJECT_CONTEXT.md at repo root) is NOT sufficient to mean "codegen
# self-build" — downstream Phoenix/static apps also carry a root
# PROJECT_CONTEXT.md (their own project index), so gating on root layout
# alone false-positives this codegen-private Trigger-Keywords/coverage
# convention against every downstream app's context/*.md files. Require the
# codegen-repo sentinel (harnesses/claude/manifest.yaml, tracked at codegen
# repo root only — a downstream app vendors the harness under
# codegen/harnesses/…, never at its own root) in addition to root layout.
# The ADD/DELETE pass above is delta-based (working tree vs HEAD, this turn
# only) and misses a PRE-EXISTING context/*.md that was already committed
# with no index row (or no Trigger Keywords section, or drifted keywords) —
# the case that used to live in the deleted `make test` gate test
# `context-index-coverage_test.sh`. Downstream/user-app layout
# (codegen/PROJECT_CONTEXT.md) is a different index-doc convention and keeps
# ONLY the delta + phantom-ref passes above — no behavior change there.
if [ "$index_path" = "PROJECT_CONTEXT.md" ] && [ -f "$repo_root/harnesses/claude/manifest.yaml" ]; then
    ctx_dir="$repo_root/context"

    # Basenames referenced in the Domain table (col-1 backtick pattern).
    listed=$(printf '%s' "$index_body" | grep -oE '`context/[a-z0-9_-]+\.md`' | sed 's|`context/||; s|`||' | sort -u || true)

    # Normalize a comma-list to a sorted unique set of lowercased trimmed tokens.
    norm() {
        tr ',' '\n' |
            sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
            tr '[:upper:]' '[:lower:]' |
            grep -v '^$' |
            sort -u
    }

    if [ -d "$ctx_dir" ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            base=$(basename "$f")

            # (a) full-tree coverage: every on-disk context/*.md is listed.
            if ! printf '%s\n' "$listed" | grep -qxF "$base"; then
                violations="${violations}${violations:+$nl}context-index-parity-scan: context/$base missing from $index_path Domain Context Files table (full-tree pass)."
            fi

            # (c) every on-disk context/*.md has a ## Trigger Keywords section.
            if ! grep -qE '^## Trigger Keywords$' "$f"; then
                violations="${violations}${violations:+$nl}context-index-parity-scan: context/$base missing ## Trigger Keywords section."
                continue
            fi

            # (d) in-file Trigger Keywords set == index "Load when prompt
            # mentions..." cell (col-4) set — byte-exact after normalization.
            file_kw=$(awk '/^## Trigger Keywords$/{getline; while ($0 ~ /^[[:space:]]*$/) getline; print; exit}' "$f" | norm)
            # Only TABLE ROWS carry the col-4 keyword cell. A prose
            # cross-reference elsewhere in the index (e.g. "See
            # `context/deployment-topology.md`." in a bullet) also matches the
            # backticked path, and parsing that line as a row appends garbage —
            # producing a permanent false "keyword drift" that no edit to
            # either document can clear. Anchor to lines that actually start a
            # markdown table row.
            idx_kw=$(grep -F "\`context/$base\`" "$repo_root/$index_path" | grep '^[[:space:]]*|' | awk -F'|' '{print $4}' | norm)
            if [ "$file_kw" != "$idx_kw" ]; then
                file_only=$(comm -23 <(printf '%s\n' "$file_kw") <(printf '%s\n' "$idx_kw") | grep -v '^$' | paste -sd, - || true)
                idx_only=$(comm -13 <(printf '%s\n' "$file_kw") <(printf '%s\n' "$idx_kw") | grep -v '^$' | paste -sd, - || true)
                [ -z "$file_only" ] && file_only="(none)"
                [ -z "$idx_only" ] && idx_only="(none)"
                violations="${violations}${violations:+$nl}context-index-parity-scan: context/$base keyword drift between file Trigger Keywords and $index_path Domain Context Files row. in file only: $file_only; in index only: $idx_only"
            fi
        done < <(find "$ctx_dir" -maxdepth 1 -name '*.md' -type f)

        # (b) no non-.md clutter in context/.
        while IFS= read -r c; do
            [ -z "$c" ] && continue
            violations="${violations}${violations:+$nl}context-index-parity-scan: non-.md clutter in context/: $(basename "$c")."
        done < <(find "$ctx_dir" -maxdepth 1 -type f ! -name '*.md')
    fi
fi

if [ -n "$violations" ]; then
    printf '%s\n' "$violations"
    exit 1
fi
exit 0
