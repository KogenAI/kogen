#!/usr/bin/env bash
# pitch-format-validator_test.sh — unit tests for pitch-format-validator.sh
#
# Tests:
#   1:  no TRANSCRIPT_PATH → allow
#   2:  shape + well-formed Questions block → allow
#   3:  shape + ## Questions with zero ### Q headings → block
#   4:  shape + Q1 with only one option bullet → block
#   5:  shape + no ## Questions block → allow
#   6:  ops + malformed Questions (zero Q headings) → block
#   7:  refactor + malformed Questions (zero Q headings) → block
#   8:  empty role + malformed Questions → allow
#   9:  debug role + malformed Questions → allow
#  10:  STOP_HOOK_ACTIVE=true + malformed Questions → allow
#  11:  stray Answers Q3 with no Q3 in Questions → block
#  12:  orphan ## Answers with no ## Questions → allow
#  13:  > Status: SHAPED → allow
#  14:  > Status: BOGUS → block
#  15:  no > Status: line → allow
#  16:  PI_ROLE=ops + malformed Questions → block
#  17:  block reason includes "pitch-format-validator" (traceability)
#  18:  frontmatter status: SHAPED → allow
#  19:  frontmatter status: BOGUS → block
#  20:  frontmatter status: SHAPED + valid Questions block → allow (frontmatter inert to Q/A extraction)
#  21:  frontmatter status: SHAPED + malformed Questions (zero Q headings) → block (Q/A validation still runs)
#  22:  frontmatter status: SHAPED + >64 KB body → allow, no 141/SIGPIPE false-miss (regression)
#  23:  frontmatter status: BOGUS + >64 KB body → block (status extraction still correct at size)
#  24:  frontmatter waives: [no-such-hook] → block (unknown registry id)
#  25:  frontmatter waives: [session-log-writer-only] → block (real id, not waivable: true)
#  26:  frontmatter waives: [prompt-budget-writer-only] → allow (real id, waivable: true)
#  27:  frontmatter with no waives: line at all → allow (absent = none)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/pitch-format-validator.sh"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -q "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -q "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# make_stop_json <cwd> <stop_hook_active> <transcript_path>
# Emits the JSON payload for a Stop event to stdout.
make_stop_json() {
    local cwd="$1"
    local stop_active="${2:-false}"
    local transcript_path="${3:-}"
    jq -n \
        --arg cwd "$cwd" \
        --argjson stop_active "$stop_active" \
        --arg transcript_path "$transcript_path" \
        '{"hook_event_name":"Stop","cwd":$cwd,"session_id":"testsession","stop_hook_active":$stop_active,"transcript_path":$transcript_path}'
}

# run_hook <cwd> <stop_active> <transcript_path> <claude_role> <pi_role>
# Pipes the stop JSON into the hook with the given role env vars.
run_hook() {
    local cwd="$1"
    local stop_active="${2:-false}"
    local transcript_path="${3:-}"
    local claude_role="${4:-}"
    local pi_role="${5:-}"
    make_stop_json "$cwd" "$stop_active" "$transcript_path" |
        CLAUDE_ROLE="$claude_role" PI_ROLE="$pi_role" bash "$HOOK" 2>/dev/null || true
}

# make_transcript_with_pitch_write <transcript_path> <pitch_path>
# Records a Write tool_use entry writing to pitch_path.
make_transcript_with_pitch_write() {
    local transcript_path="$1"
    local pitch_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$pitch_path" >"$transcript_path"
}

# write_well_formed_pitch <path>
# Pitch with a valid ## Questions block: Q1 with 2 options, no Answers.
write_well_formed_pitch() {
    local path="$1"
    cat >"$path" <<'MD'
# My Pitch

> Status: SHAPING

## Problem

Something.

## Questions

### Q1: Which approach?

- **a)** Option A — faster
- **b)** Option B — safer
MD
}

# write_malformed_pitch_no_q_headings <path>
# ## Questions block with NO ### Q<n>: headings.
write_malformed_pitch_no_q_headings() {
    local path="$1"
    cat >"$path" <<'MD'
# My Pitch

## Questions

Some prose but no Q headings.
MD
}

