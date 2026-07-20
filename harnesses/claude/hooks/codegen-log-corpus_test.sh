#!/bin/bash
# codegen-log-corpus_test.sh — unit tests for `codegen-log corpus publish` /
# `codegen-log corpus sync` (pitch "the learning corpus survives the clone").
#
# Every fixture builds its OWN bare "origin" + work clone(s) under mktemp -d
# (canonicalized via `pwd -P` so macOS /var vs /private/var symlinks never
# break a path assertion). The real codegen repo's own origin is NEVER
# touched — repo_root() resolves from CODEGEN_BUILD_CWD/PWD, so every
# invocation below is scoped to its own sandbox clone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_CODEGEN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CODEGEN_LOG_SRC="$REAL_CODEGEN_ROOT/codegen-log"

pass=0
fail=0

TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

# make_repo_pair <name> — builds a bare "origin" at $TMP_ROOT/<name>-origin.git
# and a clone at $TMP_ROOT/<name>, with shared/enforcement/registry.yaml (the
# codegen-only sentinel) and codegen/logging/ present, committed via raw
# plumbing (hash-object/update-index/write-tree/commit-tree) rather than the
# porcelain staging command — matches the "publish never opens the repo's
# own index" contract this script tests.
make_repo_pair() {
    local name="$1"
    local origin="$TMP_ROOT/${name}-origin.git"
    local work="$TMP_ROOT/${name}"
    git init --quiet --bare "$origin"
    git init --quiet "$work"
    (
        cd "$work"
        git config user.email test@test.com
        git config user.name test
        git remote add origin "$origin"
        mkdir -p shared/enforcement codegen/logging
        : >shared/enforcement/registry.yaml
        echo hi >README.md
        blob1=$(git hash-object -w README.md)
        blob2=$(git hash-object -w shared/enforcement/registry.yaml)
        idx=$(mktemp -u)
        printf '100644 %s\t%s\n100644 %s\t%s\n' "$blob1" README.md "$blob2" shared/enforcement/registry.yaml |
            GIT_INDEX_FILE="$idx" git update-index --index-info
        tree=$(GIT_INDEX_FILE="$idx" git write-tree)
        rm -f "$idx"
        commit=$(echo init | git commit-tree "$tree")
        git update-ref refs/heads/main "$commit"
        git symbolic-ref HEAD refs/heads/main
        git push --quiet origin refs/heads/main:refs/heads/main
    )
    printf '%s' "$work"
}

# write_scratch_log <basename> <content> — writes a fixture cycle-log-shaped
# file OUTSIDE codegen/logging/ (session-log-writer-only denies raw writes
# under that path for every role) so it can be pointed at via
# CODEGEN_LOG_PATH without the guard ever seeing a codegen/logging/ write.
write_scratch_log() {
    local basename="$1" content="$2"
    local dir="$TMP_ROOT/scratch-logs"
    mkdir -p "$dir"
    printf '%s\n' "$content" >"$dir/$basename"
    printf '%s/%s' "$dir" "$basename"
}

publish() {
    local work="$1"
    shift
    (cd "$work" && env -u CLAUDE_PROJECT_DIR CODEGEN_BUILD_CWD="$work" "$@" "$CODEGEN_LOG_SRC" corpus publish)
}

sync_corpus() {
    local work="$1"
    (cd "$work" && env -u CLAUDE_PROJECT_DIR -u CODEGEN_LOG_PATH CODEGEN_BUILD_CWD="$work" "$CODEGEN_LOG_SRC" corpus sync)
}

# ── Test 1: no registry.yaml sentinel → both verbs no-op (exit 0, no ref) ──
NOREG="$TMP_ROOT/noreg"
mkdir -p "$NOREG"
git init --quiet "$NOREG"
log1=$(write_scratch_log "20260101_000000_no-sentinel_cycle.jsonl" '{"ev":"init"}')
rc=0
(cd "$NOREG" && env -u CLAUDE_PROJECT_DIR CODEGEN_BUILD_CWD="$NOREG" CODEGEN_LOG_PATH="$log1" "$CODEGEN_LOG_SRC" corpus publish) || rc=$?
assert "publish with no registry.yaml sentinel exits 0 (no-op)" "0" "$rc"
rc=0
(cd "$NOREG" && env -u CLAUDE_PROJECT_DIR -u CODEGEN_LOG_PATH CODEGEN_BUILD_CWD="$NOREG" "$CODEGEN_LOG_SRC" corpus sync) || rc=$?
assert "sync with no registry.yaml sentinel exits 0 (no-op)" "0" "$rc"
assert "sync with no sentinel created no codegen/ dir" "0" "$([ -d "$NOREG/codegen" ] && echo 1 || echo 0)"

# ── Test 2: publish without CODEGEN_LOG_PATH → exit 2 ──────────────────────
WORK1="$(make_repo_pair box1)"
rc=0
(cd "$WORK1" && env -u CLAUDE_PROJECT_DIR -u CODEGEN_LOG_PATH CODEGEN_BUILD_CWD="$WORK1" "$CODEGEN_LOG_SRC" corpus publish) || rc=$?
assert "publish without CODEGEN_LOG_PATH exits 2" "2" "$rc"

# ── Test 3: publish on a path failing the canonical regex → exit 2 ─────────
bad_log=$(write_scratch_log "bad_shape.jsonl" '{"ev":"init"}')
rc=0
(cd "$WORK1" && env -u CLAUDE_PROJECT_DIR CODEGEN_BUILD_CWD="$WORK1" CODEGEN_LOG_PATH="$bad_log" "$CODEGEN_LOG_SRC" corpus publish) || rc=$?
assert "publish on non-canonical filename exits 2" "2" "$rc"

