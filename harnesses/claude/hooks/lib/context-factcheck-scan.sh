#!/usr/bin/env bash
# context-factcheck-scan.sh — standalone working-tree factcheck scan.
#
# Scans WORKING-TREE orientation docs (CLAUDE.md, AGENTS.md, PROJECT_CONTEXT.md,
# codegen/PROJECT_CONTEXT.md, context/*.md) for the three factcheck claim classes
# (named-path, count-anchor, `_`->`*` identifier corruption). Originally extracted
# from the now-deleted context-factcheck-curator-stop.sh (dead-under-loop
# SubagentStop hook) so the same logic could run both there and as an in-loop
# Elixir step. Now shared by TWO live callers: the PreToolUse
# context-factcheck-edit-gate.sh (projected post-write content, writer's own
# turn) and the in-loop Elixir OrchestrationLoop.run_curator_doc_check (working
# tree, end-of-turn backstop for Bash writes the edit-gate never sees).
#
# Usage: context-factcheck-scan.sh <repo_root> [doc_path...]
#
# With no doc_path args: scans the full working-tree orientation-doc set
# (whole-tree default — used by the interactive SubagentStop hook).
# With one or more doc_path args (each relative to repo_root): scans ONLY
# those docs — used by the in-loop Elixir step to diff-scope the scan to the
# current cycle's own edits so ambient rot in untouched docs never blocks an
# unrelated build.
#
# Exit 0: clean (no violations). Prints nothing.
# Exit 1: violations found. Prints one violation per line to stdout.
#
# No hook I/O — no parse_input, no block. Pure scan.
#
# Claim class 1 — named-path probes:
#   For each working-tree orientation doc, extract backtick'd path-like
#   literals (containing at least one slash, matching known extensions).
#   If the path does not exist under repo_root → try Elixir source roots
#   (lib/, test/) for .ex/.exs literals (module→file convention) → still
#   missing → violation.
#
# Claim class 2 — count anchors:
#   Match lines of the form: <!-- count: CMD -->NNN
#   CMD must use only allowlisted verbs (ls grep wc find cat sort uniq head tail)
#   and must not contain shell-injection tokens ($() backtick > >> ; && &).
#   Run CMD with cwd pinned to repo_root, compare integer output to NNN.
#   Mismatch → violation. Probe infra fault (non-zero exit, non-integer output) →
#   fail-open (not a violation). Malformed NNN → violation. Disallowed verb or
#   injection token → violation.
#
# Claim class 3 — identifier corruption:
#   Detects the LLM-transcription `_`→`*` artifact: a word-internal asterisk
#   sandwiched between two alphanumerics (e.g. `register*route` corrupted from
#   `register_route`, or `fn * ->` corrupted from `fn _ ->`). Pattern:
#   [[:alnum:]]\*[[:alnum:]] — matched per-line. Deliberately narrow: only the
#   word-internal case (zero false positives on real corpus — globs like
#   `context/*.md`, `OCG_*`, `no-*.sh`, regex `.*`, and markdown bold `**x**`
#   never sandwich an asterisk between two alphanumerics). The space-`*`-space
#   case (`fn * ->`) is NOT detected here — ambiguous with bullets/multiplication,
#   excluded by design (high false-positive risk).
#
# Fail-open (exit 0, no violations printed):
#   - repo_root not a git repo or repo without a PROJECT_CONTEXT.md variant
#   - Docs absent from the working tree (deleted/never existed — nothing to scan)
#   - Named-path claims without a slash (bare basenames, out of grammar)
#   - Probe infra faults (fail-open for infrastructure errors only)

set -uo pipefail

repo_root="${1:-}"
shift 2>/dev/null || true

if [ -z "$repo_root" ]; then
    printf 'context-factcheck-scan: usage: context-factcheck-scan.sh <repo_root> [doc_path...]\n' >&2
    exit 0
fi

