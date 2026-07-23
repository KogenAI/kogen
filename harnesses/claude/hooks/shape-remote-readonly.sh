#!/bin/bash
# shape-remote-readonly.sh — PreToolUse hook: classify every `ssh` invocation
# in shape-mode Bash against a closed read-only remote grammar. Deny BEFORE
# ssh ever starts on any unclassified, mutating, or malformed remote payload.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: shape
# harnesses: all
# rationale: Active only in shape-mode Bash. Executes remote read-only probes against exact literal non-wildcard SSH-config aliases through a closed command/wrapper/operator grammar; denies before ssh invocation on any unclassified or mutating remote payload, malformed argv, or alias-resolution failure. Composes with claude-debug-bash-guard (which does not recursively classify quoted remote payloads) and orchestrator-no-source-edit (unaffected — this hook governs a different axis, remote command classification, not local write-scope).
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Contract (see codegen/pitches/draft/every-harness-shapes-and-spikes.md):
#   - Only a top-level `ssh` segment (no shell-out wrapper hiding it) is
#     classified here; every OTHER command in the same chain still passes
#     through claude-debug-bash-guard and friends unaffected.
#   - Before the alias: only -n, -T, -o BatchMode=yes,
#     -o ConnectTimeout=<1..30>, -o ServerAliveInterval=<1..30>,
#     -o ServerAliveCountMax=<1..3> are allowed. Any other flag denies.
#   - The remote host MUST be an exact literal, non-wildcard Host alias
#     declared in ~/.ssh/config (verified via `ssh -G <alias>` at classify
#     time — a config/resolution error denies loud, never allow).
#   - The remote payload (the ssh command's trailing argv) is parsed with
#     the same split_command_segments/command_word_of_segment helpers used
#     for local commands, then every resulting command word must match the
#     closed allowed-family list below (identity/system, files/text,
#     processes/network, git read-only, packages query, services/containers
#     status, HTTP GET/HEAD, runtime version). Anything else denies.
#   - Wrappers `sudo -n` and `command` are transparently unwrapped (one
#     layer each, repeatedly); `sh|bash|zsh -c`, interpreters with inline
#     code, command substitution, eval/source, redirects, heredocs, and
#     backgrounding all deny.
#   - Deny happens BEFORE ssh is ever exec'd — this hook fires at
#     PreToolUse, so a deny here means the ssh process never starts.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

role=$(resolve_role)

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

if [ "$role" != "shape" ]; then
    exit 0
fi

# ── Closed remote command-word grammar (representative of the pitch's
# family table: identity/system, files/text, processes/network, git
# read-only, packages query, services/containers status, HTTP GET/HEAD,
# runtime version). ──────────────────────────────────────────────────────
REMOTE_ALLOWED_WORD_ERE='^(pwd|uname|hostname|id|whoami|date|uptime|getconf|df|du|free|vm_stat|ls|find|stat|file|readlink|realpath|wc|grep|rg|awk|cut|sort|uniq|head|tail|tr|sed|printf|echo|test|ps|pgrep|lsof|ss|netstat|git|dpkg|rpm|apt-cache|brew|npm|pip|pip3|gem|systemctl|journalctl|launchctl|docker|podman|curl|wget|node|python|python3|ruby|elixir|mix|java|go)$'

# git: only read-only subcommands after global opts stripped.
git_is_readonly() {
    local seg="$1"
    local stripped
    stripped=$(strip_git_global_opts "$seg")
    local argv
    argv=$(segment_argv_of "$stripped")
    printf '%s' "$argv" | grep -qE '^(status|diff|log|show|rev-parse|ls-files|grep)\b'
}

# find: forbid mutating flags.
find_is_readonly() {
    local seg="$1"
    local argv
    argv=$(segment_argv_of "$seg")
    ! printf '%s' "$argv" | grep -qE -- '-delete|-exec|-execdir|-ok\b'
}

# curl: GET/HEAD-only flag surface, no data/upload/output.
curl_is_readonly() {
    local seg="$1"
    local argv
    argv=$(segment_argv_of "$seg")
    if printf '%s' "$argv" | grep -qE -- '-d|--data|--upload-file|-T|-o[[:space:]]|--output|-X[[:space:]]*(POST|PUT|PATCH|DELETE)'; then
        return 1
    fi
    return 0
}

wget_is_readonly() {
    local seg="$1"
    local argv
    argv=$(segment_argv_of "$seg")
    printf '%s' "$argv" | grep -qE -- '--spider\b'
}

sed_is_readonly() {
    local seg="$1"
    local argv
    argv=$(segment_argv_of "$seg")
    if printf '%s' "$argv" | grep -qE -- '(^|[[:space:]])-i\b'; then
        return 1
    fi
    printf '%s' "$argv" | grep -qE -- '(^|[[:space:]])-n\b'
}