# write_malformed_pitch_one_option <path>
# Q1 exists but has only 1 option bullet.
write_malformed_pitch_one_option() {
    local path="$1"
    cat >"$path" <<'MD'
# My Pitch

## Questions

### Q1: Which approach?

- **a)** Only one option here
MD
}

# write_pitch_no_questions <path>
# Pitch with no ## Questions block at all.
write_pitch_no_questions() {
    local path="$1"
    cat >"$path" <<'MD'
# My Pitch

## Problem

Something to solve.
MD
}

# write_pitch_stray_answer <path>
# Q1 and Q2 in Questions, but Answers has Q1 and Q3 (stray).
write_pitch_stray_answer() {
    local path="$1"
    cat >"$path" <<'MD'
# My Pitch

## Questions

### Q1: First question?

- **a)** Option A
- **b)** Option B

### Q2: Second question?

- **a)** Option A
- **b)** Option B

## Answers

### Q1: a

Chose option A.

### Q3: b

Stray answer for nonexistent Q3.
MD
}

# write_pitch_orphan_answers <path>
# Only ## Answers, no ## Questions (resolved+deleted state).
write_pitch_orphan_answers() {
    local path="$1"
    cat >"$path" <<'MD'
# My Pitch

## Problem

All resolved.

## Answers

### Q1: a

Chose option A.
MD
}

# write_pitch_status_shaped <path>
write_pitch_status_shaped() {
    local path="$1"
    cat >"$path" <<'MD'
# My Pitch

> Status: SHAPED

## Problem

Done.
MD
}

# write_pitch_status_bogus <path>
write_pitch_status_bogus() {
    local path="$1"
    cat >"$path" <<'MD'
# My Pitch

> Status: INPROGRESS

## Problem

Bad status.
MD
}

# write_pitch_no_status <path>
write_pitch_no_status() {
    local path="$1"
    cat >"$path" <<'MD'
# My Pitch

## Problem

No status line.
MD
}

# write_pitch_frontmatter_status_shaped <path>
write_pitch_frontmatter_status_shaped() {
    local path="$1"
    cat >"$path" <<'MD'
---
status: SHAPED
blocks_on: []
---
# My Pitch

## Problem

Done.
MD
}

# write_pitch_waives_unknown_id <path>
# frontmatter waives: names a hook id not present in the registry at all.
write_pitch_waives_unknown_id() {
    local path="$1"
    cat >"$path" <<'MD'
---
status: SHAPED
waives: [no-such-hook]
---
# My Pitch

## Problem

Done.
MD
}

# write_pitch_waives_non_waivable_id <path>
# frontmatter waives: names a real registry id that lacks waivable: true.
write_pitch_waives_non_waivable_id() {
    local path="$1"
    cat >"$path" <<'MD'
---
status: SHAPED
waives: [session-log-writer-only]
---
# My Pitch

## Problem

Done.
MD
}

# write_pitch_waives_valid_id <path>
# frontmatter waives: names the one real waivable: true registry id.
write_pitch_waives_valid_id() {
    local path="$1"
    cat >"$path" <<'MD'
---
status: SHAPED
waives: [prompt-budget-writer-only]
---
# My Pitch

## Problem

Done.
MD
}

# write_pitch_frontmatter_status_shaped_large <path>
# Same frontmatter+status as write_pitch_frontmatter_status_shaped, but with
# a >64 KB body appended after the frontmatter closing "---". Regression
# fixture for the set -e + SIGPIPE false-141 bug: `head -n1`/`awk …exit` fed
# via a pipe from a large in-memory variable can die with 141 mid-write,
# which a bare `var=$(pipeline)` under `set -e` reads as extraction failure.
write_pitch_frontmatter_status_shaped_large() {
    local path="$1"
    {
        printf -- '---\n'
        printf -- 'status: SHAPED\n'
        printf -- 'blocks_on: []\n'
        printf -- '---\n'
        printf -- '# My Pitch\n\n## Problem\n\n'
        # ~20k lines, well past the 64 KB pipe buffer.
        for i in $(seq 1 20000); do
            printf -- 'Body filler line %d for large-pitch SIGPIPE regression test.\n' "$i"
        done
    } >"$path"
}

