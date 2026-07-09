#!/bin/bash
# context-factcheck-curator-stop.sh — SubagentStop hook for context-curator.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: context-curator
# surface: user_global
# signal: AGENT_TYPE
# role: context-curator
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Scans WORKING-TREE orientation docs (CLAUDE.md, AGENTS.md, PROJECT_CONTEXT.md,
# codegen/PROJECT_CONTEXT.md, context/*.md) for the two factcheck claim classes
# (named-path + count-anchor) and BLOCKS the curator so it fixes before
# yielding to the committer — the committer cannot Read/Edit context/*.md
# (subagent-read-discipline denies it), so a factcheck violation reaching the
# committer is an unfixable dead-end. This hook fires at the last role that
# CAN edit orientation docs, reading the working tree (not the staged blob),
# so it catches cross-file breaks too (e.g. doc A references a path deleted
# by an edit to file B this same cycle).
#
# Mirrors the claim-class scan logic of context-factcheck-guard.sh (the
# commit-time PreToolUse backstop for non-loop / direct / human commits,
# which is unchanged and kept). Divergence: this hook reads files from DISK
# (working tree), not `git show :<path>` (staged blob); and it `block`s
# (Stop-event JSON) instead of `deny`s (PreToolUse JSON).
#
# Claim class 1 — named-path probes:
#   For each working-tree orientation doc, extract backtick'd path-like
#   literals (containing at least one slash, matching known extensions).
#   If the path does not exist under repo_root → BLOCK.
#
# Claim class 2 — count anchors:
#   Match lines of the form: <!-- count: CMD -->NNN
#   CMD must use only allowlisted verbs (ls grep wc find cat sort uniq head tail)
#   and must not contain shell-injection tokens ($() backtick > >> ; && &).
#   Run CMD with cwd pinned to repo_root, compare integer output to NNN.
#   Mismatch → BLOCK. Probe infra fault (non-zero exit, non-integer output) → ALLOW.
#   Malformed NNN (non-integer) → BLOCK.
#   Disallowed verb or injection token → BLOCK.
#
# Allows:
#   - Non-context-curator stops
#   - STOP_HOOK_ACTIVE re-entry (loop guard — this hook itself may block)
#   - Any cwd outside a git repo or repo without a PROJECT_CONTEXT.md variant
#   - Docs absent from the working tree (deleted/never existed — nothing to scan)
#   - Named-path claims without a slash (bare basenames, out of grammar)
#   - Probe infra faults (fail-open for infrastructure errors only)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log context-factcheck-curator-stop "agent=$AGENT_TYPE stop_active=$STOP_HOOK_ACTIVE"

# Loop guard: this hook may itself trigger a re-stop (block); avoid re-firing
# on the synthetic re-invocation.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# AGENT_TYPE gate — only run for context-curator.
case "$AGENT_TYPE" in
context-curator) ;;
*)
    exit 0
    ;;
esac

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. COMMAND is empty on SubagentStop events, so this
# is a harmless no-op guard kept for parity with sibling hooks.
is_codegen_log_write && exit 0

project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# Guard: must be inside a git repo.
if ! git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

repo_root=$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$repo_root" ]; then
    exit 0
fi

# Detect layout (same priority as context-factcheck-guard / context-index-parity).
if [ -f "$repo_root/PROJECT_CONTEXT.md" ]; then
    _layout="platform"
elif [ -f "$repo_root/codegen/PROJECT_CONTEXT.md" ]; then
    _layout="userapp"
else
    exit 0
fi

# Build the list of working-tree orientation docs to scan (existing files
# only — git ls-files covers tracked + intent-to-add; context/*.md is
# enumerated via find so NEW untracked docs are also caught).
docs=""
nl="
"
for fixed_doc in CLAUDE.md AGENTS.md PROJECT_CONTEXT.md codegen/PROJECT_CONTEXT.md; do
    if [ -f "$repo_root/$fixed_doc" ]; then
        docs="${docs}${docs:+$nl}${fixed_doc}"
    fi
done
if [ -d "$repo_root/context" ]; then
    while IFS= read -r ctx_doc; do
        [ -z "$ctx_doc" ] && continue
        docs="${docs}${docs:+$nl}context/${ctx_doc}"
    done <<CTXDOCS
$(cd "$repo_root/context" && find . -maxdepth 1 -name '*.md' -type f -exec basename {} \; 2>/dev/null | sort)
CTXDOCS
fi

if [ -z "$docs" ]; then
    exit 0
fi

# Accumulate all violations.
violations=""

# Verb allowlist for count-anchor probes.
ALLOWED_VERBS="ls grep wc find cat sort uniq head tail"

is_allowed_verb() {
    local verb="$1"
    local v
    for v in $ALLOWED_VERBS; do
        [ "$v" = "$verb" ] && return 0
    done
    return 1
}