package_is_query() {
    local word="$1" seg="$2"
    local argv
    argv=$(segment_argv_of "$seg")
    case "$word" in
    dpkg) printf '%s' "$argv" | grep -qE -- '(^|[[:space:]])-l|-s\b' ;;
    rpm) printf '%s' "$argv" | grep -qE -- '(^|[[:space:]])-q' ;;
    apt-cache) return 0 ;;
    brew) printf '%s' "$argv" | grep -qE '^(info|list)\b' ;;
    npm) printf '%s' "$argv" | grep -qE '^(view|list)\b' ;;
    pip | pip3) printf '%s' "$argv" | grep -qE '^(show|list)\b' ;;
    gem) printf '%s' "$argv" | grep -qE '^list\b' ;;
    *) return 1 ;;
    esac
}

service_is_status() {
    local word="$1" seg="$2"
    local argv
    argv=$(segment_argv_of "$seg")
    case "$word" in
    systemctl) printf '%s' "$argv" | grep -qE '^(status|show|is-active|is-enabled)\b' ;;
    journalctl) return 0 ;;
    launchctl) printf '%s' "$argv" | grep -qE '^(print|list)\b' ;;
    docker | podman) printf '%s' "$argv" | grep -qE '^(ps|inspect|logs|version|info)\b' ;;
    *) return 1 ;;
    esac
}

runtime_is_version_or_help() {
    local seg="$1"
    local argv
    argv=$(segment_argv_of "$seg")
    printf '%s' "$argv" | grep -qE -- '(^|[[:space:]])(--version|-v|--help|-h|version)\b' || [ -z "$argv" ]
}

# ps/lsof/ss/netstat: forbid signal/execute flags.
proc_net_is_readonly() {
    local word="$1" seg="$2"
    local argv
    argv=$(segment_argv_of "$seg")
    case "$word" in
    ps | pgrep) ! printf '%s' "$argv" | grep -qE -- '(^|[[:space:]])(-9|--signal)\b' ;;
    lsof | ss | netstat) return 0 ;;
    esac
}

# is_remote_command_safe <segment> — classify a single trailing-payload
# segment against the closed remote grammar. Returns 0 (safe) / 1 (deny).
# Tokenizes explicitly (rather than via command_word_of_segment, which
# blindly consumes a leading `sudo` regardless of flags) so `sudo` WITHOUT
# `-n` is correctly denied instead of silently unwrapped.
is_remote_command_safe() {
    local seg="$1"
    local _had_f=0
    case $- in *f*) _had_f=1 ;; esac
    set -f
    # shellcheck disable=SC2206
    local -a toks=($seg)
    [ "$_had_f" = 0 ] && set +f

    local -i idx=0
    local -i n=${#toks[@]}
    local -i iterations=0
    while [ "$iterations" -lt 5 ] && [ "$idx" -lt "$n" ]; do
        case "${toks[$idx]}" in
        sudo)
            if [ "${toks[$((idx + 1))]:-}" != "-n" ]; then
                return 1
            fi
            idx=$((idx + 2))
            ;;
        command)
            idx=$((idx + 1))
            ;;
        *)
            break
            ;;
        esac
        iterations=$((iterations + 1))
    done

    [ "$idx" -ge "$n" ] && return 1
    local word="${toks[$idx]}"
    local seg_rest="${toks[*]:$idx}"
    seg="$seg_rest"

    [ -z "$word" ] && return 1

    # Deny known dangerous interpreters/wrappers explicitly (never fall
    # through to the allow-list, which would just miss them by name).
    case "$word" in
    sh | bash | zsh | eval | source | ".") return 1 ;;
    esac

    if ! printf '%s' "$word" | grep -qE "$REMOTE_ALLOWED_WORD_ERE"; then
        return 1
    fi

    case "$word" in
    git) git_is_readonly "$seg" ;;
    find) find_is_readonly "$seg" ;;
    curl) curl_is_readonly "$seg" ;;
    wget) wget_is_readonly "$seg" ;;
    sed) sed_is_readonly "$seg" ;;
    dpkg | rpm | apt-cache | brew | npm | pip | pip3 | gem) package_is_query "$word" "$seg" ;;
    systemctl | journalctl | launchctl | docker | podman) service_is_status "$word" "$seg" ;;
    node | python | python3 | ruby | elixir | mix | java | go) runtime_is_version_or_help "$seg" ;;
    ps | pgrep | lsof | ss | netstat) proc_net_is_readonly "$word" "$seg" ;;
    *) return 0 ;;
    esac
}

# is_remote_payload_safe <payload> — split on |, &&, || and require every
# resulting segment to pass is_remote_command_safe. A parse failure
# (unbalanced quote) or empty payload after a wrapper strip denies.
is_remote_payload_safe() {
    local payload="$1"
    [ -z "${payload// /}" ] && return 1

    local segments
    if ! segments=$(split_command_segments "$payload"); then
        return 1
    fi

    local seg
    while IFS= read -r seg; do
        [ -z "${seg// /}" ] && continue
        # Redirects, heredocs, backgrounding, command substitution: deny
        # outright before per-command classification.
        if printf '%s' "$seg" | grep -qE '(^|[^><])[<>]|<<|&[[:space:]]*$|\$\('; then
            return 1
        fi
        if ! is_remote_command_safe "$seg"; then
            return 1
        fi
    done <<<"$segments"

    return 0
}

