#!/usr/bin/env bash
# Probe 18 (offline): the Codex rendering's in-scope denials on a disposable scope-shaped directory.
set -u
P=/private/tmp/claude-501/kogen-prep5b/probe/p18; rm -rf $P; mkdir -p $P/{c,h,t} $P/scope/{sessions,agents}
echo owned > $P/scope/.kogen-owned; echo env > $P/scope/environments.toml; echo a > $P/scope/agents/kogen_boundary.toml; echo '{}' > $P/scope/auth.json
sb() { sandbox-exec -f /private/tmp/claude-501/kogen-prep5b/probe/wb-codex.sb.tmpl -D CANDIDATE=$P/c -D HARNESS_HOME=$P/h -D BUILD_TMP=$P/t -D CODEX_SCOPE=$P/scope -D LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" "$@"; }
run() { local name="$1"; shift; out=$("$@" 2>&1); echo "[$name] exit=$? ${out:+out=$(echo "$out"|tr '\n' ' '|cut -c1-140)}"; }
run rollout-write        sb sh -c "echo r > $P/scope/sessions/rollout.jsonl"
run history-append       sb sh -c "echo h >> $P/scope/history.jsonl"
run config-toml-write    sb sh -c "echo '[projects]' > $P/scope/config.toml"
run auth-json-refresh    sb sh -c "echo '{\"refreshed\":1}' > $P/scope/auth.json.tmp && mv $P/scope/auth.json.tmp $P/scope/auth.json"
run hooks-json-create    sb sh -c "echo '{}' > $P/scope/hooks.json"
run plugins-dir-create   sb mkdir $P/scope/plugins
run rules-dir-create     sb mkdir $P/scope/rules
run config-d-create      sb mkdir $P/scope/config.d
run agents-md-create     sb sh -c "echo x > $P/scope/AGENTS.md"
run env-toml-overwrite   sb sh -c "echo x > $P/scope/environments.toml"
run env-toml-rename-away sb mv $P/scope/environments.toml $P/scope/env.bak
run agents-def-overwrite sb sh -c "echo x > $P/scope/agents/kogen_boundary.toml"
run agents-dir-rename    sb mv $P/scope/agents $P/scope/agents.bak
run owned-marker-delete  sb rm $P/scope/.kogen-owned
run hooks-via-rename     sb sh -c "echo '{}' > $P/scope/h.tmp && mv $P/scope/h.tmp $P/scope/hooks.json"
echo "[scope after] $(cd $P/scope && find . | sort | tr '\n' ' ')"
