#!/usr/bin/env bash
# mix_exs.sh — mutates mix.exs after phx.new.
# Steps (each idempotent via grep -F anchor checks):
#   1. Inject credo + tidewave deps before {:lazy_html, ...} anchor
#   2. Replace defp aliases do [...] end with full Optimum aliases
#   3. Insert/replace def cli do block
#   4. Inject project-info sections into def project do
#   5. Restructure defp deps into phoenix_deps() ++ optimum_deps() ++ app_deps()
#
# Usage: mix_exs.sh <app_path> <app_name> <app_name_module>
#   app_name        snake_case  (e.g. my_app)
#   app_name_module CamelCase   (e.g. MyApp)

set -euo pipefail

APP_PATH="$1"
APP_NAME="$2"
APP_NAME_MODULE="$3"
shift 3

# Parse optional flags
WITH_APPSIGNAL=""
GITHUB_URL=""
NO_ECTO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
    --with-appsignal)
        WITH_APPSIGNAL="1"
        shift
        ;;
    --github-url)
        GITHUB_URL="$2"
        shift 2
        ;;
    --no-ecto)
        NO_ECTO="1"
        shift
        ;;
    *)
        shift
        ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data/mix_exs"

MIX_EXS="$APP_PATH/mix.exs"

if [ ! -f "$MIX_EXS" ]; then
    echo "[mix_exs.sh] ERROR: $MIX_EXS not found" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: inject {:credo,...} and {:tidewave,...} before {:lazy_html,...}
# Idempotent: skip if :credo or :tidewave already present.
# ---------------------------------------------------------------------------
if ! grep -qF '      {:credo,' "$MIX_EXS"; then
    sed "s|      {:lazy_html,|      {:credo, \"~> 1.7\", only: [:dev, :test], runtime: false},\n      {:lazy_html,|" "$MIX_EXS" >"${MIX_EXS}.tmp" && mv "${MIX_EXS}.tmp" "$MIX_EXS"
fi

if ! grep -qF '      {:tidewave,' "$MIX_EXS"; then
    sed "s|      {:lazy_html,|      {:tidewave, \"~> 0.5\", only: [:dev]},\n      {:lazy_html,|" "$MIX_EXS" >"${MIX_EXS}.tmp" && mv "${MIX_EXS}.tmp" "$MIX_EXS"
fi

# Post-condition: both deps must be present
if ! grep -qF '{:credo,' "$MIX_EXS"; then
    echo "[mix_exs.sh] ERROR: post-condition failed — '{:credo,' not found after Step 1" >&2
    exit 1
fi
if ! grep -qF '{:tidewave,' "$MIX_EXS"; then
    echo "[mix_exs.sh] ERROR: post-condition failed — '{:tidewave,' not found after Step 1" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: replace defp aliases do [...] end with Optimum aliases
# Idempotent: skip if ci: alias already present (stock phx.new has "ecto.setup": but not ci:).
# ---------------------------------------------------------------------------
if ! grep -qF 'ci:' "$MIX_EXS"; then
    # Build aliases content with app_name substituted
    ALIASES_CONTENT="$(sed "s/<%= app_name %>/${APP_NAME}/g" "$DATA_DIR/aliases.txt")"
    # If --no-ecto, strip ecto.* alias lines
    if [[ -n "$NO_ECTO" ]]; then
        ALIASES_CONTENT="$(echo "$ALIASES_CONTENT" | grep -v '"ecto\.')"
    fi

    # Use Python to do the multi-line replacement safely
    python3 - "$MIX_EXS" "$ALIASES_CONTENT" <<'PYEOF'
import sys
import re

mix_exs_path = sys.argv[1]
aliases_content = sys.argv[2]

with open(mix_exs_path, 'r') as f:
    content = f.read()

# Replace the aliases block: from "defp aliases do\n    [" through "]\n  end"
# keeping the function skeleton intact
new_content = re.sub(
    r'(  defp aliases do\n    \[).*?(\n    \]\n  end)',
    lambda m: m.group(1) + '\n' + aliases_content + '    ' + m.group(2).lstrip(),
    content,
    flags=re.DOTALL
)

