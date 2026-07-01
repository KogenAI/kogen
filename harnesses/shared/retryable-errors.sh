#!/usr/bin/env bash
# retryable-errors.sh — single source of truth for transient-error classification.
# Sourced (never executed) by interactive-session-fallback Stop hooks in the
# claude harness. Mirrored in Elixir by `LoopQueue.transient?/1`'s
# `@retryable_regex` (test_harness/lib/codegen_test_harness/loop_queue.ex) for
# the deterministic orchestration loop's per-role retry classifier — no active
# parity test enforces sync between the two; keep them in lockstep by hand.
# Defines three regexes consumed by grep -qE. Harness-agnostic: the
# transport-fault taxonomy (socket closed / ConnectionRefused / ETIMEDOUT) is
# CLI-independent. Keep retryable_regex on ONE single-quoted physical line.

retryable_regex='Stream idle timeout|Unable to connect|FailedToOpenSocket|ConnectionRefused|API Error: 529|API Error: 500|API Error: 502|API Error: 503|API Error: 504|overloaded_error|Internal server error|upstream connect error|connection reset|socket hang up|ETIMEDOUT|context deadline exceeded|File has been modified since read|has been unexpectedly modified|socket connection was closed|Connection closed mid-response'
rate_limit_regex='API Error: 429|rate_limit|rate limit'
hard_fail_regex='API Error: 400|API Error: 401|API Error: 403|API Error: 404|Prompt is too long|invalid_api_key|authentication_error|permission_error'
