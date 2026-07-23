#!/usr/bin/env bash
# build-ready-currency.sh — single source of truth for the "installed harness
# is current with the working tree" check used by both `install.sh` (writer)
# and `make build-ready` (reader). Sourced, not executed directly.
#
# Source-set: the files `make install` actually consumes to produce the
# installed harness. Keep this list textually identical wherever it appears —
# it is defined ONCE here specifically to avoid drift between the writer and
# the reader (see codegen/pitches/ready/... "build-ready" — Files to touch).
#
# The four claude-*/pi-* launcher entries are COPIED into the installed
# harness by `make install`; the pitch-context-selector.sh, ssh-target.sh, and
# worktree-lifecycle.sh entries are instead SOURCED LIVE through the installed
# harness symlink at launcher runtime — all sides must invalidate a same-HEAD
# stamp, so all are in this set.
set -uo pipefail

_BUILD_READY_SOURCE_SET="shared/rules shared/subagents harnesses/claude/manifest.yaml harnesses/pi/manifest.yaml harnesses/claude/hooks templates/generator harnesses/claude/claude-shape.sh harnesses/claude/claude-experiment.sh harnesses/pi/pi-shape.sh harnesses/pi/pi-experiment.sh harnesses/pi/pi-ops.sh harnesses/pi/pi-debug.sh harnesses/shared/pitch-context-selector.sh harnesses/shared/ssh-target.sh harnesses/shared/worktree-lifecycle.sh harnesses/shared/pitch-postflight.sh harnesses/shared/pitch-postflight.cjs shared/enforcement/registry.yaml harnesses/claude/claude-build.sh harnesses/pi/pi-build.sh harnesses/claude/dispatch.sh harnesses/pi/dispatch.sh harnesses/shared/loop-signal-bridge.sh"

# build_ready_content_hash <codegen_dir>
# Prints a stable hash over the CURRENT WORKING-TREE bytes of the source set
# (not the committed HEAD tree — an edited-but-uncommitted source must count
# as stale). Uses only `git` (already a hard doctor dependency) — no sha256sum
# / shasum binary, which differs macOS vs Linux. See build_ready_content_hash
# for the deleted-but-unstaged-path exclusion this relies on.
build_ready_content_hash() {
    # Excludes deleted-but-unstaged paths from the hash — git ls-files lists
    # the index (tracked set), which still includes a file removed from disk
    # but not yet `git add`ed for the deletion; hash-object would otherwise
    # error trying to read a path that no longer exists.
    local codegen_dir="$1"
    comm -23 \
        <(git -C "$codegen_dir" ls-files -- $_BUILD_READY_SOURCE_SET | sort) \
        <(git -C "$codegen_dir" ls-files --deleted -- $_BUILD_READY_SOURCE_SET | sort) |
        git -C "$codegen_dir" hash-object --stdin-paths |
        git hash-object --stdin
}

# build_ready_write_stamp <codegen_dir> <stamp_path>
# Writes sha=<HEAD>/hash=<content-hash> lines to stamp_path. Fail-open (skips,
# stderr note) when codegen_dir is not a git repo — stamp absence is read as
# stale later, which is the correct fail-closed default, not a swallow.
build_ready_write_stamp() {
    local codegen_dir="$1"
    local stamp_path="$2"

    if ! git -C "$codegen_dir" rev-parse HEAD >/dev/null 2>&1; then
        echo "build-ready: $codegen_dir is not a git repo — skipping install stamp" >&2
        return 0
    fi

    local head hash
    head=$(git -C "$codegen_dir" rev-parse HEAD)
    hash=$(build_ready_content_hash "$codegen_dir")

    {
        printf 'sha=%s\n' "$head"
        printf 'hash=%s\n' "$hash"
    } >"$stamp_path"
}

# check_install_currency <codegen_dir> <stamp_path>
# Echoes an OK/FAIL line and returns 0 (current) or 1 (stale/absent/mismatch).
check_install_currency() {
    local codegen_dir="$1"
    local stamp_path="$2"

    if [ ! -f "$stamp_path" ]; then
        echo "FAIL: install stamp absent at $stamp_path (run 'make install' in codegen)"
        return 1
    fi

    if ! git -C "$codegen_dir" rev-parse HEAD >/dev/null 2>&1; then
        echo "FAIL: $codegen_dir is not a git repo — cannot verify install currency"
        return 1
    fi

    local stamped_sha stamped_hash current_sha current_hash
    stamped_sha=$(grep '^sha=' "$stamp_path" | cut -d= -f2- || true)
    stamped_hash=$(grep '^hash=' "$stamp_path" | cut -d= -f2- || true)
    current_sha=$(git -C "$codegen_dir" rev-parse HEAD)
    current_hash=$(build_ready_content_hash "$codegen_dir")

    if [ -z "$stamped_sha" ] || [ -z "$stamped_hash" ]; then
        echo "FAIL: install stamp malformed at $stamp_path (run 'make install' in codegen)"
        return 1
    fi

    if [ "$stamped_sha" != "$current_sha" ] || [ "$stamped_hash" != "$current_hash" ]; then
        echo "FAIL: installed harness stale — stamp ${stamped_sha:0:7}/${stamped_hash:0:7}, tree ${current_sha:0:7}/${current_hash:0:7} (run 'make install' in codegen)"
        return 1
    fi

    echo "OK: installed harness current with working tree (${current_sha:0:7})"
    return 0
}
