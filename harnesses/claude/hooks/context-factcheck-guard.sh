#!/bin/bash
# context-factcheck-guard.sh — PreToolUse hook: deny `git commit` when staged
# orientation docs contain named-path claims that don't resolve in the repo
# or <!-- count: CMD -->NNN anchors whose live probe mismatches NNN.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: unset
# harnesses: all
#
# Firing contract: no CLAUDE_ROLE gating (signal: none) — fires for all roles in all repos.
# Subagent inheritance: intentional — committer runs as subagent and this hook MUST
#   block its commits. Do NOT call is_outer_session().
#
# Claim class 1 — named-path probes:
#   For each staged orientation doc (CLAUDE.md, AGENTS.md, PROJECT_CONTEXT.md,
#   codegen/PROJECT_CONTEXT.md, context/*.md), extract backtick'd path-like
#   literals (containing at least one slash, matching known extensions).
#   If the path does not exist under repo_root → try Elixir source roots
#   (lib/, test/) for .ex/.exs literals (module→file convention) → still
#   missing → DENY.
#
# Claim class 2 — count anchors:
#   Match lines of the form: <!-- count: CMD -->NNN
#   CMD must use only allowlisted verbs (ls grep wc find cat sort uniq head tail)
#   and must not contain shell-injection tokens ($() backtick > >> ; && &).
#   Run CMD with cwd pinned to repo_root, compare integer output to NNN.
#   Mismatch → DENY. Probe infra fault (non-zero exit, non-integer output) → ALLOW.
#   Malformed NNN (non-integer) → DENY.
#   Disallowed verb or injection token → DENY.
#
# Allows:
#   - git status, git log, echo "git commit" (non-commit or substring)
#   - Read/Write/Edit tools (non-Bash)
#   - Any command outside a git repo or repo without a PROJECT_CONTEXT.md variant
#   - Unstaged docs (not in staged index)
#   - Named-path claims without a slash (bare basenames, out of grammar)
#   - Probe infra faults (fail-open for infrastructure errors only)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log context-factcheck-guard "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Match git commit at start-of-command position (not inside echo/string).
if ! printf '%s' "$COMMAND" | grep -qE '(^|[[:space:];&|])git[[:space:]]+commit\b'; then
    exit 0
fi

# Guard: must be inside a git repo.
if [ -z "${CWD:-}" ] || ! git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

# Derive repo root from CWD.
repo_root=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$repo_root" ]; then
    exit 0
fi

# Detect layout (same priority as context-index-parity).
if [ -f "$repo_root/PROJECT_CONTEXT.md" ]; then
    _layout="platform"
elif [ -f "$repo_root/codegen/PROJECT_CONTEXT.md" ]; then
    _layout="userapp"
else
    exit 0
fi

# Build the list of staged orientation docs to scan.
# Platform layout: CLAUDE.md, AGENTS.md, PROJECT_CONTEXT.md, context/*.md
# User-app layout: CLAUDE.md, AGENTS.md, codegen/PROJECT_CONTEXT.md, context/*.md
staged_docs=$(git -C "$repo_root" diff --cached --name-only 2>/dev/null |
    grep -E '^(CLAUDE\.md|AGENTS\.md|PROJECT_CONTEXT\.md|codegen/PROJECT_CONTEXT\.md|context/[^/]+\.md)$' || true)

if [ -z "$staged_docs" ]; then
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

    # Read staged blob.
    blob=$(git -C "$repo_root" show :"$doc_path" 2>/dev/null || true)
    if [ -z "$blob" ]; then
        continue
    fi

    linenum=0
    while IFS= read -r line; do
        linenum=$((linenum + 1))

        # ── Claim class 1: named-path probes ────────────────────────────────
        # Extract backtick'd literals that look like paths (contain a slash and
        # end with a known extension). Use printf/grep to stay POSIX-portable.
        # We strip the backticks and check each extracted path.
        path_claims=$(printf '%s\n' "$line" |
            grep -oE '`[a-zA-Z0-9_-]+/[a-zA-Z0-9_./-]+\.(sh|md|py|ts|js|json|yaml|exs|ex)`' |
            tr -d '`' || true)

        while IFS= read -r claim_path; do
            [ -z "$claim_path" ] && continue
            if [ ! -e "$repo_root/$claim_path" ]; then
                # Elixir source-root fallback: `widgetapp/billing.ex` (module
                # convention) commonly resolves at lib/widgetapp/billing.ex or
                # test/widgetapp/billing_test.ex. Only tried on literal-miss,
                # only for .ex/.exs — can never mask a real bare-root miss.
                resolved=0
                case "$claim_path" in
                *.ex | *.exs)
                    if [ -e "$repo_root/lib/$claim_path" ] || [ -e "$repo_root/test/$claim_path" ]; then
                        resolved=1
                    fi
                    ;;
                esac
                if [ "$resolved" -eq 0 ]; then
                    msg="context-factcheck-guard: ${doc_path}:${linenum} references \`${claim_path}\` which does not exist. Fix the path or remove the claim."
                    violations="${violations}${violations:+$'\n'}${msg}"
                fi
            fi
        done <<PATHS
