#!/bin/bash
# shape-remote-readonly_test.sh — unit tests for shape-remote-readonly.sh
#
# Uses a fixture SSH config (SHAPE_REMOTE_SSH_CONFIG seam) so no live network
# access or real ~/.ssh/config is required. Asserts DENY happens before ssh
# ever executes by pointing `ssh` at a stub script when a test needs to prove
# a would-be-allowed command never actually ran (deny-before-invocation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/shape-remote-readonly.sh"

pass=0
fail=0

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

FIXTURE_CONFIG="$TMP_DIR/ssh_config"
cat >"$FIXTURE_CONFIG" <<'EOF'
Host codegen-test-host
    HostName 10.0.0.99
    User testuser

Host proxied-host
    HostName 10.0.0.100
    User testuser
    ProxyCommand ssh jumpbox -W %h:%p
EOF

run_test() {
    local desc="$1"
    local expected="$2" # "deny" or "allow"
    local cmd="$3"

    local input
    input=$(jq -n --arg cmd "$cmd" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd},agent_type:"",agent_id:""}')

    local stdout
    stdout=$(printf '%s' "$input" | CLAUDE_ROLE="shape" SHAPE_REMOTE_SSH_CONFIG="$FIXTURE_CONFIG" bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="deny"
    else
        outcome="allow"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n  stdout: %s\n' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

H="codegen-test-host"

# ── Local (non-ssh) command unaffected in shape role ──────────────────────
run_test "local command in shape role — unaffected, allow" "allow" \
    "grep -rn foo ."

# ── Local command with 2>&1 piped to a filter — regression for the
# split_command_segments fix: the & inside 2>&1 must not be treated as a
# control-operator split point, which would otherwise leave a bare,
# unresolvable segment that this hook's ssh-classification loop simply
# skips (no ssh word to find) — proves the fix does not introduce any new
# denial on an ordinary local pipeline. ──
run_test "local command with 2>&1 | grep in shape role — unaffected, allow" "allow" \
    "mix test 2>&1 | grep -i warning"

# ── Non-shape role — hook entirely inactive even on a remote mutation ─────
run_test_role() {
    local desc="$1"
    local expected="$2"
    local cmd="$3"
    local role="$4"

    local input
    input=$(jq -n --arg cmd "$cmd" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd},agent_type:"",agent_id:""}')
    local stdout
    stdout=$(printf '%s' "$input" | CLAUDE_ROLE="$role" SHAPE_REMOTE_SSH_CONFIG="$FIXTURE_CONFIG" bash "$GUARD" 2>/dev/null || true)
    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="deny"
    else
        outcome="allow"
    fi
    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n  stdout: %s\n' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}
run_test_role "non-shape role — hook inactive even on remote mutation" "allow" \
    "ssh $H 'apt-get install -y jq'" "debug"

# ── Allowed families (representative) ──────────────────────────────────────
run_test "identity/system: uname" "allow" "ssh $H uname -s"
run_test "identity/system: pwd" "allow" "ssh $H pwd"
run_test "files/text: ls" "allow" "ssh $H ls -la /tmp"
run_test "files/text: grep" "allow" "ssh $H grep -rn foo /var/log"
run_test "files/text: find without -delete" "allow" "ssh $H find /tmp -name '*.log'"
run_test "processes/network: ps" "allow" "ssh $H ps aux"
run_test "git read-only: status" "allow" "ssh $H git -C /srv/app status"
run_test "git read-only: log" "allow" "ssh $H git log -p"
run_test "packages query: dpkg -l" "allow" "ssh $H dpkg -l jq"
run_test "packages query: brew info" "allow" "ssh $H brew info jq"
run_test "services status: systemctl status" "allow" "ssh $H systemctl status nginx"
run_test "services status: docker ps" "allow" "ssh $H docker ps"
run_test "HTTP GET/HEAD: curl -sI" "allow" "ssh $H curl -sI https://example.com"
run_test "HTTP: wget --spider" "allow" "ssh $H wget --spider https://example.com"
run_test "runtime version: node --version" "allow" "ssh $H node --version"
run_test "runtime version: go version" "allow" "ssh $H go version"

# ── Wrappers ────────────────────────────────────────────────────────────────
run_test "wrapper: sudo -n allowed-command" "allow" "ssh $H sudo -n ls /root"
run_test "wrapper: command allowed-command" "allow" "ssh $H command ls /tmp"
run_test "wrapper: sudo WITHOUT -n denies" "deny" "ssh $H sudo ls /root"

# ── Operators (all segments must pass) ─────────────────────────────────────
run_test "operator: pipe, both sides allowed" "allow" "ssh $H 'ps aux | grep nginx'"
run_test "operator: &&, both sides allowed" "allow" "ssh $H 'uname -s && pwd'"
run_test "operator: ||, both sides allowed" "allow" "ssh $H 'ls /tmp || pwd'"
run_test "operator: pipe, one side forbidden -> deny" "deny" "ssh $H 'ps aux | rm -rf /tmp'"

# ── Bounded transport flags ─────────────────────────────────────────────────
run_test "bounded flag: -n -T allowed" "allow" "ssh -n -T $H uname -s"
run_test "bounded flag: BatchMode=yes allowed" "allow" "ssh -o BatchMode=yes $H uname -s"
run_test "bounded flag: ConnectTimeout=5 allowed" "allow" "ssh -o ConnectTimeout=5 $H uname -s"
run_test "bounded flag: ConnectTimeout out of range denies" "deny" "ssh -o ConnectTimeout=999 $H uname -s"
run_test "bounded flag: ServerAliveInterval=10 allowed" "allow" "ssh -o ServerAliveInterval=10 $H uname -s"
run_test "bounded flag: ServerAliveCountMax=2 allowed" "allow" "ssh -o ServerAliveCountMax=2 $H uname -s"
run_test "bounded flag: ServerAliveCountMax out of range denies" "deny" "ssh -o ServerAliveCountMax=9 $H uname -s"
run_test "unknown flag denies: -A (agent forwarding)" "deny" "ssh -A $H uname -s"
run_test "unknown flag denies: -i identity" "deny" "ssh -i /tmp/key $H uname -s"
run_test "unknown flag denies: -p port" "deny" "ssh -p 2222 $H uname -s"
run_test "unknown flag denies: -L forwarding" "deny" "ssh -L 8080:localhost:80 $H uname -s"
run_test "unknown flag denies: -t tty allocation" "deny" "ssh -t $H uname -s"
run_test "unknown flag denies: -J jump host" "deny" "ssh -J jumpbox $H uname -s"
run_test "unknown flag denies: -F alternate config" "deny" "ssh -F /tmp/other-config $H uname -s"
run_test "unknown ssh -o option denies" "deny" "ssh -o StrictHostKeyChecking=no $H uname -s"

# ── Host validation ──────────────────────────────────────────────────────────
run_test "raw IP host denies (not a config alias)" "deny" "ssh 10.0.0.55 uname -s"
run_test "unconfigured DNS name denies" "deny" "ssh not-a-configured-host.example.com uname -s"
run_test "wildcard host pattern denies" "deny" "ssh 'codegen-*' uname -s"
run_test "proxied host (ProxyCommand) denies" "deny" "ssh proxied-host uname -s"

# ── Package/service/container/process/DB/Git mutation ──────────────────────
run_test "package install denies" "deny" "ssh $H 'sudo apt-get install -y jq'"
run_test "package update denies" "deny" "ssh $H 'apt-get update'"
run_test "service restart denies" "deny" "ssh $H systemctl restart nginx"
run_test "container run denies" "deny" "ssh $H docker run -it ubuntu"
run_test "container exec denies" "deny" "ssh $H docker exec -it app bash"
run_test "process kill denies" "deny" "ssh $H kill -9 123"
run_test "git write denies (commit)" "deny" "ssh $H 'git -C /srv/app commit -am wip'"
run_test "git write denies (push)" "deny" "ssh $H 'git -C /srv/app push'"
run_test "filesystem write denies (rm)" "deny" "ssh $H rm -rf /tmp/x"
run_test "filesystem write denies (find -delete)" "deny" "ssh $H \"find /tmp -name '*.log' -delete\""
run_test "curl POST denies" "deny" "ssh $H curl -X POST https://example.com"
run_test "curl with data flag denies" "deny" "ssh $H \"curl -d 'x=1' https://example.com\""
run_test "sed -i denies" "deny" "ssh $H \"sed -i 's/a/b/' /etc/hosts\""

# ── Interpreter / substitution / redirect / heredoc / backgrounding ────────
run_test "sh -c wrapper denies" "deny" "ssh $H \"sh -c 'rm -rf /tmp'\""
run_test "bash -c wrapper denies" "deny" "ssh $H \"bash -c 'id'\""
run_test "eval denies" "deny" "ssh $H \"eval 'ls'\""
run_test "command substitution denies" "deny" "ssh $H 'echo \$(whoami)'"
run_test "redirect denies" "deny" "ssh $H 'ls > /tmp/out.txt'"
run_test "backgrounding denies" "deny" "ssh $H 'sleep 100 &'"

# ── Unknown verb / malformed payload ─────────────────────────────────────────
run_test "unknown/unclassified verb denies" "deny" "ssh $H some-unknown-binary --flag"
run_test "unbalanced quote in payload denies" "deny" "ssh $H \"echo 'unterminated"

# ── Deny-before-invocation proof: a stub `ssh` on PATH would leave a
# sentinel file if the REAL remote command ever executed (distinguishing a
# legitimate local -G resolution call from an actual remote-command dispatch
# — the guard only ever emits a JSON allow/deny, it never itself execs the
# remote command, but this proves the classification path never shells out
# to run the payload during a deny). ─────────────────────────────────────────
STUB_BIN_DIR="$TMP_DIR/stub-bin"
mkdir -p "$STUB_BIN_DIR"
SENTINEL="$TMP_DIR/ssh-real-invocation.marker"
# Locate the REAL ssh binary (an absolute path outside STUB_BIN_DIR) once,
# up front, so the stub never has to re-resolve `ssh` through a PATH that
# includes itself (which would recurse into the stub).
REAL_SSH_BIN=""
for _candidate in /usr/bin/ssh /bin/ssh /usr/local/bin/ssh /opt/homebrew/bin/ssh; do
    if [ -x "$_candidate" ]; then
        REAL_SSH_BIN="$_candidate"
        break
    fi
done
if [ -z "$REAL_SSH_BIN" ]; then
    echo "FAIL: could not locate a real ssh binary for the stub — skipping deny-before-invocation tests"
    fail=$((fail + 1))
    REAL_SSH_BIN="/usr/bin/ssh"
fi

cat >"$STUB_BIN_DIR/ssh" <<EOF
#!/bin/bash
# Stub ssh: -G resolution calls pass through to the real ssh binary
# (read-only, no network, resolved by absolute path — never re-resolved
# through PATH, which would recurse into this stub). Any OTHER invocation
# (i.e. an attempt to actually run the remote payload) writes a sentinel —
# that would mean the guard let a denied command execute, which must never
# happen.
case " \$* " in
*" -G "*) exec "$REAL_SSH_BIN" "\$@" ;;
*)
    printf 'REAL SSH INVOCATION: %s\\n' "\$*" >>"$SENTINEL"
    exit 1
    ;;
