#!/usr/bin/env bash
# test-stub-lib.sh — shared helpers to collapse test-created executables onto
# one already-scanned inode (macOS fresh-exec-inode scan tax) and to hardlink
# real repo executables instead of copying them.
#
# Sourced into `set -e` test scripts — this file itself uses `set -uo
# pipefail` only (no `-e`), and every fallible step ends `|| true` except the
# intentional fail-loud guards below.
#
# Mechanism:
#   - Every synthetic stub is a hardlink to ONE shared trampoline executable
#     (tmp/test-stub-cache/.trampoline), which just execs "$0.body". The real
#     stub logic lives in a sibling `.body` DATA file — never exec'd, never
#     scanned by macOS's on-exec malware scan.
#   - Real repo executables a test copies (codegen-build, dispatch.sh, ...)
#     are hardlinked via link_or_copy, falling back to cp on cross-filesystem
#     failures.
#
# Functions:
#   _ensure_trampoline            -> echoes path to the shared trampoline exe
#   link_or_copy <src> <dst>      -> hardlink dst to src, or cp+chmod fallback
#   make_stub <path> <body>       -> write path.body + link path -> trampoline
#   _warm_replace <path> <body>   -> like make_stub, for an already-linked path
#   link_stub_path <path>         -> point path -> trampoline; body already
#                                     written to path.body by caller (heredoc)
#
# GOTCHA: aliasing one trampoline stub to another path with link_or_copy
# hardlinks only the trampoline exe — you MUST also link_or_copy the sibling
# "$src.body" -> "$dst.body", or the alias's trampoline execs a .body that
# does not exist at the new path.
set -uo pipefail

_test_stub_lib_root() {
    # Derive repo root from this file's own location — never hardcode.
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # harnesses/shared/test-stub-lib.sh -> repo root is two dirs up
    (cd "$here/../.." && pwd)
}

_ensure_trampoline() {
    local root cache_dir trampoline tmp
    root="$(_test_stub_lib_root)"
    cache_dir="$root/tmp/test-stub-cache"
    trampoline="$cache_dir/.trampoline"

    mkdir -p "$cache_dir" 2>/dev/null || true

    if [ ! -x "$trampoline" ]; then
        tmp="$cache_dir/.trampoline.tmp.$$"
        {
            printf '#!/usr/bin/env bash\n'
            printf 'exec bash "$0.body" "$@"\n'
        } >"$tmp"
        chmod +x "$tmp"
        # Atomic, concurrent-safe: a losing racer's mv -n is a harmless no-op.
        mv -n "$tmp" "$trampoline" 2>/dev/null || true
        rm -f "$tmp" 2>/dev/null || true
    fi

    printf '%s\n' "$trampoline"
}

link_or_copy() {
    local src="$1" dst="$2"
    rm -f "$dst" 2>/dev/null || true
    ln "$src" "$dst" 2>/dev/null || {
        cp "$src" "$dst"
        chmod +x "$dst"
    }
}

make_stub() {
    local path="$1" body="$2"
    if [ -z "$path" ]; then
        printf 'make_stub: empty path\n' >&2
        return 1
    fi
    if [ -z "$body" ]; then
        printf 'make_stub: empty body\n' >&2
        return 1
    fi

    local trampoline
    trampoline="$(_ensure_trampoline)"

    printf '%s' "$body" >"$path.body"
    chmod 644 "$path.body"

    ln -f "$trampoline" "$path"
}

_warm_replace() {
    local path="$1" body="$2"
    if [ -z "$path" ]; then
        printf '_warm_replace: empty path\n' >&2
        return 1
    fi
    if [ -z "$body" ]; then
        printf '_warm_replace: empty body\n' >&2
        return 1
    fi

    local trampoline
    trampoline="$(_ensure_trampoline)"

    printf '%s' "$body" >"$path.body"
    chmod 644 "$path.body"

    # Never truncate the shared trampoline inode via >; always ln -f.
    ln -f "$trampoline" "$path"
}

# link_stub_path <path>
# Points $path at the shared trampoline (ln -f, never a truncating >). Use
# this at a call site that writes the stub BODY itself via a heredoc redirect
# to "$path.body" (`cat >"$path.body" <<'EOF' ... EOF`), then calls this fn
# to point $path at the trampoline. Keeps existing heredoc call sites' exact
# quoting (literal 'EOF' vs interpolating EOF) untouched — only the
# redirect target changes, from $path to $path.body.
link_stub_path() {
    local path="$1"
    if [ -z "$path" ]; then
        printf 'link_stub_path: empty path\n' >&2
        return 1
    fi
    local trampoline
    trampoline="$(_ensure_trampoline)"
    chmod 644 "$path.body" 2>/dev/null || true
    ln -f "$trampoline" "$path"
}
