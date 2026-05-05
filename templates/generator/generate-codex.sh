#!/bin/bash
# Codex TOML Agent Generator
# Generates ~/.codex/agents/*.toml files from shared .md.j2 subagent templates.
# Also generates templates/generated/codex/config.toml with [features], [agents],
# and [[hooks.PreToolUse]] entries.
#
# Requires:
#   - python3 (3.11+ for stdlib tomllib; only used for validation)
#   - pyyaml  (auto-installed via pip if missing)
#   - OCG_CONTEXT_DIR env var pointing at the shared context repo
#
# Usage: bash templates/generator/generate-codex.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$(dirname "$SCRIPT_DIR")"
SUBAGENTS_ROOT="$TEMPLATES_DIR/shared/subagents"
CONFIG_YAML="$SCRIPT_DIR/config.yaml"
OUTPUT_AGENTS_DIR="$TEMPLATES_DIR/generated/codex/agents"
OUTPUT_CONFIG="$TEMPLATES_DIR/generated/codex/config.toml"

# Ensure output directories exist
mkdir -p "$OUTPUT_AGENTS_DIR"
mkdir -p "$(dirname "$OUTPUT_CONFIG")"

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

echo "🚀 Generating Codex TOML agents..."

# sandbox_mode is derived from each template's `tools:` frontmatter by
# process_template.py — see STYLE_GUIDE.md. No per-role allowlist here.

# Walk all subagent template subdirs
SUBDIRS=("$SUBAGENTS_ROOT/shared" "$SUBAGENTS_ROOT/phoenix" "$SUBAGENTS_ROOT/static" "$SUBAGENTS_ROOT/platform")

GENERATED_AGENTS=()

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
        output_file="$OUTPUT_AGENTS_DIR/${role_name}.toml"

        echo "   Generating: ${role_name}.toml"

        python3 "$SCRIPT_DIR/process_template.py" \
            --format=toml \
            --config="$CONFIG_YAML" \
            --role="$role_name" \
            "$template_file" >"$output_file"

        echo "   ✅ Written: $(basename "$output_file")"

        GENERATED_AGENTS+=("$role_name")
    done
done

echo ""
echo "🚀 Generating Codex config.toml..."

# Build config.toml via the shared renderer (also used by Combobulate.Apps).
python3 "$SCRIPT_DIR/codex_config.py" \
    --target=global \
    --hook 'PreToolUse:$HOME/.codex/hooks/codex-inspector-bash-guard.sh' \
    --hook 'PreToolUse:$HOME/.codex/hooks/codex-inspector-write-guard.sh' \
    --out "$OUTPUT_CONFIG"

echo "   ✅ Written: $(basename "$OUTPUT_CONFIG")"

echo ""
echo "✅ Codex generation complete!"
echo "   Agents: $OUTPUT_AGENTS_DIR"
echo "   Config: $OUTPUT_CONFIG"