# write_pitch_frontmatter_status_bogus <path>
write_pitch_frontmatter_status_bogus() {
    local path="$1"
    cat >"$path" <<'MD'
---
status: INPROGRESS
blocks_on: []
---
# My Pitch

## Problem

Bad status.
MD
}

# write_pitch_frontmatter_status_bogus_large <path>
# BOGUS-status sibling of write_pitch_frontmatter_status_shaped_large.
write_pitch_frontmatter_status_bogus_large() {
    local path="$1"
    {
        printf -- '---\n'
        printf -- 'status: INPROGRESS\n'
        printf -- 'blocks_on: []\n'
        printf -- '---\n'
        printf -- '# My Pitch\n\n## Problem\n\n'
        for i in $(seq 1 20000); do
            printf -- 'Body filler line %d for large-pitch SIGPIPE regression test.\n' "$i"
        done
    } >"$path"
}

# write_pitch_frontmatter_status_shaped_valid_questions <path>
write_pitch_frontmatter_status_shaped_valid_questions() {
    local path="$1"
    cat >"$path" <<'MD'
---
status: SHAPED
blocks_on: []
---
# My Pitch

## Questions

### Q1: Which approach?

- **a)** Option A — faster
- **b)** Option B — safer
MD
}

# write_pitch_frontmatter_status_shaped_malformed_questions <path>
write_pitch_frontmatter_status_shaped_malformed_questions() {
    local path="$1"
    cat >"$path" <<'MD'
---
status: SHAPED
blocks_on: []
---
# My Pitch

## Questions

Some prose but no Q headings.
MD
}

# ── Test 1: no TRANSCRIPT_PATH → allow ──────────────────────────────────────
T1_dir=$(mktemp -d)
out=$(run_hook "$T1_dir" false "" "shape" "")
assert_not_contains "no TRANSCRIPT_PATH → allow" '"decision"' "$out"
rm -rf "$T1_dir"

# ── Test 2: shape + well-formed Questions → allow ───────────────────────────
T2_dir=$(mktemp -d)
mkdir -p "$T2_dir/codegen/pitches/draft"
T2_pitch="$T2_dir/codegen/pitches/draft/my-pitch.md"
T2_transcript="$T2_dir/transcript.jsonl"
write_well_formed_pitch "$T2_pitch"
make_transcript_with_pitch_write "$T2_transcript" "$T2_pitch"
out=$(run_hook "$T2_dir" false "$T2_transcript" "shape" "")
assert_not_contains "shape + well-formed Questions → allow" '"decision"' "$out"
rm -rf "$T2_dir"

# ── Test 3: shape + Questions with zero Q headings → block ──────────────────
T3_dir=$(mktemp -d)
mkdir -p "$T3_dir/codegen/pitches/draft"
T3_pitch="$T3_dir/codegen/pitches/draft/my-pitch.md"
T3_transcript="$T3_dir/transcript.jsonl"
write_malformed_pitch_no_q_headings "$T3_pitch"
make_transcript_with_pitch_write "$T3_transcript" "$T3_pitch"
out=$(run_hook "$T3_dir" false "$T3_transcript" "shape" "")
assert_contains "shape + Q-block with zero Q headings → block" '"decision"' "$out"
rm -rf "$T3_dir"

# ── Test 4: shape + Q1 with one option bullet → block ───────────────────────
T4_dir=$(mktemp -d)
mkdir -p "$T4_dir/codegen/pitches/draft"
T4_pitch="$T4_dir/codegen/pitches/draft/my-pitch.md"
T4_transcript="$T4_dir/transcript.jsonl"
write_malformed_pitch_one_option "$T4_pitch"
make_transcript_with_pitch_write "$T4_transcript" "$T4_pitch"
out=$(run_hook "$T4_dir" false "$T4_transcript" "shape" "")
assert_contains "shape + Q1 with one option bullet → block" '"decision"' "$out"
rm -rf "$T4_dir"

