#!/bin/bash
# Pi Markdown Agent Generator
# Generates ~/.pi/agent/agents/*.md files from shared .md.j2 subagent templates.
#
# Requires:
#   - python3
#   - pyyaml  (auto-installed via pip if missing)
#   - OCG_CONTEXT_DIR env var pointing at the shared context repo
#
# Usage: bash templates/generator/generate-pi.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$(dirname "$SCRIPT_DIR")"
SUBAGENTS_ROOT="$TEMPLATES_DIR/shared/subagents"
OUTPUT_AGENTS_DIR="$TEMPLATES_DIR/generated/pi/agent"

# Ensure output directory exists
mkdir -p "$OUTPUT_AGENTS_DIR"

# Ensure OCG_CONTEXT_DIR is set
if [ -z "$OCG_CONTEXT_DIR" ]; then
    echo "❌ OCG_CONTEXT_DIR is not set. Run 'make install' or set it manually." >&2
    exit 1
fi

# Ensure pyyaml is available
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "   Installing pyyaml..."
    python3 -m pip install --user --quiet pyyaml --break-system-packages 2>/dev/null ||
        python3 -m pip install --user --quiet pyyaml 2>/dev/null ||
        {
            echo "❌ Failed to install pyyaml. Run: pip3 install pyyaml" >&2
            exit 1
        }
fi

echo "🚀 Generating Pi Markdown agents..."

# Walk all subagent template subdirs
SUBDIRS=("$SUBAGENTS_ROOT/shared" "$SUBAGENTS_ROOT/phoenix" "$SUBAGENTS_ROOT/static")

for subdir in "${SUBDIRS[@]}"; do
    if [ ! -d "$subdir" ]; then
        continue
    fi
    for template_file in "$subdir"/*.md.j2; do
        if [ ! -f "$template_file" ]; then
            continue
        fi

        # Derive role name: strip directory prefix and .md.j2 suffix
        base_name=$(basename "$template_file" .j2) # e.g. planner.md
        role_name="${base_name%.md}"               # e.g. planner
        output_file="$OUTPUT_AGENTS_DIR/${role_name}.md"

        echo "   Generating: ${role_name}.md"

        python3 "$SCRIPT_DIR/process_template.py" \
            --format=md \
            "$template_file" pi false >"$output_file"

        echo "   ✅ Written: $(basename "$output_file")"
    done
done

echo ""
echo "✅ Pi generation complete!"
echo "   Agents: $OUTPUT_AGENTS_DIR"
