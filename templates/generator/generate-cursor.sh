#!/bin/bash
# Cursor Markdown Agent Generator
# Generates templates/generated/cursor/agents/*.md files from shared .md.j2
# subagent templates. Mirrors generate-codex.sh's structure but emits markdown
# (Cursor agents have no frontmatter — just the rendered body).
#
# Why a dedicated script (vs. relying on generate.sh's cursor branch): this
# script preflights `harness_models[role]['cursor']` in config.yaml before
# rendering, so a missing entry fails loudly rather than silently shipping
# a Cursor agent without a model assignment.
#
# Requires:
#   - python3 (3.11+ for stdlib tomllib; not actually loaded here)
#   - pyyaml  (auto-installed via pip if missing)
#   - OCG_CONTEXT_DIR env var pointing at the shared context repo
#
# Usage: bash templates/generator/generate-cursor.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$(dirname "$SCRIPT_DIR")"
SUBAGENTS_ROOT="$TEMPLATES_DIR/shared/subagents"
CONFIG_YAML="$SCRIPT_DIR/config.yaml"
OUTPUT_AGENTS_DIR="$TEMPLATES_DIR/generated/cursor/agents"
PROCESS_TEMPLATE="$SCRIPT_DIR/process_template.py"

# Ensure output directory exists
mkdir -p "$OUTPUT_AGENTS_DIR"

# Ensure OCG_CONTEXT_DIR is set
if [ -z "$OCG_CONTEXT_DIR" ]; then
    echo "❌ OCG_CONTEXT_DIR is not set. Run 'make install' or set it manually." >&2
    exit 1
fi

# Ensure pyyaml is available (used by the preflight model check)
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "   Installing pyyaml..."
    python3 -m pip install --user --quiet pyyaml --break-system-packages 2>/dev/null ||
        python3 -m pip install --user --quiet pyyaml 2>/dev/null ||
        {
            echo "❌ Failed to install pyyaml. Run: pip3 install pyyaml" >&2
            exit 1
        }
fi

echo "🚀 Generating Cursor markdown agents..."

# Walk all subagent template subdirs (mirrors generate-codex.sh).
SUBDIRS=("$SUBAGENTS_ROOT/shared" "$SUBAGENTS_ROOT/phoenix" "$SUBAGENTS_ROOT/static" "$SUBAGENTS_ROOT/platform")

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

        # Preflight: require harness_models[role]['cursor'] in config.yaml.
        # Mirrors generate-codex.sh:142-147 — fail loudly rather than silently
        # ship a role with no cursor model assignment.
        python3 - "$CONFIG_YAML" "$role_name" <<'PY'
import sys
config_yaml = sys.argv[1]
role_name   = sys.argv[2]
try:
    import yaml
except ImportError:
    sys.exit("ERROR: pyyaml not available")
with open(config_yaml, 'r') as f:
    config = yaml.safe_load(f)
harness_models = config.get('harness_models', {})
role_models = harness_models.get(role_name)
if not role_models or 'cursor' not in role_models:
    sys.exit(
        f"ERROR: generate-cursor.sh: no harness_models[{role_name!r}]['cursor'] entry "
        f"in {config_yaml}; refusing to ship a silently-mistargeted role."
    )
PY

        echo "   Generating: ${role_name}.md"

        # Render via process_template.py with tool=cursor and
        # yaml_frontmatter=false. Cursor agent files are pure markdown — no
        # YAML header, no name/description metadata, just the body. This
        # matches the format already in ~/.cursor/agents/. process_template.py
        # has an explicit `cursor` branch alongside `claude` for future
        # per-harness divergence; today it renders identically to claude.
        python3 "$PROCESS_TEMPLATE" "$template_file" cursor false >"$output_file"
    done
done

echo ""
echo "✅ Cursor generation complete!"
echo "   Agents: $OUTPUT_AGENTS_DIR"
