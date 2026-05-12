#!/usr/bin/env bash
# claude-multi-step.sh — fresh-session orchestrator for multi-step tasks.
#
# Spawns one claude process per step. State persists via checkpoint file +
# session log. System prompt is a FULL REPLACEMENT (not append) — avoids
# paying full AGENTS.md cost on top of step context.
#
# Usage:
#   # Run one step:
#   claude-multi-step
#
#   # Loop until all steps done:
#   while ls ~/.claude/orchestrate-session-*.next-step.json 2>/dev/null | grep -q .; do
#     claude-multi-step || break
#   done
#
# Checkpoint file format (written by /split after each commit):
#   {
#     "session_id": "<id>",
#     "step": <N>,
#     "total_steps": <M>,
#     "log_path": "codegen/logging/20260511_stepN_slug.md",
#     "last_commit_sha": "<sha>",
#     "remaining_steps": ["step N+1 description", ...]
#   }
#
# Exit codes:
#   0 — step completed successfully
#   1 — no checkpoint file found
#   2 — HEAD does not match last_commit_sha (safety guard)
#   3 — claude exited non-zero

set -euo pipefail

CODEGEN_DIR="${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}"
SYSTEM_PROMPT_TEMPLATE="$CODEGEN_DIR/templates/shared/claude-multi-step-system-prompt.txt"
CHECKPOINT_GLOB="$HOME/.claude/orchestrate-session-*.next-step.json"

if [ ! -f "$SYSTEM_PROMPT_TEMPLATE" ]; then
    echo "claude-multi-step: system prompt template not found: $SYSTEM_PROMPT_TEMPLATE" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq required but not found" >&2
    exit 1
fi

# Find checkpoint file.
checkpoint_file=""
for f in $CHECKPOINT_GLOB; do
    [ -f "$f" ] && checkpoint_file="$f" && break
done

if [ -z "$checkpoint_file" ]; then
    echo "No checkpoint file found matching: $CHECKPOINT_GLOB" >&2
    exit 1
fi

echo "Reading checkpoint: $checkpoint_file"

step=$(jq -r '.step // 1' "$checkpoint_file")
total=$(jq -r '.total_steps // "?"' "$checkpoint_file")
log_path=$(jq -r '.log_path // empty' "$checkpoint_file")
last_commit_sha=$(jq -r '.last_commit_sha // empty' "$checkpoint_file")
remaining_count=$(jq '.remaining_steps | length' "$checkpoint_file" 2>/dev/null || echo 0)

echo "Step $step/$total | log=$log_path | remaining_after=$remaining_count"

# Safety guard: verify HEAD matches last_commit_sha.
if [ -n "$last_commit_sha" ]; then
    current_head=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$current_head" ] && [ "$current_head" != "$last_commit_sha" ]; then
        echo "HEAD mismatch: checkpoint expects $last_commit_sha, got $current_head" >&2
        echo "Refusing to proceed — resolve git state first." >&2
        exit 2
    fi
fi

# Build system prompt from template — fill placeholders.
system_prompt=$(sed \
    -e "s|{{STEP}}|$step|g" \
    -e "s|{{TOTAL}}|$total|g" \
    -e "s|{{LOG_PATH}}|$log_path|g" \
    "$SYSTEM_PROMPT_TEMPLATE")

# Remove checkpoint before spawning — crashed step won't auto-retry without review.
# /split writes a new checkpoint on success.
cp "$checkpoint_file" "${checkpoint_file}.bak"
rm -f "$checkpoint_file"

echo "Spawning fresh claude for step $step/$total..."

if claude \
    --model sonnet \
    --effort medium \
    --dangerously-skip-permissions \
    --disallowed-tools EnterPlanMode,ExitPlanMode,EnterWorktree,AskUserQuestion \
    --system-prompt "$system_prompt" \
    --print \
    "Continue orchestration from step $step. Session log: $log_path. Read it to resume."; then
    rm -f "${checkpoint_file}.bak"
    echo "Step $step completed."
    exit 0
else
    rc=$?
    echo "claude exited with code $rc for step $step" >&2
    # Restore checkpoint so operator can retry.
    mv "${checkpoint_file}.bak" "$checkpoint_file"
    exit 3
fi
