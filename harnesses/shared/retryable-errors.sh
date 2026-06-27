#!/usr/bin/env bash
# retryable-errors.sh — single source of truth for transient-error classification.
# Sourced (never executed) by claude stop-resume.sh and, in a later slice, the
# claude + pi dispatch.sh retry loops. Defines three regexes consumed by grep -qE.
# Harness-agnostic: the transport-fault taxonomy (socket closed / ConnectionRefused /
# ETIMEDOUT) is CLI-independent. Keep retryable_regex on ONE single-quoted physical
# line — transient-parity.test.ts extracts it via a single-quoted pattern grep.

retryable_regex='Stream idle timeout|Unable to connect|FailedToOpenSocket|ConnectionRefused|API Error: 529|API Error: 500|API Error: 502|API Error: 503|API Error: 504|overloaded_error|Internal server error|upstream connect error|connection reset|socket hang up|ETIMEDOUT|context deadline exceeded|File has been modified since read|has been unexpectedly modified|socket connection was closed|Connection closed mid-response'
rate_limit_regex='API Error: 429|rate_limit|rate limit'
hard_fail_regex='API Error: 400|API Error: 401|API Error: 403|API Error: 404|Prompt is too long|invalid_api_key|authentication_error|permission_error'
