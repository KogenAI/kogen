#!/usr/bin/env bash
# build-queue.sh — drain codegen/pitches/ready/ one pitch per fresh isolated
# codegen-build --non-interactive child (zero cross-pitch context accumulation).
# Usage: build-queue.sh --harness=<claude|pi> [--stack=<S>]
# Filesystem IS the state: re-scan ready/ each iteration (refillable + resumable).
# Success = child exit 0 AND shipped/<slug>.md present AND ready/<slug>.md gone.
# Non-ship outcome: retry SAME slug if transient (transport fault / interrupted /
# crashed-no-result) up to CODEGEN_BUILD_QUEUE_MAX_RETRIES (default 3) with
# CODEGEN_BUILD_QUEUE_RETRY_DELAYS backoff (default "30 120 300" sec); otherwise
# halt (echo child result + exit 1), leaving the rest in ready/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODEGEN_DIR="${OCG_CODEGEN_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
BUILD_BIN="$CODEGEN_DIR/codegen-build"

# Transient-error taxonomy (retryable_regex, hard_fail_regex) — single source of
# truth shared with stop-resume.sh + dispatch retry loops.
# shellcheck source=harnesses/shared/retryable-errors.sh
if [ -r "$SCRIPT_DIR/retryable-errors.sh" ]; then
    source "$SCRIPT_DIR/retryable-errors.sh"
fi

# Operator toggles (build-time; NOT app runtime — do not add to .env samples):
#   CODEGEN_BUILD_QUEUE_MAX_RETRIES   max consecutive transient retries per slug (default 3)
#   CODEGEN_BUILD_QUEUE_RETRY_DELAYS  space-separated backoff seconds per attempt (default "30 120 300")
MAX_RETRIES="${CODEGEN_BUILD_QUEUE_MAX_RETRIES:-3}"
RETRY_DELAYS="${CODEGEN_BUILD_QUEUE_RETRY_DELAYS:-30 120 300}"

HARNESS=""
STACK="${STACK:-phoenix}"
for _arg in "$@"; do
    case "$_arg" in
    --harness=*) HARNESS="${_arg#--harness=}" ;;
    --stack=*) STACK="${_arg#--stack=}" ;;
    *)
        printf 'build-queue: unknown argument: %s\n' "$_arg" >&2
        exit 2
        ;;
    esac
done
if [ -z "$HARNESS" ]; then
    printf 'build-queue: --harness=<claude|pi> required\n' >&2
    exit 2
fi

case "$HARNESS" in
claude) MENTION_PREFIX="@" ;;
pi) MENTION_PREFIX="" ;;
*)
    printf 'build-queue: unknown harness: %s\n' "$HARNESS" >&2
    exit 2
    ;;
esac

READY_DIR="$PWD/codegen/pitches/ready"
SHIPPED_DIR="$PWD/codegen/pitches/shipped"
LOG_DIR="$PWD/codegen/logging"
mkdir -p "$SHIPPED_DIR" "$LOG_DIR"

# --- parse_edges: extract dependency edges from a pitch file ---
# Emits "SLUG DEP" lines where SLUG depends on (blocks on) DEP.
# i.e., DEP must be built before SLUG.
parse_edges() {
    local slug="$1" file="$2"
    local in_deps=0
    while IFS= read -r line; do
        case "$line" in
        'Blocks-on:'*)
            local dep="${line#Blocks-on:}"
            dep="${dep%%,*}"
            dep="${dep%%)*}"
            dep="${dep// /}"
            dep="${dep##* }"
            [ -n "$dep" ] && printf '%s %s\n' "$slug" "$dep"
            ;;
        '## Dependencies'*)
            in_deps=1
            ;;
        '## '*)
            in_deps=0
            ;;
        *)
            if [ "$in_deps" = "1" ]; then
                case "$line" in
                '- '*)
                    local dep="${line#- }"
                    dep="${dep%% *}"
                    dep="${dep%%(*}"
                    [ -n "$dep" ] && printf '%s %s\n' "$slug" "$dep"
                    ;;
                esac
            fi
            ;;
        esac
    done <"$file"
}

