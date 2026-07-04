#!/usr/bin/env bash
# scaffold_cache.sh — machine-global scaffold cache for the Phoenix scaffold path.
#
# Sourced by scaffold.sh. Side-effect-free on source (defines functions only).
# Caches compiled hex deps (deps/ + _build/*/lib/<dep>) and the Dialyzer PLT
# (priv/plts/dialyzer.plt) keyed by <otp>-<elixir>-<sha256(mix.lock)> so that
# repeated same-toolchain+lockfile scaffold runs skip the expensive
# deps-compile + PLT-build steps.
#
# NO -e here: this file is sourced into scaffold.sh's `set -e` context. Every
# fail-open step below ends with `|| true`; the only deliberate non-zero exits
# are explicit `return 1`/`return 2` on genuine not-found/bad-input conditions.
set -uo pipefail

# scaffold_cache_root
#   Prints the machine-global cache root directory (does not create it).
#   Honors $XDG_CACHE_HOME; falls back to $HOME/.cache.
scaffold_cache_root() {
    echo "${XDG_CACHE_HOME:-$HOME/.cache}/codegen-scaffold"
}

# scaffold_cache_hash_file <file>
#   Prints the sha256 hex digest of <file>. Prefers sha256sum (Linux),
#   falls back to shasum -a 256 (macOS). Returns 2 if neither tool exists.
scaffold_cache_hash_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        echo "[scaffold_cache] ERROR: neither sha256sum nor shasum found — cannot compute cache key" >&2
        return 2
    fi
}

# scaffold_cache_key <target_dir> <otp> <elixir>
#   Prints the cache key "<otp>-<elixir>-<sha256(mix.lock)>" on stdout.
#   Returns 1 if <target_dir>/mix.lock does not exist (cache key not
#   computable yet — caller should fall back to a cold run).
scaffold_cache_key() {
    local target_dir="$1" otp="$2" elixir="$3"
    local lockfile="$target_dir/mix.lock"
    if [ ! -f "$lockfile" ]; then
        return 1
    fi
    local hash
    hash="$(scaffold_cache_hash_file "$lockfile")" || return 1
    echo "${otp}-${elixir}-${hash}"
}

# scaffold_cache_is_disabled <root> <key>
#   Returns 0 (true) if the cache entry for <key> carries a disable sentinel.
scaffold_cache_is_disabled() {
    local root="$1" key="$2"
    [ -f "$root/$key/disabled" ]
}

# scaffold_cache_disable <root> <key>
#   Writes a disable sentinel into <root>/<key>/. Best-effort; never fails
#   the caller (fail-open — worst case the cache simply stays cold forever).
scaffold_cache_disable() {
    local root="$1" key="$2"
    mkdir -p "$root/$key" 2>/dev/null || true
    : >"$root/$key/disabled" 2>/dev/null || true
    return 0
}

# scaffold_cache_restore <target_dir> <root> <key>
#   Restores deps/, _build/*/lib/<dep> (all env dirs), and
#   priv/plts/dialyzer.plt from <root>/<key>/ into <target_dir>.
#   Returns 1 (no-op, target left untouched) if the cache entry is missing
#   or disabled.
scaffold_cache_restore() {
    local target_dir="$1" root="$2" key="$3"
    local entry="$root/$key"

    if [ -f "$entry/disabled" ]; then
        return 1
    fi
    if [ ! -d "$entry" ]; then
        return 1
    fi

    local restored_any=""

    if [ -d "$entry/deps" ]; then
        mkdir -p "$target_dir"
        cp -R "$entry/deps" "$target_dir/deps" 2>/dev/null && restored_any="1"
    fi

    if [ -d "$entry/_build" ]; then
        mkdir -p "$target_dir/_build"
        local env_dir
        for env_dir in "$entry/_build"/*/; do
            [ -d "$env_dir" ] || continue
            local env_name
            env_name="$(basename "$env_dir")"
            mkdir -p "$target_dir/_build/$env_name/lib"
            local dep_dir
            for dep_dir in "$env_dir/lib"/*/; do
                [ -d "$dep_dir" ] || continue
                local dep_name
                dep_name="$(basename "$dep_dir")"
                cp -R "$dep_dir" "$target_dir/_build/$env_name/lib/$dep_name" 2>/dev/null && restored_any="1"
            done
        done
    fi

    if [ -f "$entry/dialyzer.plt" ]; then
        mkdir -p "$target_dir/priv/plts"
        cp "$entry/dialyzer.plt" "$target_dir/priv/plts/dialyzer.plt" 2>/dev/null && restored_any="1"
    fi

    if [ -z "$restored_any" ]; then
        return 1
    fi
    return 0
}