# ── Test 5: shape + no ## Questions block → allow ───────────────────────────
T5_dir=$(mktemp -d)
mkdir -p "$T5_dir/codegen/pitches/draft"
T5_pitch="$T5_dir/codegen/pitches/draft/my-pitch.md"
T5_transcript="$T5_dir/transcript.jsonl"
write_pitch_no_questions "$T5_pitch"
make_transcript_with_pitch_write "$T5_transcript" "$T5_pitch"
out=$(run_hook "$T5_dir" false "$T5_transcript" "shape" "")
assert_not_contains "shape + no ## Questions block → allow" '"decision"' "$out"
rm -rf "$T5_dir"

# ── Test 6: ops + malformed Questions (zero Q headings) → block ─────────────
T6_dir=$(mktemp -d)
mkdir -p "$T6_dir/codegen/pitches/draft"
T6_pitch="$T6_dir/codegen/pitches/draft/my-pitch.md"
T6_transcript="$T6_dir/transcript.jsonl"
write_malformed_pitch_no_q_headings "$T6_pitch"
make_transcript_with_pitch_write "$T6_transcript" "$T6_pitch"
out=$(run_hook "$T6_dir" false "$T6_transcript" "ops" "")
assert_contains "ops + malformed Questions → block" '"decision"' "$out"
rm -rf "$T6_dir"

# ── Test 7: refactor + malformed Questions (zero Q headings) → block ────────
T7_dir=$(mktemp -d)
mkdir -p "$T7_dir/codegen/pitches/draft"
T7_pitch="$T7_dir/codegen/pitches/draft/my-pitch.md"
T7_transcript="$T7_dir/transcript.jsonl"
write_malformed_pitch_no_q_headings "$T7_pitch"
make_transcript_with_pitch_write "$T7_transcript" "$T7_pitch"
out=$(run_hook "$T7_dir" false "$T7_transcript" "refactor" "")
assert_contains "refactor + malformed Questions → block" '"decision"' "$out"
rm -rf "$T7_dir"

# ── Test 8: empty role + malformed Questions → allow ────────────────────────
T8_dir=$(mktemp -d)
mkdir -p "$T8_dir/codegen/pitches/draft"
T8_pitch="$T8_dir/codegen/pitches/draft/my-pitch.md"
T8_transcript="$T8_dir/transcript.jsonl"
write_malformed_pitch_no_q_headings "$T8_pitch"
make_transcript_with_pitch_write "$T8_transcript" "$T8_pitch"
out=$(run_hook "$T8_dir" false "$T8_transcript" "" "")
assert_not_contains "empty role + malformed Questions → allow" '"decision"' "$out"
rm -rf "$T8_dir"

# ── Test 9: debug role + malformed Questions → allow ────────────────────────
T9_dir=$(mktemp -d)
mkdir -p "$T9_dir/codegen/pitches/draft"
T9_pitch="$T9_dir/codegen/pitches/draft/my-pitch.md"
T9_transcript="$T9_dir/transcript.jsonl"
write_malformed_pitch_no_q_headings "$T9_pitch"
make_transcript_with_pitch_write "$T9_transcript" "$T9_pitch"
out=$(run_hook "$T9_dir" false "$T9_transcript" "debug" "")
assert_not_contains "debug role + malformed Questions → allow" '"decision"' "$out"
rm -rf "$T9_dir"

# ── Test 10: STOP_HOOK_ACTIVE=true + malformed Questions → allow ─────────────
T10_dir=$(mktemp -d)
mkdir -p "$T10_dir/codegen/pitches/draft"
T10_pitch="$T10_dir/codegen/pitches/draft/my-pitch.md"
T10_transcript="$T10_dir/transcript.jsonl"
write_malformed_pitch_no_q_headings "$T10_pitch"
make_transcript_with_pitch_write "$T10_transcript" "$T10_pitch"
out=$(run_hook "$T10_dir" true "$T10_transcript" "shape" "")
assert_not_contains "STOP_HOOK_ACTIVE=true + malformed → allow" '"decision"' "$out"
rm -rf "$T10_dir"