# ── Test 4: publish leaves git status --porcelain byte-identical against a
# deliberately dirty tree (the load-bearing safety assertion) ──────────────
log_a=$(write_scratch_log "20260715_230435_close-the-learning-loop_cycle.jsonl" '{"ev":"init","pitch":"x"}')
echo dirty >>"$WORK1/README.md"
before="$(git -C "$WORK1" status --porcelain)"
(cd "$WORK1" && env -u CLAUDE_PROJECT_DIR CODEGEN_BUILD_CWD="$WORK1" CODEGEN_LOG_PATH="$log_a" "$CODEGEN_LOG_SRC" corpus publish) >/dev/null
after="$(git -C "$WORK1" status --porcelain)"
assert "publish leaves git status --porcelain byte-identical against a dirty tree" "$before" "$after"

# ── Test 5: first publish creates refs/heads/corpus on origin with exactly
# the one log ────────────────────────────────────────────────────────────
git -C "$WORK1" fetch --quiet origin '+refs/heads/corpus:refs/heads/corpus'
tree_count="$(git -C "$WORK1" ls-tree --name-only refs/heads/corpus | grep -c . || true)"
assert "first publish: exactly one log on refs/heads/corpus" "1" "$tree_count"
assert "first publish: the one log is the published basename" "20260715_230435_close-the-learning-loop_cycle.jsonl" \
    "$(git -C "$WORK1" ls-tree --name-only refs/heads/corpus)"

# ── Test 6: second box publishes without ever fetching first (concurrency);
# publish self-heals (fetch+replay), and a fresh clone shows BOTH logs ─────
WORK2="$TMP_ROOT/box2"
git clone --quiet "$TMP_ROOT/box1-origin.git" "$WORK2"
git -C "$WORK2" config user.email test2@test.com
git -C "$WORK2" config user.name test2
mkdir -p "$WORK2/codegen/logging"
log_b=$(write_scratch_log "20260716_010101_second-box-slug_cycle.jsonl" '{"ev":"init","pitch":"y"}')
(cd "$WORK2" && env -u CLAUDE_PROJECT_DIR CODEGEN_BUILD_CWD="$WORK2" CODEGEN_LOG_PATH="$log_b" "$CODEGEN_LOG_SRC" corpus publish) >/dev/null

FRESH="$TMP_ROOT/fresh-clone"
git clone --quiet "$TMP_ROOT/box1-origin.git" "$FRESH"
git -C "$FRESH" fetch --quiet origin '+refs/heads/corpus:refs/heads/corpus'
fresh_count="$(git -C "$FRESH" ls-tree --name-only refs/heads/corpus | grep -c . || true)"
assert "a fresh clone sees both boxes' logs after concurrent publish" "2" "$fresh_count"

# ── Test 7: sync into an empty codegen/logging/ materializes both canonical
# logs; a hostile branch entry is NOT materialized ─────────────────────────
# Push a hostile non-canonical entry directly onto the branch.
(
    cd "$WORK1"
    git fetch --quiet origin '+refs/heads/corpus:refs/heads/corpus'
    idx=$(mktemp -u)
    parent=$(git rev-parse refs/heads/corpus)
    GIT_INDEX_FILE="$idx" git read-tree "$parent"
    blob=$(echo evil | git hash-object -w --stdin)
    printf '100644 %s\t%s\n' "$blob" evil.txt | GIT_INDEX_FILE="$idx" git update-index --index-info
    tree=$(GIT_INDEX_FILE="$idx" git write-tree)
    rm -f "$idx"
    commit=$(echo hostile | git commit-tree "$tree" -p "$parent")
    git update-ref refs/heads/corpus "$commit"
    git push --quiet origin refs/heads/corpus:refs/heads/corpus
)

SYNCWORK="$TMP_ROOT/syncwork"
git clone --quiet "$TMP_ROOT/box1-origin.git" "$SYNCWORK"
mkdir -p "$SYNCWORK/codegen/logging"
sync_corpus "$SYNCWORK" >/dev/null
assert "sync materializes both canonical logs" "2" "$(find "$SYNCWORK/codegen/logging" -name '*_cycle.jsonl' | grep -c . || true)"
assert "sync does NOT materialize the hostile evil.txt entry" "0" "$([ -f "$SYNCWORK/codegen/logging/evil.txt" ] && echo 1 || echo 0)"

# ── Test 8: sync stamps mtime from the filename, not "now" ─────────────────
mtime_epoch="$(stat -c '%Y' "$SYNCWORK/codegen/logging/20260715_230435_close-the-learning-loop_cycle.jsonl" 2>/dev/null \
    || stat -f '%m' "$SYNCWORK/codegen/logging/20260715_230435_close-the-learning-loop_cycle.jsonl" 2>/dev/null)"
expected_epoch="$(date -d '2026-07-15 23:04:35' +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' '2026-07-15 23:04:35' +%s 2>/dev/null)"
assert "synced log's mtime matches its filename stamp, not now" "$expected_epoch" "$mtime_epoch"

# ── Test 9: sync run twice is idempotent — no duplicate, no re-stamp churn,
# second run emits nothing new to sync ─────────────────────────────────────
before_ls="$(find "$SYNCWORK/codegen/logging" -name '*_cycle.jsonl' | sort)"
sync_out="$(sync_corpus "$SYNCWORK")"
after_ls="$(find "$SYNCWORK/codegen/logging" -name '*_cycle.jsonl' | sort)"
assert "second sync run: file set unchanged (idempotent)" "$before_ls" "$after_ls"
assert "second sync run: no 'synced N log(s)' output (nothing new)" "" "$sync_out"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