# --- topo_sort: Kahn's algorithm over newline-delimited strings ---
# Args: $1=newline-delimited slugs, $2=newline-delimited "SLUG DEP" edges
# Emits topo-ordered slugs to stdout (deps first).
# Exits 3 on cycle.
topo_sort() {
    local slugs="$1" edges="$2"
    local ordered="" remaining="$slugs"
    local changed=1
    while [ -n "$remaining" ] && [ "$changed" = "1" ]; do
        changed=0
        local next_remaining=""
        while IFS= read -r slug; do
            [ -z "$slug" ] && continue
            local blocked=0
            if [ -n "$edges" ]; then
                while IFS= read -r edge; do
                    [ -z "$edge" ] && continue
                    local before after
                    before="${edge%% *}"
                    after="${edge#* }"
                    # slug is blocked if some 'before' (dep) is still in remaining
                    if [ "$before" = "$slug" ] && printf '%s\n' "$remaining" | grep -qxF "$after"; then
                        blocked=1
                        break
                    fi
                done <<EDGES
$edges
EDGES
            fi
            if [ "$blocked" = "0" ]; then
                ordered="${ordered:+$ordered
}$slug"
                changed=1
            else
                next_remaining="${next_remaining:+$next_remaining
}$slug"
            fi
        done <<SLUGS
$remaining
SLUGS
        remaining="$next_remaining"
    done
    if [ -n "$remaining" ]; then
        printf 'build-queue: cyclic dependency among: %s\n' \
            "$(printf '%s\n' "$remaining" | tr '\n' ' ')" >&2
        exit 3
    fi
    printf '%s\n' "$ordered"
}

# --- is_transient: classify a child's tee'd JSONL as a retryable infra blip ---
# Args: $1=jsonl_file. Returns 0 (transient) iff:
#   (a) a line matches retryable_regex (transport faults: socket closed, 5xx, etc.)
#   (b) OR (claude only) the literal "Request interrupted by user for tool use" appears
#   (c) OR there is NO type:result record (child crashed/killed mid-flight)
# Returns 1 (deterministic failure) otherwise.
is_transient() {
    local jsonl="$1"
    [ -r "$jsonl" ] || return 0 # missing capture == crashed == transient
    if [ -n "${retryable_regex:-}" ] && grep -qE "$retryable_regex" "$jsonl"; then
        return 0
    fi
    if [ "$HARNESS" = "claude" ] &&
        grep -qF 'Request interrupted by user for tool use' "$jsonl"; then
        return 0
    fi
    if ! grep -q '"type":"result"' "$jsonl"; then
        return 0
    fi
    return 1
}