# Optional explicit doc-path args (diff-scope caller). Empty when none given.
explicit_docs=""
nl_explicit="
"
for explicit_doc in "$@"; do
    [ -z "$explicit_doc" ] && continue
    explicit_docs="${explicit_docs}${explicit_docs:+$nl_explicit}${explicit_doc}"
done

if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

resolved_root=$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$resolved_root" ]; then
    exit 0
fi
repo_root="$resolved_root"

# Detect layout (same priority as context-factcheck-edit-gate.sh / context-index-parity-scan.sh).
if [ -f "$repo_root/PROJECT_CONTEXT.md" ]; then
    :
elif [ -f "$repo_root/codegen/PROJECT_CONTEXT.md" ]; then
    :
else
    exit 0
fi

# Build the list of orientation docs to scan. When the caller passed explicit
# doc-path args (diff-scope), scan ONLY those (each still resolved under
# repo_root below). Otherwise fall back to the whole-tree walk (default,
# preserves the interactive hook's existing behavior).
docs=""
nl="
"
if [ -n "$explicit_docs" ]; then
    docs="$explicit_docs"
else
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
                    msg="context-factcheck-scan: ${doc_path}:${linenum} references \`${claim_path}\` which does not exist. Fix the path or remove the claim."
                    violations="${violations}${violations:+$nl}${msg}"
                fi
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
                msg="context-factcheck-scan: ${doc_path}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor."
                violations="${violations}${violations:+$nl}${msg}"
                continue
            fi
            if ! printf '%s' "$anchor_nnn" | grep -qE '^[0-9]+$'; then
                msg="context-factcheck-scan: ${doc_path}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor."
                violations="${violations}${violations:+$nl}${msg}"
                continue
            fi

            # Reject injection tokens in CMD (fail-closed).
            if printf '%s' "$anchor_cmd" | grep -qE '\$\(|`|>|;|&&|&'; then
                msg="context-factcheck-scan: ${doc_path}:${linenum} disallowed token in probe command. Only allowlisted verbs are permitted."
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
                    msg="context-factcheck-scan: ${doc_path}:${linenum} disallowed probe verb '${verb}'. Allowed: ${ALLOWED_VERBS}."
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

            # Integer mismatch → violation.
            if [ "$probe_int" != "$anchor_nnn" ]; then
                msg="context-factcheck-scan: ${doc_path}:${linenum} claims ${anchor_nnn} but the count probe returns ${probe_int}. Update the count or the docs."
                violations="${violations}${violations:+$nl}${msg}"
            fi
        elif printf '%s\n' "$line" | grep -qE '<!--[[:space:]]*count:[[:space:]]*.+-->[^0-9]'; then
            nnn_val=$(printf '%s\n' "$line" | sed 's/.*-->//' | tr -d '[:space:]' | grep -oE '^[^<]*' | head -1)
            if [ -n "$nnn_val" ] && ! printf '%s' "$nnn_val" | grep -qE '^[0-9]+$'; then
                msg="context-factcheck-scan: ${doc_path}:${linenum} malformed count anchor — NNN must be a bare integer. Fix or remove the anchor."
                violations="${violations}${violations:+$nl}${msg}"
            fi
        fi

        # ── Claim class 3: identifier corruption (`_`→`*`) ──────────────────
        if printf '%s\n' "$line" | grep -qE '[[:alnum:]]\*[[:alnum:]]'; then
            corrupt_token=$(printf '%s\n' "$line" |
                grep -oE '[[:alnum:]_]*\*[[:alnum:]_]*' | grep -E '[[:alnum:]]\*[[:alnum:]]' | head -1)
            msg="context-factcheck-scan: ${doc_path}:${linenum} contains a '_'→'*' identifier corruption (e.g. \`${corrupt_token}\`). Restore the underscore."
            violations="${violations}${violations:+$nl}${msg}"
        fi

    done <<BLOB
$blob
BLOB

done <<DOCS
$docs
DOCS

if [ -n "$violations" ]; then
    printf '%s\n' "$violations"
    exit 1
fi
exit 0
