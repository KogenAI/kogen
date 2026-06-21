#!/usr/bin/env bash
# build-queue.sh — drain codegen/pitches/ready/ one pitch per fresh isolated
# codegen-build --non-interactive child (zero cross-pitch context accumulation).
# Usage: build-queue.sh --harness=<claude|pi> [--stack=<S>]
# Filesystem IS the state: re-scan ready/ each iteration (refillable + resumable).
# Success = child exit 0 AND shipped/<slug>.md present AND ready/<slug>.md gone.
# Halt on first failure; leave the rest in ready/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODEGEN_DIR="${OCG_CODEGEN_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
BUILD_BIN="$CODEGEN_DIR/codegen-build"

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

# --- main loop ---
TOTAL=0
SHIPPED_COUNT=0

while true; do
    # Re-scan ready/ each iteration (refillable + resumable)
    slugs=""
    for f in "$READY_DIR"/*.md; do
        [ -f "$f" ] || continue
        slug="$(basename "$f" .md)"
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
    JSONL="$LOG_DIR/${ts}_${slug}_build.jsonl"

    # Spawn child; capture exit code through tee pipeline
    set +e
    "$BUILD_BIN" --harness="$HARNESS" --non-interactive --stack="$STACK" \
        -- "${MENTION_PREFIX}codegen/pitches/ready/${slug}.md" 2>&1 | tee "$JSONL"
    child_rc="${PIPESTATUS[0]}"
    set -e

    if [ "$child_rc" = "0" ] && [ -f "$SHIPPED_DIR/$slug.md" ] && [ ! -f "$READY_DIR/$slug.md" ]; then
        SHIPPED_COUNT=$((SHIPPED_COUNT + 1))
        printf '[%d/%d] %s ... shipped\n' "$idx" "$TOTAL" "$slug"
    else
        printf '[%d/%d] %s ... FAILED (exit %s)\n' "$idx" "$TOTAL" "$slug" "$child_rc" >&2
        exit 1
    fi
done
