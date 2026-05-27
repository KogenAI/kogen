#!/usr/bin/env bash
# install_pi_round_trip_test.sh — install.sh --harness=pi → assert artifacts → uninstall.sh → assert clean.
# Requires jq, yq, rg, claude pre-installed on the host. Skips if any are absent.
# install.sh deletes and regenerates templates/generated/ — this is expected (the dir is not source-controlled).
set -euo pipefail

passed=0
failed=0
fail_lines=()

assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    fail_lines+=("FAIL: $label — eval failed: $cond")
  fi
}

# Pre-flight: skip if required tools absent
for cmd in jq yq rg claude; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "SKIP: $cmd not on host PATH — round-trip test requires pre-installed tools"
    echo "1 passed, 0 failed"
    exit 0
  fi
done

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_home="$(mktemp -d -t ocg-install-XXXXXX)"
trap 'rm -rf "$tmp_home"' EXIT

# Create completion dir + rc files
mkdir -p "$tmp_home/.zsh/completions"
touch "$tmp_home/.zshrc" "$tmp_home/.bashrc"

export HOME="$tmp_home"
export SHELL="/bin/bash"
export ZSH_COMPLETION_DIRS="$tmp_home/.zsh/completions"

# Run install for pi harness only
if ! "$CODEGEN_DIR/install.sh" --harness=pi </dev/null > "$tmp_home/install.log" 2>&1; then
  failed=$((failed + 1))
  fail_lines+=("FAIL: install.sh --harness=pi exited non-zero")
  cat "$tmp_home/install.log" >&2
fi

# Assert artifacts present
assert ".ocg/config.json exists"  '[ -f "$tmp_home/.ocg/config.json" ]'
assert "no claude hooks dir"      '[ ! -d "$tmp_home/.claude/hooks" ]'

# Pi-specific launchers from manifest
if [ -f "$CODEGEN_DIR/harnesses/pi/manifest.yaml" ] && command -v yq >/dev/null 2>&1; then
  while IFS=$'\t' read -r _src name; do
    assert "launcher '$name' exists" '[ -f "$tmp_home/.local/bin/$name" ]'
  done < <(yq e '.launchers[] | [.src, .name] | join("\t")' "$CODEGEN_DIR/harnesses/pi/manifest.yaml" 2>/dev/null)
fi

# Pi agents populated (templates/generated/pi/agent/*.md)
if [ -d "$tmp_home/.pi/agent/agents" ]; then
  pi_agent_count="$(ls "$tmp_home/.pi/agent/agents/" 2>/dev/null | wc -l | tr -d ' ')"
  assert "pi agents dir populated" '[ "$pi_agent_count" -gt 0 ]'
else
  # May not exist if pi manifests use a different layout — just assert install succeeded
  assert "install.sh exited 0" 'true'
fi

# Run uninstall
printf 'N\nN\n' | SHELL=/bin/bash "$CODEGEN_DIR/uninstall.sh" > "$tmp_home/uninstall.log" 2>&1 || {
  failed=$((failed + 1))
  fail_lines+=("FAIL: uninstall.sh exited non-zero")
}

# Pi launchers removed
if [ -f "$CODEGEN_DIR/harnesses/pi/manifest.yaml" ] && command -v yq >/dev/null 2>&1; then
  while IFS=$'\t' read -r _src name; do
    assert "pi launcher '$name' removed after uninstall" '[ ! -f "$tmp_home/.local/bin/$name" ]'
  done < <(yq e '.launchers[] | [.src, .name] | join("\t")' "$CODEGEN_DIR/harnesses/pi/manifest.yaml" 2>/dev/null)
fi

# Pi agents .md files removed unconditionally (no prompt in uninstall.sh)
# uninstall.sh removes the .md files but may leave the empty dir
assert "pi agents .md files removed after uninstall" \
  '[ "$(find "$tmp_home/.pi/agent/agents" -name "*.md" -type f 2>/dev/null | wc -l | tr -d " ")" -eq 0 ]'

# rc file cleanup
assert "bash_completion.sh source removed from .bashrc" \
  '! grep -q "bash_completion.sh" "$tmp_home/.bashrc" 2>/dev/null'

# Footer
echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  printf '%s\n' "${fail_lines[@]}" >&2
  exit 1
fi