while IFS= read -r doc_path; do
    [ -z "$doc_path" ] && continue

    # Read from the WORKING TREE (disk), not the staged/HEAD blob.
    if [ ! -f "$repo_root/$doc_path" ]; then
        continue
    fi
    blob=$(cat "$repo_root/$doc_path" 2>/dev/null || true)
    if [ -z "$blob" ]; then
        continue
    fi

    linenum=0
    while IFS= read -r line; do
        linenum=$((linenum + 1))

        # ── Claim class 1: named-path probes ────────────────────────────────
        path_claims=$(printf '%s\n' "$line" |
            grep -oE '`[a-zA-Z0-9_-]+/[a-zA-Z0-9_./-]+\.(sh|md|py|ts|js|json|yaml|exs|ex)`' |
            tr -d '`' || true)

        while IFS= read -r claim_path; do
            [ -z "$claim_path" ] && continue
            if [ ! -e "$repo_root/$claim_path" ]; then
                msg="context-factcheck-curator-stop: ${doc_path}:${linenum} references \`${claim_path}\` which does not exist. Fix the path or remove the claim."
                violations="${violations}${violations:+$nl}${msg}"
            fi
        done <<PATHS
$path_claims
PATHS

        # ── Claim class 2: count-anchor probes ──────────────────────────────
        if printf '%s\n' "$line" | grep -qE '<!--[[:space:]]*count:[[:space:]]*.+-->[0-9]+'; then
            anchor_cmd=$(printf '%s\n' "$line" |
                sed 's/.*<!--[[:space:]]*count:[[:space:]]*//' |
                sed 's/-->[0-9]*.*$//' |
                sed 's/[[:space:]]*$//')
            anchor_nnn=$(printf '%s\n' "$line" |
                sed 's/.*-->//' |
                grep -oE '^[0-9]+' | head -1)

            if [ -z "$anchor_nnn" ]; then
                msg="context-factcheck-curator-stop: ${doc_path}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor."
                violations="${violations}${violations:+$nl}${msg}"
                continue
            fi
            if ! printf '%s' "$anchor_nnn" | grep -qE '^[0-9]+$'; then
                msg="context-factcheck-curator-stop: ${doc_path}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor."
                violations="${violations}${violations:+$nl}${msg}"
                continue
            fi

            # Reject injection tokens in CMD (fail-closed).
            if printf '%s' "$anchor_cmd" | grep -qE '\$\(|`|>|;|&&|&'; then
                msg="context-factcheck-curator-stop: ${doc_path}:${linenum} disallowed token in probe command. Only allowlisted verbs are permitted."
                violations="${violations}${violations:+$nl}${msg}"
                continue
            fi

            # Tokenize CMD on pipe segments, extract first word (verb) of each.
            injection_denied=0
            IFS='|' read -ra pipe_segs <<<"$anchor_cmd"
            for seg in "${pipe_segs[@]}"; do
                verb=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//' | awk '{print $1}')
                if [ -z "$verb" ]; then
                    continue
                fi
                if ! is_allowed_verb "$verb"; then
                    msg="context-factcheck-curator-stop: ${doc_path}:${linenum} disallowed probe verb '${verb}'. Allowed: ${ALLOWED_VERBS}."
                    violations="${violations}${violations:+$nl}${msg}"
                    injection_denied=1
                    break
                fi
            done
            [ "$injection_denied" -eq 1 ] && continue

            # Run the vetted probe with cwd pinned to repo_root (fail-open on infra faults).
            probe_out=$(cd "$repo_root" && bash -c "$anchor_cmd" 2>/dev/null) || true
            probe_int=$(printf '%s' "$probe_out" | tr -d '[:space:]')

            # Non-integer output → fail-open (infra fault).
            if ! printf '%s' "$probe_int" | grep -qE '^[0-9]+$'; then
                continue
            fi

            # Integer mismatch → block.
            if [ "$probe_int" != "$anchor_nnn" ]; then
                msg="context-factcheck-curator-stop: ${doc_path}:${linenum} claims ${anchor_nnn} but the count probe returns ${probe_int}. Update the count or the docs."
                violations="${violations}${violations:+$nl}${msg}"
            fi
        elif printf '%s\n' "$line" | grep -qE '<!--[[:space:]]*count:[[:space:]]*.+-->[^0-9]'; then
            nnn_val=$(printf '%s\n' "$line" | sed 's/.*-->//' | tr -d '[:space:]' | grep -oE '^[^<]*' | head -1)
            if [ -n "$nnn_val" ] && ! printf '%s' "$nnn_val" | grep -qE '^[0-9]+$'; then
                msg="context-factcheck-curator-stop: ${doc_path}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor."
                violations="${violations}${violations:+$nl}${msg}"
            fi
        fi

    done <<BLOB
$blob
BLOB

done <<DOCS
$docs
DOCS

if [ -n "$violations" ]; then
    block "$violations Fix these in your working tree, then stop again."
fi
exit 0
