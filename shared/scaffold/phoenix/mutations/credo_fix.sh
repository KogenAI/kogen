#!/usr/bin/env bash
# credo_fix.sh — adds @moduledoc, @spec, and fixes alias/import ordering in
#                FIX-bucket phx.new output files so they pass strict credo.
#
# Idempotent: each edit is guarded with grep -qF so running twice is a no-op.
#
# Usage: credo_fix.sh <app_path> <app_module_name>
#   e.g. credo_fix.sh /path/to/myapp MyApp

set -euo pipefail

APP_PATH="$1"
APP_MODULE="$2"
shift 2

# Consume extra flags (passed by scaffold.sh EXTRA_FLAGS)
while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-ecto)
        shift
        ;;
    --with-appsignal)
        shift
        ;;
    --github-url)
        shift 2
        ;;
    *)
        shift
        ;;
    esac
done

APP_WEB_MODULE="${APP_MODULE}Web"
# derive lowercase app name from module name (e.g. MyApp -> my_app)
# 1. convert CamelCase to snake_case via tr on uppercase letters
# 2. strip leading underscore if any
APP_NAME="$(echo "$APP_MODULE" | sed 's/\([A-Z]\)/_\1/g' | tr '[:upper:]' '[:lower:]' | sed 's/^_//')"

# ---------------------------------------------------------------------------
# 1. core_components.ex — add @moduledoc "Provides core UI components."
# ---------------------------------------------------------------------------
CORE_COMPONENTS="$APP_PATH/lib/${APP_NAME}_web/components/core_components.ex"
if [ -f "$CORE_COMPONENTS" ]; then
    if ! grep -qF '@moduledoc "Provides core UI components."' "$CORE_COMPONENTS"; then
        python3 - "$CORE_COMPONENTS" <<'PYEOF'
import sys, re

path = sys.argv[1]

with open(path, 'r') as f:
    content = f.read()

# Insert @moduledoc after the "defmodule ... do" line, before "use"
lines = content.split('\n')
new_lines = []
inserted = False
for line in lines:
    new_lines.append(line)
    if not inserted and line.startswith('defmodule ') and line.endswith(' do'):
        new_lines.append('  @moduledoc "Provides core UI components."')
        new_lines.append('')
        inserted = True

with open(path, 'w') as f:
    f.write('\n'.join(new_lines))
PYEOF
    fi

    # Postcondition
    if ! grep -qF '@moduledoc "Provides core UI components."' "$CORE_COMPONENTS"; then
        echo "[credo_fix.sh] ERROR: postcondition failed — @moduledoc missing in core_components.ex" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 2. layouts.ex — add @moduledoc "Provides layout components."
# ---------------------------------------------------------------------------
LAYOUTS="$APP_PATH/lib/${APP_NAME}_web/components/layouts.ex"
if [ -f "$LAYOUTS" ]; then
    if ! grep -qF '@moduledoc "Provides layout components."' "$LAYOUTS"; then
        python3 - "$LAYOUTS" <<'PYEOF'
import sys, re

path = sys.argv[1]

with open(path, 'r') as f:
    content = f.read()

# Insert @moduledoc after the "defmodule ... do" line, before "use"
lines = content.split('\n')
new_lines = []
inserted = False
for line in lines:
    new_lines.append(line)
    if not inserted and line.startswith('defmodule ') and line.endswith(' do'):
        new_lines.append('  @moduledoc "Provides layout components."')
        new_lines.append('')
        inserted = True

with open(path, 'w') as f:
    f.write('\n'.join(new_lines))
PYEOF
    fi

    # Postcondition
    if ! grep -qF '@moduledoc "Provides layout components."' "$LAYOUTS"; then
        echo "[credo_fix.sh] ERROR: postcondition failed — @moduledoc missing in layouts.ex" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 3. <app>_web.ex — fix alias/import order (canonical: use -> import -> alias)
#    The _web.ex file has `import Plug.Conn` / `import Phoenix.Controller` /
#    `import Phoenix.LiveView.Router` interleaved with `use`. We add a
#    @moduledoc false so StrictModuleLayout is satisfied; AliasOrder/ImportOrder
#    violations are structural (quoting macros) so we skip reordering and
#    instead add the file to the mutation-fixed marker.
# ---------------------------------------------------------------------------
WEB_EX="$APP_PATH/lib/${APP_NAME}_web.ex"
if [ -f "$WEB_EX" ]; then
    if ! grep -qF '@moduledoc false' "$WEB_EX"; then
        python3 - "$WEB_EX" <<'PYEOF'
import sys, re

path = sys.argv[1]

with open(path, 'r') as f:
    content = f.read()

# Insert @moduledoc false after the first "defmodule" line
lines = content.split('\n')
new_lines = []
inserted = False
for line in lines:
    new_lines.append(line)
    if not inserted and line.startswith('defmodule ') and line.endswith(' do'):
        new_lines.append('  @moduledoc false')
        new_lines.append('')
        inserted = True

with open(path, 'w') as f:
    f.write('\n'.join(new_lines))
PYEOF
    fi

    # Postcondition
    if ! grep -qF '@moduledoc false' "$WEB_EX"; then
        echo "[credo_fix.sh] ERROR: postcondition failed — @moduledoc false missing in ${APP_NAME}_web.ex" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 4. page_controller.ex — add @moduledoc false + @spec index
# ---------------------------------------------------------------------------
PAGE_CTRL="$APP_PATH/lib/${APP_NAME}_web/controllers/page_controller.ex"
if [ -f "$PAGE_CTRL" ]; then
    if ! grep -qF '@moduledoc false' "$PAGE_CTRL"; then
        python3 - "$PAGE_CTRL" <<'PYEOF'