# ── Test 11: stray Answers Q3 (no Q3 in Questions) → block ──────────────────
T11_dir=$(mktemp -d)
mkdir -p "$T11_dir/codegen/pitches/draft"
T11_pitch="$T11_dir/codegen/pitches/draft/my-pitch.md"
T11_transcript="$T11_dir/transcript.jsonl"
write_pitch_stray_answer "$T11_pitch"
make_transcript_with_pitch_write "$T11_transcript" "$T11_pitch"
out=$(run_hook "$T11_dir" false "$T11_transcript" "shape" "")
assert_contains "stray Answers Q3 → block" '"decision"' "$out"
rm -rf "$T11_dir"

# ── Test 12: orphan ## Answers with no ## Questions → allow ─────────────────
T12_dir=$(mktemp -d)
mkdir -p "$T12_dir/codegen/pitches/draft"
T12_pitch="$T12_dir/codegen/pitches/draft/my-pitch.md"
T12_transcript="$T12_dir/transcript.jsonl"
write_pitch_orphan_answers "$T12_pitch"
make_transcript_with_pitch_write "$T12_transcript" "$T12_pitch"
out=$(run_hook "$T12_dir" false "$T12_transcript" "shape" "")
assert_not_contains "orphan ## Answers, no ## Questions → allow" '"decision"' "$out"
rm -rf "$T12_dir"

# ── Test 13: > Status: SHAPED → allow ───────────────────────────────────────
T13_dir=$(mktemp -d)
mkdir -p "$T13_dir/codegen/pitches/draft"
T13_pitch="$T13_dir/codegen/pitches/draft/my-pitch.md"
T13_transcript="$T13_dir/transcript.jsonl"
write_pitch_status_shaped "$T13_pitch"
make_transcript_with_pitch_write "$T13_transcript" "$T13_pitch"
out=$(run_hook "$T13_dir" false "$T13_transcript" "shape" "")
assert_not_contains "> Status: SHAPED → allow" '"decision"' "$out"
rm -rf "$T13_dir"

# ── Test 14: > Status: BOGUS → block ────────────────────────────────────────
T14_dir=$(mktemp -d)
mkdir -p "$T14_dir/codegen/pitches/draft"
T14_pitch="$T14_dir/codegen/pitches/draft/my-pitch.md"
T14_transcript="$T14_dir/transcript.jsonl"
write_pitch_status_bogus "$T14_pitch"
make_transcript_with_pitch_write "$T14_transcript" "$T14_pitch"
out=$(run_hook "$T14_dir" false "$T14_transcript" "shape" "")
assert_contains "> Status: BOGUS → block" '"decision"' "$out"
rm -rf "$T14_dir"

# ── Test 15: no > Status: line → allow ──────────────────────────────────────
T15_dir=$(mktemp -d)
mkdir -p "$T15_dir/codegen/pitches/draft"
T15_pitch="$T15_dir/codegen/pitches/draft/my-pitch.md"
T15_transcript="$T15_dir/transcript.jsonl"
write_pitch_no_status "$T15_pitch"
make_transcript_with_pitch_write "$T15_transcript" "$T15_pitch"
out=$(run_hook "$T15_dir" false "$T15_transcript" "shape" "")
assert_not_contains "no > Status: line → allow" '"decision"' "$out"
rm -rf "$T15_dir"

# ── Test 16: PI_ROLE=ops + malformed Questions → block ──────────────────────
T16_dir=$(mktemp -d)
mkdir -p "$T16_dir/codegen/pitches/draft"
T16_pitch="$T16_dir/codegen/pitches/draft/my-pitch.md"
T16_transcript="$T16_dir/transcript.jsonl"
write_malformed_pitch_no_q_headings "$T16_pitch"
make_transcript_with_pitch_write "$T16_transcript" "$T16_pitch"
out=$(run_hook "$T16_dir" false "$T16_transcript" "" "ops")
assert_contains "PI_ROLE=ops + malformed Questions → block" '"decision"' "$out"
rm -rf "$T16_dir"

