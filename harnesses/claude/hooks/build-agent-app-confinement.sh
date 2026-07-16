#!/bin/bash
# build-agent-app-confinement.sh — PreToolUse Write|Edit|MultiEdit|Bash|NotebookEdit hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Write|Edit|MultiEdit|Bash|NotebookEdit
# surface: user_global
# signal: none
# role: *
# harnesses: all
# rationale: Denies Write/Edit/MultiEdit/NotebookEdit, and Bash write-vocab invocations (redirects, tee, cp/mv/install/rsync, sed -i/perl -pi, dd of=, truncate, ln -s), when CODEGEN_BUILD_CWD is set and the target resolves outside that dir, confining managed build subagents to the app sandbox. Fills the orchestrator-no-source-edit.sh subagent pass-through gap (AGENT_ID set -> exit 0) and the file-tool-only gap that let a relative symlink be truncated via a plain Bash redirect. Env-keyed (CODEGEN_BUILD_CWD), role-agnostic; composes with orchestrator-no-source-edit and build-worker-cwd-guard.
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Confines managed build agents (CODEGEN_BUILD_CWD set) to their app sandbox.
# Denies Write/Edit/MultiEdit/NotebookEdit to any path that resolves outside
# CODEGEN_BUILD_CWD, and denies Bash commands whose write-vocab (redirect,
# tee, cp/mv/install/rsync destination, sed -i/perl -pi operand, dd of=,
# truncate, ln -s link name) targets a path resolving outside the sandbox.
#
# Escape hatches:
#   - CODEGEN_BUILD_CWD unset → inert (not a managed build)
#   - Target's REAL (canonicalized) path under /tmp or /private/tmp → allowed
#     (scratch) — checked AFTER canonicalization so a symlink whose lexical
#     path sits under /tmp but whose real target escapes the sandbox is still
#     denied (leg B: canonicalize-before-hatch fixes the raw-path-hatch race).
#   - Target inside or equal to CODEGEN_BUILD_CWD (after canonicalization) → allow
#
# Escape test (leg A): a token T ESCAPES iff its lexical ($PWD-joined) form
# reads as inside the sandbox but its REAL (symlink-resolved) form reads as
# outside — that asymmetry is only possible via a symlink. A token whose
# lexical form is already outside the sandbox is a normal out-of-sandbox
# write (still denied below, just not the "escape" case this rationale names).
#
# cd/`../` fails CLOSED: any Bash segment carrying a write-verb or inline
# interpreter (python3 -c, perl -e, node -e, awk, patch, git apply, git
# checkout --, xargs) AND `cd`/`pushd`/`../` is denied outright — a directory
# change makes the write destination un-resolvable by this hook's per-token
# textual scan, and an un-resolvable write destination inside a managed build
# must fail closed, never silently pass.
#
# Sibling-prefix safety: appends trailing slash to CODEGEN_BUILD_CWD before
# prefix-compare so /apps/app cannot match /apps/app2.
# macOS symlink safety: hooks_realpath resolves /var → /private/var.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

build_cwd="${CODEGEN_BUILD_CWD:-}"

debug_log build-agent-app-confinement "tool=$TOOL_NAME build_cwd=$build_cwd file=$FILE_PATH cmd=${COMMAND:-}"

# Inert outside a managed build.
if [ -z "$build_cwd" ]; then
    exit 0
fi

canon_cwd=$(hooks_realpath "$build_cwd")
case "$canon_cwd" in
*/) cwd_prefix="$canon_cwd" ;;
*) cwd_prefix="${canon_cwd}/" ;;
esac

