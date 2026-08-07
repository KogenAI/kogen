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
#   index.html            ← Vite entry (root); SEO/AI-discoverability baseline head tags
#   vite.config.js        ← Vite config with @tailwindcss/vite plugin; publicDir: "static"
#   package.json          ← scripts: build/serve/dev/lint; devDeps: vite, @tailwindcss/vite, tailwindcss, eslint, @eslint/js
#   eslint.config.js      ← flat-config; lints src/**/*.js
#   src/main.js           ← app entry
#   src/style.css         ← @import "tailwindcss"
#   static/robots.txt     ← copied to public/ via publicDir
#   README.md
#   .gitignore
#   Makefile              ← build surface with ci: target (linting, format check, build)
#   .claude/gate-config.sh ← gate configuration for loop integration
#   codegen/pitches/{draft,ready,shipped}/  (recreated by codegen-scaffold integrate; no sentinel)
#
# Does NOT: run npm install, touch git, Caddy, or any database.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER_SH="$SCRIPT_DIR/eex_render.sh"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

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

mkdir -p "$CWD"

# ── index.html ────────────────────────────────────────────────────────────────
cat >"$CWD/index.html" <<EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>${APP_NAME}</title>
    <meta name="description" content="${APP_NAME} is a website." />
    <meta property="og:title" content="${APP_NAME}" />
    <meta property="og:description" content="${APP_NAME} is a website." />
    <meta property="og:type" content="website" />
    <meta
      property="og:image"
      content="https://SITE_URL_PLACEHOLDER/og-image.png"
    />
    <link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" />
    <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        "name": "${APP_NAME}",
        "url": "https://SITE_URL_PLACEHOLDER/"
      }
    </script>
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
  publicDir: "static",
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
    "lint": "eslint .",
    "serve": "vite build && python3 -u -m http.server --directory public 0"
  },
  "devDependencies": {
    "@eslint/js": "^10.0.0",
    "@tailwindcss/vite": "^4.0.0",
    "eslint": "^10.0.0",
    "tailwindcss": "^4.0.0",
    "vite": "^8.0.0"
  }
}
EOF

# ── eslint.config.js ──────────────────────────────────────────────────────────
cat >"$CWD/eslint.config.js" <<'EOF'
import js from "@eslint/js";

export default [
  js.configs.recommended,
  {
    ignores: ["public/**", "node_modules/**"],
  },
  {
    files: ["**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {
        document: "readonly",
        window: "readonly",
      },
    },
  },
];
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

# ── static/robots.txt ─────────────────────────────────────────────────────────
mkdir -p "$CWD/static"
cat >"$CWD/static/robots.txt" <<'EOF'
User-agent: *
Allow: /
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

# ── render() helper: minimal EEx template substitution ────────────────────────
render() {
    local template_rel="$1"
    local output_rel="${template_rel%.eex}" # strip .eex suffix

    # Ensure parent directory exists (handles nested paths like .claude/gate-config.sh)
    mkdir -p "$CWD/$(dirname "$output_rel")"

    "$RENDER_SH" \
        "$TEMPLATES_DIR/$template_rel" \
        "$CWD/$output_rel" \
        "slug=$SLUG"
}

render "Makefile.eex"
render ".claude/gate-config.sh.eex"

# ── codegen/pitches lifecycle dirs ────────────────────────────────────────────
# No sentinel: these dirs sit under an unnegated /codegen/ .gitignore boundary,
# so a .gitkeep file cannot survive a clone. run_integrate_stage
# (codegen-scaffold) is the durable recreator; mkdir here only covers first
# provision.
for _d in draft ready shipped; do
    mkdir -p "$CWD/codegen/pitches/$_d"
done

printf '[static/scaffold.sh] Scaffold complete for %s at %s\n' "$SLUG" "$CWD"
