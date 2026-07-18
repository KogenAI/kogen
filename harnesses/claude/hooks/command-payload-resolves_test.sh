#!/bin/bash
# command-payload-resolves_test.sh — asserts every slash command named as a
# recurring-cadence PAYLOAD in a prompt body actually resolves to a command
# file installed under harnesses/claude/commands/.
#
# This catches the exact defect that shipped for seven days: a prompt body
# said "drive the cadence via the Skill/scheduler tools available to you"
# with no named command, the model guessed `/babysit`, and every wake opened
# with "Unknown skill: babysit" until the model rediscovered its own system
# prompt. Naming the payload is necessary but not sufficient — the named
# command must actually exist on disk, checked here at make-test time
# instead of discovered only at first fire.
#
# Tests:
#   1: /babysit is named as a cadence payload in babysit.txt's prompt body
#   2: /babysit resolves to harnesses/claude/commands/babysit.md
#   3: a deliberately-bogus payload name does NOT resolve (proves the check
#      can fail, not vacuously pass)
#   4: every real `/<name>` cadence payload found across all prompt bodies
#      resolves to a command file (.md or .md.j2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROMPT_BODIES_DIR="$CODEGEN_DIR/harnesses/shared/prompt-bodies"
COMMANDS_DIR="$CODEGEN_DIR/harnesses/claude/commands"

pass=0
fail=0

assert_command_resolves() {
    local desc="$1"
    local name="$2" # command name without leading slash, no .md

    if [[ -f "$COMMANDS_DIR/${name}.md" || -f "$COMMANDS_DIR/${name}.md.j2" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — no %s.md or %s.md.j2 under %s\n' "$desc" "$name" "$name" "$COMMANDS_DIR"
        fail=$((fail + 1))
    fi
}

assert_command_absent() {
    local desc="$1"
    local name="$2"

    if [[ -f "$COMMANDS_DIR/${name}.md" || -f "$COMMANDS_DIR/${name}.md.j2" ]]; then
        printf 'FAIL: %s — expected %s to be ABSENT but it resolved\n' "$desc" "$name"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# Test 1: babysit.txt names /babysit as the cadence payload.
if grep -q '/babysit' "$PROMPT_BODIES_DIR/babysit.txt"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: babysit.txt names /babysit as the cadence payload\n'
    pass=$((pass + 1))
else
    printf 'FAIL: babysit.txt does not name /babysit anywhere — cadence has no named entry point\n'
    fail=$((fail + 1))
fi

# Test 2: /babysit resolves to a real command file.
assert_command_resolves "/babysit resolves to a command file" "babysit"

# Test 3: RED proof — a bogus payload name must NOT resolve. Confirms this
# check can actually fail rather than vacuously passing every name.
assert_command_absent "bogus payload name does not resolve (RED proof)" "definitely-not-a-real-command-xyz"

# Test 4: sweep every /<name> token appearing in ANY prompt body on a line
# that mentions "payload" AND "cadence" together — the only place a prompt
# body should be naming a recurring-wake entry point. Built-in Claude Code
# skills (e.g. /loop, which schedules the cadence but is not a codegen
# command file) are excluded from the resolution check via BUILTIN_SKILLS —
# they are named as the SCHEDULING mechanism, not the payload dispatched on
# each wake, and have no file under harnesses/claude/commands/ by design.
BUILTIN_SKILLS="loop"
is_builtin_skill() {
    local name="$1"
    local skill
    for skill in $BUILTIN_SKILLS; do
        [ "$skill" = "$name" ] && return 0
    done
    return 1
}

found_any=0
while IFS= read -r line; do
    while [[ "$line" =~ (^|[^A-Za-z0-9_/])/([a-z][a-z0-9_-]*) ]]; do
        cmd_name="${BASH_REMATCH[2]}"
        found_any=1
        if is_builtin_skill "$cmd_name"; then
            [ -n "${VERBOSE:-}" ] && printf 'SKIP: /%s is a built-in skill, not a codegen command\n' "$cmd_name"
        else
            assert_command_resolves "cadence-payload token /$cmd_name (from prompt body scan) resolves" "$cmd_name"
        fi
        line="${line#*"${BASH_REMATCH[0]}"}"
    done
done < <(grep -riE "cadence.*payload|payload.*cadence" "$PROMPT_BODIES_DIR"/*.txt 2>/dev/null || true)

if [ "$found_any" -eq 0 ]; then
    printf 'FAIL: sweep found zero cadence-payload lines across prompt bodies — scan pattern may be broken\n'
    fail=$((fail + 1))
fi

echo ""
echo "$pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