# ── Test 17: block reason includes "pitch-format-validator" (traceability) ───
T17_dir=$(mktemp -d)
mkdir -p "$T17_dir/codegen/pitches/draft"
T17_pitch="$T17_dir/codegen/pitches/draft/my-pitch.md"
T17_transcript="$T17_dir/transcript.jsonl"
write_malformed_pitch_no_q_headings "$T17_pitch"
make_transcript_with_pitch_write "$T17_transcript" "$T17_pitch"
out=$(run_hook "$T17_dir" false "$T17_transcript" "shape" "")
assert_contains "block reason includes pitch-format-validator (traceability)" 'pitch-format-validator' "$out"
rm -rf "$T17_dir"

# ── Test 18: frontmatter status: SHAPED → allow ─────────────────────────────
T18_dir=$(mktemp -d)
mkdir -p "$T18_dir/codegen/pitches/draft"
T18_pitch="$T18_dir/codegen/pitches/draft/my-pitch.md"
T18_transcript="$T18_dir/transcript.jsonl"
write_pitch_frontmatter_status_shaped "$T18_pitch"
make_transcript_with_pitch_write "$T18_transcript" "$T18_pitch"
out=$(run_hook "$T18_dir" false "$T18_transcript" "shape" "")
assert_not_contains "frontmatter status: SHAPED → allow" '"decision"' "$out"
rm -rf "$T18_dir"

# ── Test 19: frontmatter status: BOGUS → block ──────────────────────────────
T19_dir=$(mktemp -d)
mkdir -p "$T19_dir/codegen/pitches/draft"
T19_pitch="$T19_dir/codegen/pitches/draft/my-pitch.md"
T19_transcript="$T19_dir/transcript.jsonl"
write_pitch_frontmatter_status_bogus "$T19_pitch"
make_transcript_with_pitch_write "$T19_transcript" "$T19_pitch"
out=$(run_hook "$T19_dir" false "$T19_transcript" "shape" "")
assert_contains "frontmatter status: BOGUS → block" '"decision"' "$out"
rm -rf "$T19_dir"

# ── Test 20: frontmatter + valid Questions block → allow (frontmatter inert
# to Q/A extraction) ─────────────────────────────────────────────────────────
T20_dir=$(mktemp -d)
mkdir -p "$T20_dir/codegen/pitches/draft"
T20_pitch="$T20_dir/codegen/pitches/draft/my-pitch.md"
T20_transcript="$T20_dir/transcript.jsonl"
write_pitch_frontmatter_status_shaped_valid_questions "$T20_pitch"
make_transcript_with_pitch_write "$T20_transcript" "$T20_pitch"
out=$(run_hook "$T20_dir" false "$T20_transcript" "shape" "")
assert_not_contains "frontmatter + valid Questions → allow" '"decision"' "$out"
rm -rf "$T20_dir"

# ── Test 21: frontmatter + malformed Questions (zero Q headings) → block
# (proves Q/A validation still runs after a frontmatter block) ──────────────
T21_dir=$(mktemp -d)
mkdir -p "$T21_dir/codegen/pitches/draft"
T21_pitch="$T21_dir/codegen/pitches/draft/my-pitch.md"
T21_transcript="$T21_dir/transcript.jsonl"
write_pitch_frontmatter_status_shaped_malformed_questions "$T21_pitch"
make_transcript_with_pitch_write "$T21_transcript" "$T21_pitch"
out=$(run_hook "$T21_dir" false "$T21_transcript" "shape" "")
assert_contains "frontmatter + malformed Questions → block" '"decision"' "$out"
rm -rf "$T21_dir"

