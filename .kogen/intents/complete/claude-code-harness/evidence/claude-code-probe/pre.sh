#!/bin/sh
input=$(cat)
case "$input" in *'make '*) printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Kogen machinery owns verification gates."}}\n';; esac