# --- is_gate_green: gate passed but build never shipped (commit pending) ---
# Args: $1=slug, $2=start_ts (YYYYMMDD_HHMMSS captured before child spawned).
# Returns 0 iff the NEWEST per-slug session log whose filename ts >= start_ts
# contains "ALL CLEAR" (gate-green marker). Returns 1 otherwise.
is_gate_green() {
    local slug="$1" start_ts="$2"
    local newest="" newest_ts="" f base fts
    for f in "$LOG_DIR"/*_"${slug}"_session.md; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        fts="${base%%_"${slug}"_session.md}" # leading YYYYMMDD_HHMMSS
        # keep only logs written during/after this child's start
        [ "$fts" \< "$start_ts" ] && continue
        if [ -z "$newest_ts" ] || [ "$fts" \> "$newest_ts" ]; then
            newest_ts="$fts"
            newest="$f"
        fi
    done
    [ -n "$newest" ] || return 1
    grep -qF 'ALL CLEAR' "$newest"
}

# --- pick_delay: backoff seconds for attempt N (1-based); cap at last element ---
pick_delay() {
    local attempt="$1" i=1 chosen=0
    for d in $RETRY_DELAYS; do
        chosen="$d"
        [ "$i" -ge "$attempt" ] && break
        i=$((i + 1))
    done
    printf '%s' "$chosen"
}

# --- main loop ---
TOTAL=0
SHIPPED_COUNT=0
last_slug=""
retry_count=0
# Slugs timed out in this run — left in ready/ but skipped for remaining iterations.
TIMED_OUT_SLUGS=""

while true; do
    # Re-scan ready/ each iteration (refillable + resumable)
    slugs=""
    for f in "$READY_DIR"/*.md; do
        [ -f "$f" ] || continue
        slug="$(basename "$f" .md)"
        # Skip slugs that timed out earlier in this run.
        if [ -n "$TIMED_OUT_SLUGS" ] && printf '%s\n' "$TIMED_OUT_SLUGS" | grep -qxF "$slug"; then
            continue
        fi
        slugs="${slugs:+$slugs
}$slug"
    done

    if [ -z "$slugs" ]; then
        if [ "$TOTAL" = "0" ]; then
            printf 'build-queue: no ready pitches in %s\n' "$READY_DIR"
            exit 0
        fi
        printf 'build-queue: %d shipped\n' "$SHIPPED_COUNT"
        exit 0
    fi

    # Set total on first scan only (display; may understate after refill)
    if [ "$TOTAL" = "0" ]; then
        TOTAL="$(printf '%s\n' "$slugs" | grep -c '.')"
    fi

    # Build edge list from pitch files
    edges=""
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        pitchedges="$(parse_edges "$slug" "$READY_DIR/$slug.md" 2>/dev/null || true)"
        # Only keep edges where the dependency is also in current ready/
        if [ -n "$pitchedges" ]; then
            while IFS= read -r edge; do
                [ -z "$edge" ] && continue
                dep="${edge#* }"
                if printf '%s\n' "$slugs" | grep -qxF "$dep"; then
                    edges="${edges:+$edges
}$edge"
                fi
            done <<PITCHEDGES
$pitchedges
PITCHEDGES
        fi
    done <<SLUGS
$slugs
SLUGS

    # Topo-sort (lexical within same in-degree level via pre-sort)
    sorted_slugs="$(printf '%s\n' "$slugs" | sort)"
    ordered="$(topo_sort "$sorted_slugs" "$edges")"

    # Take first slug from ordered list
    slug="$(printf '%s\n' "$ordered" | grep -v '^$' | head -1)"
    idx=$((SHIPPED_COUNT + 1))

    printf '[%d/%d] %s ... building\n' "$idx" "$TOTAL" "$slug"

    ts="$(date -u +%Y%m%d_%H%M%S)"
    head_before="$(git rev-parse HEAD 2>/dev/null || true)"
    JSONL="$LOG_DIR/${ts}_${slug}_build.jsonl"

    # Per-pitch wall-clock budget (default 1800s; sentinel 124 = GNU timeout convention).
    budget="${CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS:-1800}"
    case "$budget" in
    '' | *[!0-9]* | 0) budget=1800 ;;
    esac

    TIMED_OUT=0
    set +e

    # Run child in its own process group so the watchdog can kill the whole
    # tree (child + any grandchildren it spawns). set -m enables job control
    # which gives the child PGID == child PID; set +m restores immediately.
    child_out_tmp="$(mktemp)"
    set -m
    "$BUILD_BIN" --harness="$HARNESS" --non-interactive --stack="$STACK" \
        -- "${MENTION_PREFIX}codegen/pitches/ready/${slug}.md" >"$child_out_tmp" 2>&1 &
    child_pid=$!
    set +m

    # Watchdog: fires after budget; leaves sentinel file so we can detect it.
    # Kills the WHOLE process group (child_pid == PGID when set -m is used).
    # Sentinel written BEFORE the kill-9 grace sleep so the parent can detect
    # the timeout even if the watchdog itself is killed during the grace period.
    #
    # CRITICAL: redirect the watchdog's own stdout+stderr to /dev/null. When the
    # queue runs inside command-substitution `$( ... 2>&1)` (as the test gate and
    # any captured invocation do), a backgrounded subshell INHERITS the capture
    # pipe on fd 1 and 2. Its `sleep "$budget"` would then hold that pipe open,
    # so `$(...)` cannot return until the sleep ends — blocking the caller for the
    # full budget (default 1800s) even after the child finished instantly. The
    # watchdog only ever writes to the sentinel FILE, never stdout/stderr, so
    # detaching its std streams is safe and is what unblocks the capture.
    (
        sleep "$budget"
        if kill -0 "$child_pid" 2>/dev/null; then
            printf 'WATCHDOG_FIRED\n' >"${child_out_tmp}.watchdog"
            kill -- -"$child_pid" 2>/dev/null || true
            sleep 2
            kill -9 -- -"$child_pid" 2>/dev/null || true
        fi
    ) </dev/null >/dev/null 2>&1 &
    watchdog_pid=$!

    wait "$child_pid"
    child_rc=$?
    # Cancel watchdog since child finished (or was killed by it). Reap the
    # `sleep` grandchild FIRST (while the subshell is still its parent) so it is
    # not orphaned to init and left lingering for the rest of the budget.
    pkill -P "$watchdog_pid" 2>/dev/null || true
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    # Stream output through tee so JSONL is populated.
    tee "$JSONL" <"$child_out_tmp"
    rm -f "$child_out_tmp"
    set -e

    # Check if watchdog fired — sentinel file present means timeout.
    if [ -f "${child_out_tmp}.watchdog" ]; then
        rm -f "${child_out_tmp}.watchdog"
        TIMED_OUT=1
    fi

    # Timeout: leave slug in ready/, skip for remainder of this run.
    if [ "$TIMED_OUT" = "1" ]; then
        printf '[%d/%d] %s ... TIMED OUT (budget %ss) — left in ready/, advancing\n' \
            "$idx" "$TOTAL" "$slug" "$budget" >&2
        TIMED_OUT_SLUGS="${TIMED_OUT_SLUGS:+$TIMED_OUT_SLUGS
}$slug"
        retry_count=0
        last_slug=""
        continue
    fi

    if [ "$child_rc" = "0" ] && [ -f "$SHIPPED_DIR/$slug.md" ] && [ ! -f "$READY_DIR/$slug.md" ]; then
        SHIPPED_COUNT=$((SHIPPED_COUNT + 1))
        printf '[%d/%d] %s ... shipped\n' "$idx" "$TOTAL" "$slug"
    else
        # Reset per-slug retry counter when the slug changes.
        if [ "$slug" != "$last_slug" ]; then
            retry_count=0
            last_slug="$slug"
        fi

        gate_green=0
        if is_gate_green "$slug" "$ts"; then gate_green=1; fi

        # Gate passed and child already committed (HEAD moved) but did not ship:
        # complete the ship here without re-spawning.
        head_now="$(git rev-parse HEAD 2>/dev/null || true)"
        if [ "$gate_green" = "1" ] && [ -n "$head_before" ] && [ "$head_now" != "$head_before" ] && [ ! -f "$SHIPPED_DIR/$slug.md" ]; then
            mv "$READY_DIR/$slug.md" "$SHIPPED_DIR/$slug.md"
            SHIPPED_COUNT=$((SHIPPED_COUNT + 1))
            printf '[%d/%d] %s ... gate green, already committed — shipping\n' "$idx" "$TOTAL" "$slug"
            continue
        fi

        if { is_transient "$JSONL" || [ "$gate_green" = "1" ]; } && [ "$retry_count" -lt "$MAX_RETRIES" ]; then
            retry_count=$((retry_count + 1))
            delay="$(pick_delay "$retry_count")"
            if [ "$gate_green" = "1" ]; then
                printf '[%d/%d] %s ... gate green, commit pending — retry %d/%d after %ss\n' \
                    "$idx" "$TOTAL" "$slug" "$retry_count" "$MAX_RETRIES" "$delay" >&2
            else
                printf '[%d/%d] %s ... infra blip (transient) — retry %d/%d after %ss\n' \
                    "$idx" "$TOTAL" "$slug" "$retry_count" "$MAX_RETRIES" "$delay" >&2
            fi
            if [ "$delay" -gt 0 ]; then
                sleep "$delay"
            fi
            continue # re-scan ready/ → same slug re-runs in a fresh child
        fi

        # Deterministic failure OR retries exhausted: surface child's final result.
        result_text="$(jq -r 'select(.type=="result") | .result // empty' "$JSONL" 2>/dev/null | tail -1)"
        session_id="$(jq -r 'select(.type=="result") | .session_id // empty' "$JSONL" 2>/dev/null | tail -1)"
        [ -n "$result_text" ] && printf '%s\n' "$result_text" >&2
        [ -n "$session_id" ] && printf 'session_id: %s\n' "$session_id" >&2
        printf '[%d/%d] %s ... FAILED (exit %s)\n' "$idx" "$TOTAL" "$slug" "$child_rc" >&2
        exit 1
    fi
done
