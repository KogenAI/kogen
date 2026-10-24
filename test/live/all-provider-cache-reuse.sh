#!/bin/sh
# Explicit single installed qualification; deterministic suites use loopback only.
set -eu
umask 077
exec python3 "$(dirname "$0")/all_provider_cache_reuse.py" "$@"