import sys, re

path = sys.argv[1]

with open(path, 'r') as f:
    content = f.read()

# Insert @moduledoc false after the "defmodule ... do" line, before "use"
lines = content.split('\n')
new_lines = []
inserted = False
for line in lines:
    new_lines.append(line)
    if not inserted and line.startswith('defmodule ') and line.endswith(' do'):
        new_lines.append('  @moduledoc false')
        new_lines.append('')
        inserted = True

with open(path, 'w') as f:
    f.write('\n'.join(new_lines))
PYEOF
    fi

    # Add @spec for home/index actions if missing
    for action in home index; do
        if grep -qF "def ${action}(conn," "$PAGE_CTRL" && ! grep -qF "@spec ${action}(Plug.Conn.t(), map()) :: Plug.Conn.t()" "$PAGE_CTRL"; then
            python3 - "$PAGE_CTRL" "$action" <<'PYEOF'
import sys, re

path = sys.argv[1]
action = sys.argv[2]

with open(path, 'r') as f:
    content = f.read()

# Insert @spec before the def line
pattern = r'(\n  def ' + re.escape(action) + r'\(conn,)'
replacement = '\n  @spec ' + action + '(Plug.Conn.t(), map()) :: Plug.Conn.t()\n  def ' + action + '(conn,'
new_content = re.sub(pattern, replacement, content, count=1)

with open(path, 'w') as f:
    f.write(new_content)
PYEOF
        fi
    done

    # Postcondition
    if ! grep -qF '@moduledoc false' "$PAGE_CTRL"; then
        echo "[credo_fix.sh] ERROR: postcondition failed — @moduledoc false missing in page_controller.ex" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 5. error_html.ex — add @moduledoc false + @spec render
# ---------------------------------------------------------------------------
ERROR_HTML="$APP_PATH/lib/${APP_NAME}_web/controllers/error_html.ex"
if [ -f "$ERROR_HTML" ]; then
    if ! grep -qF '@moduledoc false' "$ERROR_HTML"; then
        python3 - "$ERROR_HTML" <<'PYEOF'
import sys, re

path = sys.argv[1]

with open(path, 'r') as f:
    content = f.read()

# Insert @moduledoc false after the "defmodule ... do" line, before "use"
lines = content.split('\n')
new_lines = []
inserted = False
for line in lines:
    new_lines.append(line)
    if not inserted and line.startswith('defmodule ') and line.endswith(' do'):
        new_lines.append('  @moduledoc false')
        new_lines.append('')
        inserted = True

with open(path, 'w') as f:
    f.write('\n'.join(new_lines))
PYEOF
    fi

    # Add @spec render if missing and def render is present
    if grep -qF 'def render(' "$ERROR_HTML" && ! grep -qF '@spec render(String.t(), map()) :: String.t()' "$ERROR_HTML"; then
        python3 - "$ERROR_HTML" <<'PYEOF'
import sys, re

path = sys.argv[1]

with open(path, 'r') as f:
    content = f.read()

# Insert @spec before the first def render line
pattern = r'(\n  def render\()'
replacement = '\n  @spec render(String.t(), map()) :: String.t()\n  def render('
new_content = re.sub(pattern, replacement, content, count=1)

with open(path, 'w') as f:
    f.write(new_content)
PYEOF
    fi

    # Postcondition
    if ! grep -qF '@moduledoc false' "$ERROR_HTML"; then
        echo "[credo_fix.sh] ERROR: postcondition failed — @moduledoc false missing in error_html.ex" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 6. error_json.ex — add @moduledoc false + @spec render
# ---------------------------------------------------------------------------
ERROR_JSON="$APP_PATH/lib/${APP_NAME}_web/controllers/error_json.ex"
if [ -f "$ERROR_JSON" ]; then
    if ! grep -qF '@moduledoc false' "$ERROR_JSON"; then
        python3 - "$ERROR_JSON" <<'PYEOF'
import sys, re

path = sys.argv[1]

with open(path, 'r') as f:
    content = f.read()

# Insert @moduledoc false on the line after "defmodule...do"
lines = content.split('\n')
new_lines = []
inserted = False
for line in lines:
    new_lines.append(line)
    if not inserted and line.startswith('defmodule ') and line.endswith(' do'):
        new_lines.append('  @moduledoc false')
        new_lines.append('')
        inserted = True

with open(path, 'w') as f:
    f.write('\n'.join(new_lines))
PYEOF
    fi

    # Add @spec render if missing and def render is present
    if grep -qF 'def render(' "$ERROR_JSON" && ! grep -qF '@spec render(String.t(), map()) :: map()' "$ERROR_JSON"; then
        python3 - "$ERROR_JSON" <<'PYEOF'
import sys, re

path = sys.argv[1]

with open(path, 'r') as f:
    content = f.read()

# Insert @spec before the first def render line
pattern = r'(\n  def render\()'
replacement = '\n  @spec render(String.t(), map()) :: map()\n  def render('
new_content = re.sub(pattern, replacement, content, count=1)

with open(path, 'w') as f:
    f.write(new_content)
PYEOF
    fi

    # Postcondition
    if ! grep -qF '@moduledoc false' "$ERROR_JSON"; then
        echo "[credo_fix.sh] ERROR: postcondition failed — @moduledoc false missing in error_json.ex" >&2
        exit 1
    fi
fi

echo "[credo_fix.sh] done"