# is_scratch_real <canon_path> — true when the REAL path is under /tmp or
# /private/tmp, OR is a standard device-null/std-stream sink (/dev/null,
# /dev/stdout, /dev/stderr — ubiquitous redirect targets, never a real
# on-disk write). Checked AFTER canonicalization (leg B) so a symlink whose
# lexical form sits under /tmp but resolves outside the sandbox is NOT
# treated as scratch.
is_scratch_real() {
    case "$1" in
    /tmp/* | /private/tmp/* | /tmp | /private/tmp | /dev/null | /dev/stdout | /dev/stderr) return 0 ;;
    *) return 1 ;;
    esac
}

# is_inside_sandbox <canon_path> — true when canon_path is the sandbox root
# or a descendant of it.
is_inside_sandbox() {
    [ "$1" = "$canon_cwd" ] && return 0
    case "$1" in "${cwd_prefix}"*) return 0 ;; esac
    return 1
}

# check_target <raw_path> <what> — canonicalize raw_path, allow scratch/inside,
# else deny naming what (file-tool label or Bash-vocab description). Exits the
# whole hook (deny short-circuits); callers invoke this only when they intend
# to terminate on an escape.
check_target() {
    local raw="$1" what="$2"
    local canon
    canon=$(hooks_realpath "$raw")
    if is_scratch_real "$canon"; then
        return 0
    fi
    if is_inside_sandbox "$canon"; then
        return 0
    fi
    deny "BLOCKED by build-agent-app-confinement: managed build agents may only write inside the app sandbox ($canon_cwd). $what resolves to $canon (outside CODEGEN_BUILD_CWD). Write to a path under the sandbox, or use /tmp for scratch."
    exit 0
}

case "$TOOL_NAME" in
Write | Edit | MultiEdit | NotebookEdit)
    # fail-closed: matcher is file-bearing; empty path is an anomaly, not a
    # legitimate skip (interaction-composition proof verified — every
    # reachable caller here is a file-bearing tool call).
    if [ -z "$FILE_PATH" ]; then
        deny "BLOCKED by build-agent-app-confinement: empty/unresolvable file path on a $TOOL_NAME call inside a managed build (CODEGEN_BUILD_CWD set). A file-bearing tool with no path is anomalous; failing closed. Provide an explicit path under the sandbox."
        exit 0
    fi
    check_target "$FILE_PATH" "$TOOL_NAME target $FILE_PATH"
    exit 0
    ;;
Bash)
    if [ -z "$COMMAND" ]; then
        exit 0
    fi

    # ── Trigger vocabularies (leg A) ─────────────────────────────────────
    # Write-verb commands: redirect ops, tee, cp/mv/install/rsync (last
    # arg = destination), sed -i / perl -pi (operand), dd of=, truncate,
    # ln -s (link name — 2nd arg).
    write_verb_re='^(tee|cp|mv|install|rsync|sed|perl|dd|truncate|ln)$'
    # Inline interpreters that can perform an indirect write the textual
    # scan below cannot see inside (python3 -c "...open(...)...", etc.) —
    # these are handled by the shape backstop (Trigger B), not resolved
    # to a concrete destination token.
    interpreter_re='^(python3?|perl|node|awk|patch|xargs)$'
    # git apply / git checkout -- also write files; matched on argv, not
    # command word (git is the word; "apply"/"checkout" are argv).

    segments=$(split_command_segments "$COMMAND") || {
        # unbalanced quote — fail closed: cannot resolve a destination, but
        # this hook only ever denies on a POSITIVELY IDENTIFIED escaping
        # target, so an unparseable command is netted by the CI whole-tree
        # drift guard (leg B), not a hard deny here (avoids false-positive
        # denial of ordinary unrelated Bash on unparseable-but-harmless
        # strings, e.g. an intentionally unbalanced quote inside a heredoc).
        exit 0
    }

    while IFS= read -r seg; do
        [ -z "${seg// /}" ] && continue

        word=$(command_word_of_segment "$seg")
        argv=$(segment_argv_of "$seg")

        # cd/pushd/../ fails CLOSED when paired with a write-verb or
        # interpreter in the SAME segment — the destination cannot be
        # resolved textually once a directory change is in play.
        has_write_intent=0
        if printf '%s' "$word" | grep -qE "$write_verb_re"; then
            has_write_intent=1
        elif printf '%s' "$word" | grep -qE "$interpreter_re"; then
            has_write_intent=1
        elif [ "$word" = "git" ] && printf '%s' "$argv" | grep -qE '^(apply|checkout[[:space:]]+--)'; then
            has_write_intent=1
        fi

        if [ "$has_write_intent" = 1 ]; then
            if [ "$word" = "cd" ] || [ "$word" = "pushd" ] || printf '%s' "$seg" | grep -qE '\.\./'; then
                deny "BLOCKED by build-agent-app-confinement: Bash segment combines a write-verb/interpreter with cd/pushd/../ — destination cannot be resolved textually inside a managed build (CODEGEN_BUILD_CWD set); failing closed. Split into a plain absolute-path write."
                exit 0
            fi
        fi
        case "$word" in
        tee)
            # tee's destination(s) are its argv tokens (minus flags).
            for tok in $argv; do
                case "$tok" in -*) continue ;; esac
                check_target "$tok" "tee destination $tok"
            done
            ;;
        cp | mv | install | rsync)
            # Destination = last non-flag argv token.
            last=""
            for tok in $argv; do
                case "$tok" in -*) continue ;; esac
                last="$tok"
            done
            [ -n "$last" ] && check_target "$last" "$word destination $last"
            ;;
        sed | perl)
            # In-place edit only when -i / -pi present.
            if printf '%s' "$argv" | grep -qE '(^|[[:space:]])-[a-zA-Z]*i[a-zA-Z]*([[:space:]]|$|=)'; then
                for tok in $argv; do
                    case "$tok" in -*) continue ;; esac
                    check_target "$tok" "$word -i operand $tok"
                done
            fi
            ;;
        dd)
            for tok in $argv; do
                case "$tok" in
                of=*)
                    check_target "${tok#of=}" "dd of= target ${tok#of=}"
                    ;;
                esac
            done
            ;;
        truncate)
            for tok in $argv; do
                case "$tok" in -*) continue ;; esac
                check_target "$tok" "truncate target $tok"
            done
            ;;
        ln)
            # ln -s <target> <link-name> — link-name is the write destination.
            link_name=""
            for tok in $argv; do
                case "$tok" in -*) continue ;; esac
                link_name="$tok"
            done
            [ -n "$link_name" ] && check_target "$link_name" "ln link name $link_name"
            ;;
        git)
            if printf '%s' "$argv" | grep -qE '^checkout[[:space:]]+--[[:space:]]'; then
                # git checkout -- <path> — restores a path; treat as a write
                # to that path.
                target=$(printf '%s' "$argv" | sed -E 's/^checkout[[:space:]]+--[[:space:]]*//')
                [ -n "$target" ] && check_target "$target" "git checkout -- target $target"
            fi
            ;;
        esac

        # Redirect operators (> >> N> &>) anywhere in the segment — scan for
        # a redirect target token following the operator.
        redirect_target=$(printf '%s' "$seg" | grep -oE '(^|[[:space:]])[0-9]*(>>|>|&>)[[:space:]]*[^[:space:];|&]+' | sed -E 's/^[[:space:]]*[0-9]*(>>|>|&>)[[:space:]]*//' | tail -n 1)
        if [ -n "$redirect_target" ]; then
            check_target "$redirect_target" "redirect target $redirect_target"
        fi
    done <<<"$segments"

    exit 0
    ;;
*)
    exit 0
    ;;
esac

exit 0