# ── Locate every top-level `ssh` segment in COMMAND and classify it. ──────
segments=$(split_command_segments "$COMMAND") || {
    # unbalanced quote in the outer command — fail closed only if an ssh
    # invocation is even textually present; otherwise this hook has nothing
    # to say and other guards still see the raw (unparsed) command.
    if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:];&|])ssh\b'; then
        deny "BLOCKED by shape-remote-readonly: unbalanced quoting in a command containing ssh — cannot classify, denying closed"
        exit 0
    fi
    exit 0
}

while IFS= read -r seg; do
    [ -z "${seg// /}" ] && continue
    word=$(command_word_of_segment "$seg")
    [ "$word" = "ssh" ] || continue

    argv=$(segment_argv_of "$seg")

    # Walk argv tokens: allow only the bounded transport flag set before the
    # host; first non-flag token is the host; everything after is payload.
    host=""
    payload=""
    # shellcheck disable=SC2206
    _had_f=0
    case $- in *f*) _had_f=1 ;; esac
    set -f
    tokens=($argv)
    [ "$_had_f" = 0 ] && set +f

    ok=1
    i=0
    n=${#tokens[@]}
    while [ "$i" -lt "$n" ]; do
        tok="${tokens[$i]}"
        if [ -z "$host" ]; then
            case "$tok" in
            -n | -T)
                i=$((i + 1))
                continue
                ;;
            -o)
                next="${tokens[$((i + 1))]:-}"
                case "$next" in
                BatchMode=yes) ;;
                ConnectTimeout=*)
                    val="${next#ConnectTimeout=}"
                    [[ "$val" =~ ^([1-9]|[12][0-9]|30)$ ]] || ok=0
                    ;;
                ServerAliveInterval=*)
                    val="${next#ServerAliveInterval=}"
                    [[ "$val" =~ ^([1-9]|[12][0-9]|30)$ ]] || ok=0
                    ;;
                ServerAliveCountMax=*)
                    val="${next#ServerAliveCountMax=}"
                    [[ "$val" =~ ^[123]$ ]] || ok=0
                    ;;
                *) ok=0 ;;
                esac
                i=$((i + 2))
                continue
                ;;
            -*)
                ok=0
                i=$((i + 1))
                continue
                ;;
            *)
                host="$tok"
                i=$((i + 1))
                continue
                ;;
            esac
        else
            payload="$payload $tok"
            i=$((i + 1))
        fi
    done

    # When the remote payload was originally ONE shell-quoted argument on the
    # client side (`ssh host '<remote command>'`), set -f word-splitting
    # above breaks it into whitespace tokens while leaving the literal quote
    # characters stuck to the FIRST and LAST token only — the whole payload
    # starts and ends with the SAME quote char. Strip exactly that one layer
    # before treating payload as its own command string (mirrors the bash -c
    # payload-unquoting already used by command_invokes). A per-argument
    # quote embedded mid-payload (e.g. `find /tmp -name '*.log'`) does NOT
    # start the payload with a quote char, so this never fires there.
    payload="${payload# }"
    case "$payload" in
    \'*\') payload="${payload#\'}" && payload="${payload%\'}" ;;
    \"*\") payload="${payload#\"}" && payload="${payload%\"}" ;;
    esac

    if [ "$ok" != 1 ] || [ -z "$host" ]; then
        deny "BLOCKED by shape-remote-readonly: unrecognized SSH flag, malformed option value, or missing host — denying closed"
        exit 0
    fi

    # Host must be an exact literal alias declared in the SSH config, no
    # wildcard, no ProxyCommand, resolvable via `ssh -G`.
    # SHAPE_REMOTE_SSH_CONFIG is a test-injection seam (defaults to the
    # operator's real ~/.ssh/config) — same shape as other subprocess-boundary
    # seams in this codebase; never read in normal operation as anything but
    # the default.
    ssh_config="${SHAPE_REMOTE_SSH_CONFIG:-$HOME/.ssh/config}"
    if printf '%s' "$host" | grep -qE '[*?]'; then
        deny "BLOCKED by shape-remote-readonly: wildcard host pattern not permitted: $host"
        exit 0
    fi
    if ! grep -qiE "^[[:space:]]*Host[[:space:]]+${host}([[:space:]]|\$)" "$ssh_config" 2>/dev/null; then
        deny "BLOCKED by shape-remote-readonly: host is not a literal alias declared in ~/.ssh/config: $host"
        exit 0
    fi
    resolved=$(ssh -F "$ssh_config" -G "$host" 2>&1) || {
        deny "BLOCKED by shape-remote-readonly: ssh -G failed to resolve host config for $host — denying closed"
        exit 0
    }
    if printf '%s' "$resolved" | grep -qiE '^proxycommand[[:space:]]+\S'; then
        deny "BLOCKED by shape-remote-readonly: resolved host config declares a ProxyCommand — denying closed: $host"
        exit 0
    fi

    if ! is_remote_payload_safe "$payload"; then
        deny "BLOCKED by shape-remote-readonly: remote command payload is not in the closed read-only grammar — denying closed before ssh executes: ${payload# }"
        exit 0
    fi
done <<<"$segments"

exit 0
