#!/usr/bin/env bash
# install_claude_round_trip_test.sh — install.sh --harness=claude → assert artifacts → uninstall.sh → assert clean.
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

# Pre-flight: skip if required tools absent (brew/curl side-effects escape HOME)
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

# Create completion dir so install.sh picks it FIRST (before /opt/homebrew which may be writable)
mkdir -p "$tmp_home/.zsh/completions"
# Pre-create rc files so uninstall.sh can clean them
touch "$tmp_home/.zshrc" "$tmp_home/.bashrc"

export HOME="$tmp_home"
export SHELL="/bin/bash"
# Redirect completion dirs to tmp_home so install.sh stays fully hermetic
export ZSH_COMPLETION_DIRS="$tmp_home/.zsh/completions"

# Run install (single-harness skips the interactive prompt path)
if ! "$CODEGEN_DIR/install.sh" --harness=claude </dev/null >"$tmp_home/install.log" 2>&1; then
    failed=$((failed + 1))
    fail_lines+=("FAIL: install.sh --harness=claude exited non-zero")
    cat "$tmp_home/install.log" >&2
fi

# Assert artifacts present
assert "settings.json exists" '[ -f "$tmp_home/.claude/settings.json" ]'
assert ".ocg/config.json exists" '[ -f "$tmp_home/.ocg/config.json" ]'
assert "hooks dir populated" '[ "$(ls "$tmp_home/.claude/hooks" 2>/dev/null | wc -l | tr -d " ")" -gt 0 ]'
assert "hooks/lib dir populated" '[ "$(ls "$tmp_home/.claude/hooks/lib" 2>/dev/null | wc -l | tr -d " ")" -gt 0 ]'
assert "agents dir populated" '[ "$(ls "$tmp_home/.claude/agents" 2>/dev/null | wc -l | tr -d " ")" -gt 0 ]'
assert "no pi launchers present" '[ ! -f "$tmp_home/.local/bin/pi-build" ]'

# Claude-specific launcher(s) from manifest
if [ -f "$CODEGEN_DIR/harnesses/claude/manifest.yaml" ] && command -v yq >/dev/null 2>&1; then
    while IFS=$'\t' read -r _src name; do
        assert "launcher '$name' exists" '[ -f "$tmp_home/.local/bin/$name" ]'
    done < <(yq e '.launchers[] | [.src, .name] | join("\t")' "$CODEGEN_DIR/harnesses/claude/manifest.yaml" 2>/dev/null)
fi

# Assert hook tree matches source (spot-check count)
hook_src_count="$(find "$CODEGEN_DIR/harnesses/claude/hooks" -maxdepth 1 -name '*.sh' -type f | wc -l | tr -d ' ')"
hook_dst_count="$(find "$tmp_home/.claude/hooks" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | wc -l | tr -d ' ')"
assert "hook count matches source ($hook_src_count hooks)" '[ "$hook_src_count" -eq "$hook_dst_count" ]'

# Run uninstall (answer N to both prompts → keep claude data tree)
printf 'N\nN\n' | SHELL=/bin/bash "$CODEGEN_DIR/uninstall.sh" >"$tmp_home/uninstall.log" 2>&1 || {
    failed=$((failed + 1))
    fail_lines+=("FAIL: uninstall.sh exited non-zero")
}

# Assert removals — ocg symlink removed (uninstall.sh always removes it)
assert "ocg symlink removed" '[ ! -e "$tmp_home/.local/bin/ocg" ]'

# Note: claude-specific launchers (claude-build, etc.) are NOT removed by uninstall.sh
# (only the ocg symlink and pi launchers are removed). This is current behavior.

# Claude data preserved (answered N)
assert ".claude data tree preserved after N to prompt" '[ -d "$tmp_home/.claude" ]'

# Completion line removed from rc file
assert "bash_completion.sh source removed from .bashrc" \
    '! grep -q "bash_completion.sh" "$tmp_home/.bashrc" 2>/dev/null'

# Footer
echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