$path_claims
PATHS

        # ── Claim class 2: count-anchor probes ──────────────────────────────
        # Match: <!-- count: CMD -->NNN
        # The comment close '-->' is followed immediately by the integer NNN.
        if printf '%s\n' "$line" | grep -qE '<!--[[:space:]]*count:[[:space:]]*.+-->[0-9]+'; then
            # Extract CMD (between 'count:' and '-->').
            anchor_cmd=$(printf '%s\n' "$line" |
                sed 's/.*<!--[[:space:]]*count:[[:space:]]*//' |
                sed 's/-->[0-9]*.*$//' |
                sed 's/[[:space:]]*$//')
            # Extract NNN (immediately after '-->').
            # Use sed to avoid grep treating '-->' as an option start.
            anchor_nnn=$(printf '%s\n' "$line" |
                sed 's/.*-->//' |
                grep -oE '^[0-9]+' | head -1)

            # Verify NNN is a plain integer (fail-closed on malformed).
            if [ -z "$anchor_nnn" ]; then
                msg="context-factcheck-guard: ${doc_path}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor."
                violations="${violations}${violations:+$'\n'}${msg}"
                continue
            fi
            if ! printf '%s' "$anchor_nnn" | grep -qE '^[0-9]+$'; then
                msg="context-factcheck-guard: ${doc_path}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor."
                violations="${violations}${violations:+$'\n'}${msg}"
                continue
            fi

            # Reject injection tokens in CMD (fail-closed).
            if printf '%s' "$anchor_cmd" | grep -qE '\$\(|`|>|;|&&|&'; then
                msg="context-factcheck-guard: ${doc_path}:${linenum} disallowed token in probe command. Only allowlisted verbs are permitted."
                violations="${violations}${violations:+$'\n'}${msg}"
                continue
            fi

            # Tokenize CMD on pipe segments, extract first word (verb) of each.
            injection_denied=0
            IFS='|' read -ra pipe_segs <<<"$anchor_cmd"
            for seg in "${pipe_segs[@]}"; do
                # Trim leading whitespace to get the first token.
                verb=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//' | awk '{print $1}')
                if [ -z "$verb" ]; then
                    continue
                fi
                if ! is_allowed_verb "$verb"; then
                    msg="context-factcheck-guard: ${doc_path}:${linenum} disallowed probe verb '${verb}'. Allowed: ${ALLOWED_VERBS}."
                    violations="${violations}${violations:+$'\n'}${msg}"
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

            # Integer mismatch → deny.
            if [ "$probe_int" != "$anchor_nnn" ]; then
                msg="context-factcheck-guard: ${doc_path}:${linenum} claims ${anchor_nnn} but the count probe returns ${probe_int}. Update the count or the docs."
                violations="${violations}${violations:+$'\n'}${msg}"
            fi
        elif printf '%s\n' "$line" | grep -qE '<!--[[:space:]]*count:[[:space:]]*.+-->[^0-9]'; then
            # Has count anchor but NNN is non-integer (e.g. 'abc') → fail-closed.
            # Extract everything after '-->' and check if it's non-integer.
            nnn_val=$(printf '%s\n' "$line" | sed 's/.*-->//' | tr -d '[:space:]' | grep -oE '^[^<]*' | head -1)
            if [ -n "$nnn_val" ] && ! printf '%s' "$nnn_val" | grep -qE '^[0-9]+$'; then
                msg="context-factcheck-guard: ${doc_path}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor."
                violations="${violations}${violations:+$'\n'}${msg}"
            fi
        fi

    done <<BLOB
$blob
BLOB

done <<DOCS
$staged_docs
DOCS

if [ -n "$violations" ]; then
    deny "$violations"
fi
exit 0