with open(mix_exs_path, 'w') as f:
    f.write(new_content)
PYEOF
fi

# Post-condition: ecto.setup alias must be present (skipped when --no-ecto)
if [[ -z "$NO_ECTO" ]]; then
    if ! grep -qF '"ecto.setup":' "$MIX_EXS"; then
        echo "[mix_exs.sh] ERROR: post-condition failed — '\"ecto.setup\":' not found after Step 2" >&2
        exit 1
    fi
fi
# Post-condition: ci: alias must always be present
if ! grep -qF 'ci:' "$MIX_EXS"; then
    echo "[mix_exs.sh] ERROR: post-condition failed — 'ci:' not found after Step 2" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: insert/replace def cli do block
# Idempotent: skip if sobelow preferred_env already present.
# ---------------------------------------------------------------------------
if ! grep -qF 'sobelow: :test' "$MIX_EXS"; then
    CLI_CONTENT="$(cat "$DATA_DIR/cli.txt")"

    python3 - "$MIX_EXS" "$CLI_CONTENT" <<'PYEOF'
import sys
import re

mix_exs_path = sys.argv[1]
cli_content = sys.argv[2]

with open(mix_exs_path, 'r') as f:
    content = f.read()

if 'def cli do' in content:
    # Replace existing cli block
    new_content = re.sub(
        r'(  def cli do\n    \[).*?(\n    \]\n  end)',
        lambda m: '  def cli do\n' + cli_content + '  end',
        content,
        flags=re.DOTALL
    )
else:
    # Insert after def application do ... end
    new_content = re.sub(
        r'(  def application do\n.*?\n  end\n)',
        r'\1\n  def cli do\n' + cli_content.replace('\\', '\\\\') + '  end\n',
        content,
        count=1,
        flags=re.DOTALL
    )

with open(mix_exs_path, 'w') as f:
    f.write(new_content)
PYEOF
fi

# Post-condition: sobelow preferred_env must be present
if ! grep -qF 'sobelow: :test' "$MIX_EXS"; then
    echo "[mix_exs.sh] ERROR: post-condition failed — 'sobelow: :test' not found after Step 3" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: inject project-info sections into def project do
# Idempotent: skip if dialyzer plt_file already present.
# ---------------------------------------------------------------------------
if ! grep -qF 'plt_file: {:no_warn' "$MIX_EXS"; then
    PROJECT_CONTENT="$(sed \
        -e "s/<%= app_name_module %>/${APP_NAME_MODULE}/g" \
        -e "s/<%= app_name %>/${APP_NAME}/g" \
        "$DATA_DIR/project.txt")"

    # Handle source_url: inject --github-url value or drop the line
    if [[ -n "$GITHUB_URL" ]]; then
        PROJECT_CONTENT="$(echo "$PROJECT_CONTENT" | sed "s|source_url: \"https://github.com/Combobulate-HQ/user-apps\"|source_url: \"${GITHUB_URL}\"|")"
    else
        PROJECT_CONTENT="$(echo "$PROJECT_CONTENT" | grep -v 'source_url:')"
    fi

    python3 - "$MIX_EXS" "$PROJECT_CONTENT" <<'PYEOF'
import sys
import re

mix_exs_path = sys.argv[1]
project_content = sys.argv[2]

with open(mix_exs_path, 'r') as f:
    content = f.read()

# Find def project do block and inject project_content before closing ]
# The pattern: def project do\n    [...existing content...]\n  end
new_content = re.sub(
    r'(  def project do\n    \[)(.*?)(,?\n    \]\n  end)',
    lambda m: m.group(1) + m.group(2).rstrip(',') + ',\n\n' + project_content + '    ' + m.group(3).lstrip(),
    content,
    count=1,
    flags=re.DOTALL
)

with open(mix_exs_path, 'w') as f:
    f.write(new_content)
PYEOF
fi