esac
EOF
chmod +x "$STUB_BIN_DIR/ssh"

run_deny_before_invocation_test() {
    local desc="$1"
    local cmd="$2"

    rm -f "$SENTINEL"
    local input
    input=$(jq -n --arg cmd "$cmd" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd},agent_type:"",agent_id:""}')
    local stdout
    stdout=$(printf '%s' "$input" | CLAUDE_ROLE="shape" SHAPE_REMOTE_SSH_CONFIG="$FIXTURE_CONFIG" PATH="$STUB_BIN_DIR:$PATH" bash "$GUARD" 2>/dev/null || true)

    local denied=0
    printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' && denied=1

    if [ "$denied" != 1 ]; then
        printf 'FAIL: %s — expected deny verdict, got: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
        return
    fi
    if [ -f "$SENTINEL" ]; then
        printf 'FAIL: %s — deny verdict returned but the real remote command WAS invoked: %s\n' "$desc" "$(cat "$SENTINEL")"
        fail=$((fail + 1))
        return
    fi
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s (deny occurred before any ssh remote-command invocation)\n' "$desc"
    pass=$((pass + 1))
}

run_deny_before_invocation_test "package install denied before ssh ever runs the remote command" \
    "ssh $H 'sudo apt-get install -y jq'"
run_deny_before_invocation_test "git push denied before ssh ever runs the remote command" \
    "ssh $H 'git -C /srv/app push'"
run_deny_before_invocation_test "unknown verb denied before ssh ever runs the remote command" \
    "ssh $H some-unknown-binary --flag"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