# scaffold_cache_save <target_dir> <root> <key> <app_name>
#   Best-effort, atomic save of deps/, _build/*/lib/<dep> (excluding the
#   app's own _build/*/lib/<app_name>), and priv/plts/dialyzer.plt from
#   <target_dir> into <root>/<key>/. Writes to a temp dir first, then moves
#   into place. Never returns non-zero — on any failure (unwritable cache
#   root, disk full, etc.) it warns on stderr and returns 0 so callers never
#   have to guard the call.
scaffold_cache_save() {
    local target_dir="$1" root="$2" key="$3" app_name="$4"
    local entry="$root/$key"
    local tmp_entry="$root/${key}.tmp.$$"

    mkdir -p "$root" 2>/dev/null || {
        echo "WARN: scaffold cache save failed — next scaffold will be cold" >&2
        return 0
    }

    rm -rf "$tmp_entry" 2>/dev/null || true
    mkdir -p "$tmp_entry" 2>/dev/null || {
        echo "WARN: scaffold cache save failed — next scaffold will be cold" >&2
        return 0
    }

    local ok="1"

    if [ -d "$target_dir/deps" ]; then
        cp -R "$target_dir/deps" "$tmp_entry/deps" 2>/dev/null || ok=""
    fi

    if [ -n "$ok" ] && [ -d "$target_dir/_build" ]; then
        mkdir -p "$tmp_entry/_build" 2>/dev/null || ok=""
        if [ -n "$ok" ]; then
            local env_dir
            for env_dir in "$target_dir/_build"/*/; do
                [ -d "$env_dir" ] || continue
                local env_name
                env_name="$(basename "$env_dir")"
                mkdir -p "$tmp_entry/_build/$env_name/lib" 2>/dev/null || {
                    ok=""
                    break
                }
                local dep_dir
                for dep_dir in "$env_dir/lib"/*/; do
                    [ -d "$dep_dir" ] || continue
                    local dep_name
                    dep_name="$(basename "$dep_dir")"
                    # Never cache the app's own compiled output.
                    if [ "$dep_name" = "$app_name" ]; then
                        continue
                    fi
                    cp -R "$dep_dir" "$tmp_entry/_build/$env_name/lib/$dep_name" 2>/dev/null || {
                        ok=""
                        break
                    }
                done
            done
        fi
    fi

    if [ -n "$ok" ] && [ -f "$target_dir/priv/plts/dialyzer.plt" ]; then
        cp "$target_dir/priv/plts/dialyzer.plt" "$tmp_entry/dialyzer.plt" 2>/dev/null || ok=""
    fi

    if [ -z "$ok" ]; then
        rm -rf "$tmp_entry" 2>/dev/null || true
        echo "WARN: scaffold cache save failed — next scaffold will be cold" >&2
        return 0
    fi

    rm -rf "$entry" 2>/dev/null || true
    if ! mv "$tmp_entry" "$entry" 2>/dev/null; then
        rm -rf "$tmp_entry" 2>/dev/null || true
        echo "WARN: scaffold cache save failed — next scaffold will be cold" >&2
        return 0
    fi

    return 0
}
