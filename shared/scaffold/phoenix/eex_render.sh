#!/usr/bin/env bash
# eex_render.sh — minimal EEx renderer for scaffold templates.
# Handles <%= var %> substitution only; templates must not use <% %> control-flow.
#
# Usage: eex_render.sh <template_file> <output_file> \
#          app_name=<snake_case> elixir_version=<v> node_version=<v> \
#          otp_version=<v> app_name_module=<CamelCase> otp_major_version=<N>
#
# Bindings are passed as key=value positional args (order does not matter).

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <template_file> <output_file> [key=value ...]" >&2
    exit 1
fi

template="$1"
output="$2"
shift 2

content="$(cat "$template")"

for arg in "$@"; do
    key="${arg%%=*}"
    val="${arg#*=}"
    # Escape & and \ in replacement value for sed
    escaped_val="$(printf '%s' "$val" | sed 's/[&\\/]/\\&/g')"
    content="$(printf '%s' "$content" | sed "s/<%= ${key} %>/${escaped_val}/g")"
done

mkdir -p "$(dirname "$output")"
printf '%s' "$content" >"$output"