# Post-condition: plt_file must be present
if ! grep -qF 'plt_file: {:no_warn' "$MIX_EXS"; then
    echo "[mix_exs.sh] ERROR: post-condition failed — 'plt_file: {:no_warn' not found after Step 4" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 5: restructure defp deps → phoenix_deps() ++ optimum_deps() ++ app_deps()
# Idempotent: skip if phoenix_deps already defined.
# ---------------------------------------------------------------------------
if ! grep -qF 'defp phoenix_deps do' "$MIX_EXS"; then
    DEPS_CONTENT="$(cat "$DATA_DIR/deps.txt")"

    python3 - "$MIX_EXS" "$DEPS_CONTENT" <<'PYEOF'
import sys
import re

mix_exs_path = sys.argv[1]
optimum_deps = sys.argv[2]

with open(mix_exs_path, 'r') as f:
    content = f.read()

# Update deps: reference in project def
content = content.replace(
    'deps: deps(),',
    'deps: phoenix_deps() ++ optimum_deps() ++ app_deps(),'
)

# Split defp deps do into phoenix_deps + optimum_deps + app_deps
# Remove any existing optimum deps (credo, tidewave, dialyxir, etc.) from the deps list
# to avoid duplication — they move to optimum_deps()
OPTIMUM_PKG_NAMES = [
    'credo', 'dialyxir', 'doctest_formatter', 'ex_doc',
    'ex_machina', 'excoveralls', 'faker', 'mix_audit',
    'optimum_credo', 'sobelow', 'tidewave'
]

def remove_optimum_deps_from_block(deps_block):
    lines = deps_block.split('\n')
    kept = []
    for line in lines:
        stripped = line.strip()
        # Check if this line is one of the optimum deps
        is_optimum = any(
            stripped.startswith('{:' + pkg + ',') or stripped.startswith('{:' + pkg + ' ')
            for pkg in OPTIMUM_PKG_NAMES
        )
        if not is_optimum:
            kept.append(line)
    # Remove trailing empty lines before closing bracket
    while kept and kept[-1].strip() == '':
        kept.pop()
    return '\n'.join(kept)

# Extract and restructure the defp deps block
match = re.search(r'  defp deps do\n(.*?)\n  end\n', content, re.DOTALL)
if match:
    deps_body = match.group(1)
    phoenix_body = remove_optimum_deps_from_block(deps_body)

    new_deps = (
        '  defp app_deps do\n'
        '    []\n'
        '  end\n'
        '\n'
        '  defp optimum_deps do\n'
        '    [\n'
        + optimum_deps + '\n'
        '    ]\n'
        '  end\n'
        '\n'
        '  defp phoenix_deps do\n'
        + phoenix_body + '\n'
        '  end\n'
    )

    content = content[:match.start()] + new_deps + content[match.end():]

with open(mix_exs_path, 'w') as f:
    f.write(content)
PYEOF
fi

# Post-condition: phoenix_deps function must be present
if ! grep -qF 'defp phoenix_deps do' "$MIX_EXS"; then
    echo "[mix_exs.sh] ERROR: post-condition failed — 'defp phoenix_deps do' not found after Step 5" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6 (conditional): inject {:appsignal_phoenix,...} when --with-appsignal
# Idempotent: skip if appsignal_phoenix already present.
# ---------------------------------------------------------------------------
if [[ -n "$WITH_APPSIGNAL" ]] && ! grep -qF '{:appsignal_phoenix,' "$MIX_EXS"; then
    # Add to app_deps()
    python3 - "$MIX_EXS" <<'PYEOF'
import sys
import re

mix_exs_path = sys.argv[1]

with open(mix_exs_path, 'r') as f:
    content = f.read()

# Insert {:appsignal_phoenix, "~> 2.0"} into defp app_deps do block
content = content.replace(
    '  defp app_deps do\n    []\n  end',
    '  defp app_deps do\n    [\n      {:appsignal_phoenix, "~> 2.0"}\n    ]\n  end'
)

with open(mix_exs_path, 'w') as f:
    f.write(content)
PYEOF
fi

echo "[mix_exs.sh] done"
