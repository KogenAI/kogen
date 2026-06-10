#!/usr/bin/env bash
# scaffold.sh — Static site scaffold entrypoint.
#
# Writes static site scaffold files: html, package.json, readme, css.
#
# Usage: scaffold.sh <slug> <cwd> --app-name <name>
#   slug      URL-safe app identifier (used in package.json "name")
#   cwd       absolute path where the static site files will be written
#   --app-name  human-readable app name (used in <title>, <h1>, README heading)
#
# Writes:
#   assets/css/app.css
#   static/images/.keep
#   static/js/.keep
#   static/index.html
#   package.json
#   README.md
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
    # Fall back to slug if app-name not provided
    APP_NAME="$SLUG"
fi

# ── assets/css/app.css ────────────────────────────────────────────────────────
mkdir -p "$CWD/assets/css"
printf '@import "tailwindcss";\n' >"$CWD/assets/css/app.css"

# ── static/images/.keep and static/js/.keep ───────────────────────────────────
mkdir -p "$CWD/static/images"
touch "$CWD/static/images/.keep"

mkdir -p "$CWD/static/js"
touch "$CWD/static/js/.keep"

# ── static/index.html ─────────────────────────────────────────────────────────
cat >"$CWD/static/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${APP_NAME}</title>
  <link rel="stylesheet" href="/css/app.css" />
</head>
<body>
  <h1>${APP_NAME}</h1>
</body>
</html>
EOF

# ── package.json ──────────────────────────────────────────────────────────────
cat >"$CWD/package.json" <<EOF
{
  "name": "${SLUG}",
  "scripts": {
    "build": "npx @tailwindcss/cli -i ./assets/css/app.css -o ./public/css/app.css --minify && cp -r static/. public/",
    "watch:css": "npx @tailwindcss/cli -i ./assets/css/app.css -o ./public/css/app.css --watch",
    "watch:static": "npx nodemon --watch static --ext html,js,svg,png,jpg --exec 'cp -r static/. public/'",
    "serve": "npm run build && concurrently \"npm run watch:css\" \"npm run watch:static\" \"python3 -u -m http.server --directory public 0\""
  },
  "devDependencies": {
    "@tailwindcss/cli": "^4.0.0",
    "concurrently": "^9.0.0",
    "nodemon": "^3.0.0",
    "tailwindcss": "^4.0.0"
  }
}
EOF

# ── README.md ─────────────────────────────────────────────────────────────────
cat >"$CWD/README.md" <<EOF
# ${APP_NAME}

${APP_NAME} is a static website.

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
cat >"$CWD/.gitignore" <<EOF
/package-lock.json
/node_modules/
/public/
current
public-*
.DS_Store
EOF

printf '[static/scaffold.sh] Scaffold complete for %s at %s\n' "$SLUG" "$CWD"
