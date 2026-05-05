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

# Roles that must be read-only even without a 'tools:' frontmatter line
# planner is intentionally read-only per spec
READONLY_ROLES="planner"

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

        python3 - "$template_file" "$output_file" "$CONFIG_YAML" "$role_name" "$OCG_CONTEXT_DIR" "$READONLY_ROLES" <<'PY'
import sys
import re
import os

template_file = sys.argv[1]
output_file   = sys.argv[2]
config_yaml   = sys.argv[3]
role_name     = sys.argv[4]
context_dir   = sys.argv[5]
readonly_roles_str = sys.argv[6]

try:
    import yaml
except ImportError:
    print("ERROR: pyyaml not available", file=sys.stderr)
    sys.exit(1)

# Load config.yaml to get harness_models
with open(config_yaml, 'r') as f:
    config = yaml.safe_load(f)

harness_models = config.get('harness_models', {})

# ---- Parse template file ----
with open(template_file, 'r') as f:
    raw = f.read()

# Extract YAML frontmatter between first pair of ---
fm_match = re.match(r'^\{%\s*if\s+tool\.yaml_frontmatter\s*%\}\s*---\n(.*?)\n---\s*\n\{%\s*endif\s*%\}', raw, re.DOTALL)
frontmatter = {}
if fm_match:
    frontmatter = yaml.safe_load(fm_match.group(1)) or {}

# Strip the {% if tool.yaml_frontmatter %}...{% endif %} block to get body
body = re.sub(r'\{%\s*if\s+tool\.yaml_frontmatter\s*%\}.*?\{%\s*endif\s*%\}\s*\n?', '', raw, flags=re.DOTALL)

# Strip remaining {% if ... %}...{% endif %} blocks (keep body inside)
# For codex: no yaml_frontmatter, so remove those wrapping blocks but keep inner content
body = re.sub(r'\{%\s*if\s+tool\.yaml_frontmatter\s*%\}(.*?)\{%\s*endif\s*%\}', '', body, flags=re.DOTALL)

# Resolve {% include 'path' %} directives
def resolve_include(m):
    path = m.group(1).strip().strip("'\"")
    full_path = os.path.join(context_dir, path)
    if not os.path.exists(full_path):
        raise FileNotFoundError(f"Include not found: {full_path}")
    with open(full_path, 'r') as f:
        content = f.read()
    if content and not content.endswith('\n'):
        content += '\n'
    return content

body = re.sub(r'\{%\s*include\s+[\'"]([^\'"]+)[\'"]\s*%\}', resolve_include, body)

# Remove any remaining Jinja-style tags
body = re.sub(r'\{%[^%]*%\}', '', body)

# Strip leading/trailing whitespace
body = body.strip()

# ---- Derive TOML fields ----
name_val        = frontmatter.get('name', role_name)
description_val = frontmatter.get('description', '')
effort_val      = frontmatter.get('effort', 'medium')
has_tools       = 'tools' in frontmatter

readonly_roles  = [r.strip() for r in readonly_roles_str.split() if r.strip()]
is_readonly     = has_tools or (role_name in readonly_roles)
sandbox_mode    = 'read-only' if is_readonly else 'workspace-write'

# Model lookup — fail loudly when a role has no codex entry rather than
# silently shipping a mistargeted role to production.
role_models = harness_models.get(role_name)
if not role_models or 'codex' not in role_models:
    sys.exit(f"ERROR: generate-codex.sh: no harness_models[{role_name!r}]['codex'] entry in config.yaml; refusing to ship a silently-mistargeted role.")
model_val = role_models['codex']

# Reasoning effort
effort_map = {'high': 'high', 'medium': 'medium', 'low': 'low'}
reasoning_effort = effort_map.get(effort_val, 'medium')

# Use TOML literal multiline strings (''') so backslashes in body are treated literally.
# Escape any literal ''' in body by splitting into adjacent literal/basic string segments.
# In practice rule files never contain ''', so this is a safety fallback.
if "'''" in body:
    # Fall back to basic string with full backslash escaping when body contains '''.
    body_escaped = body.replace('\\', '\\\\').replace('"', '\\"').replace('\r', '\\r')
    instr_line = f'developer_instructions = """\n{body_escaped}\n"""'
else:
    body_for_toml = f"'''\n{body}\n'''"
    instr_line = f'developer_instructions = {body_for_toml}'

# ---- Write TOML ----
lines = []
lines.append(f'name = "{name_val}"')
if description_val:
    lines.append(f'description = "{description_val}"')
lines.append(f'model = "{model_val}"')
lines.append(f'model_reasoning_effort = "{reasoning_effort}"')
lines.append(f'sandbox_mode = "{sandbox_mode}"')
lines.append('')
lines.append(instr_line)
lines.append('')

with open(output_file, 'w') as f:
    f.write('\n'.join(lines))

print(f"   ✅ Written: {os.path.basename(output_file)}")
PY

        GENERATED_AGENTS+=("$role_name")
    done
done

echo ""
echo "🚀 Generating Codex config.toml..."

# Build config.toml
python3 - "$OUTPUT_CONFIG" "$OUTPUT_AGENTS_DIR" <<'PY'
import sys
import os

output_config     = sys.argv[1]
agents_dir        = sys.argv[2]

lines = []
lines.append('[features]')
lines.append('codex_hooks = true')
lines.append('')
lines.append('[agents]')
lines.append('max_depth = 5')
lines.append('max_threads = 6')
lines.append('')
lines.append('[[hooks.PreToolUse]]')
lines.append('command = "$HOME/.codex/hooks/codex-inspector-bash-guard.sh"')
lines.append('')
lines.append('[[hooks.PreToolUse]]')
lines.append('command = "$HOME/.codex/hooks/codex-inspector-write-guard.sh"')
lines.append('')

with open(output_config, 'w') as f:
    f.write('\n'.join(lines))

print(f"   ✅ Written: {os.path.basename(output_config)}")
PY

echo ""
echo "✅ Codex generation complete!"
echo "   Agents: $OUTPUT_AGENTS_DIR"
echo "   Config: $OUTPUT_CONFIG"