# ── Test 22: frontmatter status: SHAPED + >64 KB body → allow, no 141/SIGPIPE
# false-miss (regression for set -e + pipefail + early-exit consumer bug) ───
T22_dir=$(mktemp -d)
mkdir -p "$T22_dir/codegen/pitches/draft"
T22_pitch="$T22_dir/codegen/pitches/draft/my-pitch.md"
T22_transcript="$T22_dir/transcript.jsonl"
write_pitch_frontmatter_status_shaped_large "$T22_pitch"
make_transcript_with_pitch_write "$T22_transcript" "$T22_pitch"
out=$(run_hook "$T22_dir" false "$T22_transcript" "shape" "")
assert_not_contains "frontmatter + >64 KB body, SHAPED → allow (no 141 false-miss)" '"decision"' "$out"
rm -rf "$T22_dir"

# ── Test 23: frontmatter status: BOGUS + >64 KB body → block (status
# extraction still correct at size) ──────────────────────────────────────────
T23_dir=$(mktemp -d)
mkdir -p "$T23_dir/codegen/pitches/draft"
T23_pitch="$T23_dir/codegen/pitches/draft/my-pitch.md"
T23_transcript="$T23_dir/transcript.jsonl"
write_pitch_frontmatter_status_bogus_large "$T23_pitch"
make_transcript_with_pitch_write "$T23_transcript" "$T23_pitch"
out=$(run_hook "$T23_dir" false "$T23_transcript" "shape" "")
assert_contains "frontmatter + >64 KB body, BOGUS → block" '"decision"' "$out"
rm -rf "$T23_dir"

# ── Test 24: waives: [no-such-hook] → block (unknown registry id) ──────────
T24_dir=$(mktemp -d)
mkdir -p "$T24_dir/codegen/pitches/draft"
T24_pitch="$T24_dir/codegen/pitches/draft/my-pitch.md"
T24_transcript="$T24_dir/transcript.jsonl"
write_pitch_waives_unknown_id "$T24_pitch"
make_transcript_with_pitch_write "$T24_transcript" "$T24_pitch"
out=$(run_hook "$T24_dir" false "$T24_transcript" "shape" "")
assert_contains "waives: [no-such-hook] → block" '"decision"' "$out"
rm -rf "$T24_dir"

# ── Test 25: waives: [session-log-writer-only] → block (real id, not
# waivable: true) ────────────────────────────────────────────────────────
T25_dir=$(mktemp -d)
mkdir -p "$T25_dir/codegen/pitches/draft"
T25_pitch="$T25_dir/codegen/pitches/draft/my-pitch.md"
T25_transcript="$T25_dir/transcript.jsonl"
write_pitch_waives_non_waivable_id "$T25_pitch"
make_transcript_with_pitch_write "$T25_transcript" "$T25_pitch"
out=$(run_hook "$T25_dir" false "$T25_transcript" "shape" "")
assert_contains "waives: [session-log-writer-only] → block (not waivable)" '"decision"' "$out"
rm -rf "$T25_dir"

# ── Test 26: waives: [prompt-budget-writer-only] → allow (real id,
# waivable: true) ────────────────────────────────────────────────────────
T26_dir=$(mktemp -d)
mkdir -p "$T26_dir/codegen/pitches/draft"
T26_pitch="$T26_dir/codegen/pitches/draft/my-pitch.md"
T26_transcript="$T26_dir/transcript.jsonl"
write_pitch_waives_valid_id "$T26_pitch"
make_transcript_with_pitch_write "$T26_transcript" "$T26_pitch"
out=$(run_hook "$T26_dir" false "$T26_transcript" "shape" "")
assert_not_contains "waives: [prompt-budget-writer-only] → allow" '"decision"' "$out"
rm -rf "$T26_dir"

# ── Test 27: no waives: line at all → allow (absent = none) ────────────────
T27_dir=$(mktemp -d)
mkdir -p "$T27_dir/codegen/pitches/draft"
T27_pitch="$T27_dir/codegen/pitches/draft/my-pitch.md"
T27_transcript="$T27_dir/transcript.jsonl"
write_pitch_frontmatter_status_shaped "$T27_pitch"
make_transcript_with_pitch_write "$T27_transcript" "$T27_pitch"
out=$(run_hook "$T27_dir" false "$T27_transcript" "shape" "")
assert_not_contains "no waives: line → allow" '"decision"' "$out"
rm -rf "$T27_dir"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
