#!/usr/bin/env bash
# scaffold.sh — Static site scaffold entrypoint.
#
# Writes vanilla Vite static site scaffold files.
#
# Usage: scaffold.sh <slug> <cwd> --app-name <name>
#   slug      URL-safe app identifier (used in package.json "name")
#   cwd       absolute path where the static site files will be written
#   --app-name  human-readable app name (used in <title>, <h1>, README heading)
#
# Writes:
#   index.html            ← Vite entry (root)
#   vite.config.js        ← Vite config with @tailwindcss/vite plugin
#   package.json          ← scripts: build/serve/dev; devDeps: vite, @tailwindcss/vite, tailwindcss
#   src/main.js           ← app entry
#   src/style.css         ← @import "tailwindcss"
#   README.md
#   .gitignore
#   codegen/pitches/{draft,ready,shipped}/.gitkeep
#
# Does NOT: run npm install, touch git, Caddy, or any database.

set -euo pipefail

SLUG=""
CWD=""
APP_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    --app-name=*)
        APP_NAME="${1#--app-name=}"
        shift
        ;;
    --app-name)
        APP_NAME="$2"
        shift 2
        ;;
    -*)
        printf '[static/scaffold.sh] Unknown flag: %s\n' "$1" >&2
        exit 1
        ;;
    *)
        if [[ -z "$SLUG" ]]; then
            SLUG="$1"
        elif [[ -z "$CWD" ]]; then
            CWD="$1"
        else
            printf '[static/scaffold.sh] Unexpected positional arg: %s\n' "$1" >&2
            exit 1
        fi
        shift
        ;;
    esac
done

if [[ -z "$SLUG" || -z "$CWD" ]]; then
    printf 'Usage: scaffold.sh <slug> <cwd> --app-name <name>\n' >&2
    exit 2
fi

if [[ -z "$APP_NAME" ]]; then
    APP_NAME="$SLUG"
fi

# ── index.html ────────────────────────────────────────────────────────────────
cat >"$CWD/index.html" <<EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>${APP_NAME}</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.js"></script>
  </body>
</html>
EOF

# ── vite.config.js ────────────────────────────────────────────────────────────
cat >"$CWD/vite.config.js" <<'EOF'
import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [tailwindcss()],
  build: {
    outDir: "public",
  },
});
EOF

# ── package.json ──────────────────────────────────────────────────────────────
cat >"$CWD/package.json" <<EOF
{
  "name": "${SLUG}",
  "type": "module",
  "scripts": {
    "build": "vite build",
    "dev": "vite",
    "serve": "vite build && python3 -u -m http.server --directory public 0"
  },
  "devDependencies": {
    "@tailwindcss/vite": "^4.0.0",
    "tailwindcss": "^4.0.0",
    "vite": "^6.0.0"
  }
}
EOF

# ── src/main.js ───────────────────────────────────────────────────────────────
mkdir -p "$CWD/src"
cat >"$CWD/src/main.js" <<EOF
import "./style.css";

document.querySelector("#app").innerHTML = \`
  <h1 class="text-3xl font-bold text-center mt-16">${APP_NAME}</h1>
\`;
EOF

# ── src/style.css ─────────────────────────────────────────────────────────────
cat >"$CWD/src/style.css" <<'EOF'
@import "tailwindcss";
EOF

# ── README.md ─────────────────────────────────────────────────────────────────
cat >"$CWD/README.md" <<EOF
# ${APP_NAME}

${APP_NAME} is a static website built with Vite and Tailwind CSS v4.

## Development

Install dependencies:

\`\`\`bash
npm install
\`\`\`

Build the site:

\`\`\`bash
npm run build
\`\`\`

Watch for changes and serve locally:

\`\`\`bash
npm run serve
\`\`\`
EOF

# ── .gitignore: static-site non-marker entries ────────────────────────────────
# Written unconditionally — codegen-scaffold's integrate stage adds the
# machine-local symlink marker block on top of these entries (idempotent).
cat >"$CWD/.gitignore" <<'EOF'
/node_modules/
/public/
/package-lock.json
current
public-*
.DS_Store
EOF

# ── codegen/pitches lifecycle dirs ────────────────────────────────────────────
for _d in draft ready shipped; do
    mkdir -p "$CWD/codegen/pitches/$_d"
    touch "$CWD/codegen/pitches/$_d/.gitkeep"
done

printf '[static/scaffold.sh] Scaffold complete for %s at %s\n' "$SLUG" "$CWD"
