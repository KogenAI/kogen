# Plain HTML Stack

Single-page sites with compiled Tailwind v4. No Hugo, no framework.

## File Structure

```
assets/css/app.css    ← Tailwind source
static/               ← copied as-is to public/
  index.html
  images/
  js/
public/               ← build output (gitignored)
```

## Build Pipeline

```
npx @tailwindcss/cli -i ./assets/css/app.css -o ./public/css/app.css --minify && cp -r static/. public/
```

## What You Edit

`static/index.html`, `assets/css/app.css`, `static/js/*.js`, `static/images/`.

## Inline JS Belongs in app.js

Never `<script>` blocks in `index.html` when `app.js` exists.

## Images Without Explicit Width

`class="w-full"` for full-bleed — else renders natural width.

## Base Template Recipe

`static-html-base-template.md`.

## package.json Scripts

```json
{
  "scripts": {
    "build": "npx @tailwindcss/cli -i ./assets/css/app.css -o ./public/css/app.css --minify && cp -r static/. public/",
    "watch:css": "npx @tailwindcss/cli -i ./assets/css/app.css -o ./public/css/app.css --watch",
    "watch:static": "npx nodemon --watch static --ext html,js,svg,png,jpg --exec 'cp -r static/. public/'",
    "serve": "npm run build && python3 -u -m http.server --directory public 0"
  },
  "devDependencies": {
    "@tailwindcss/cli": "^4.0.0",
    "concurrently": "^9.0.0",
    "nodemon": "^3.0.0",
    "tailwindcss": "^4.0.0"
  }
}
```

## Tailwind v4 Setup

```css
@import "tailwindcss";

@theme {
  --color-brand: #fd4f00;
  --font-family-montserrat: "Montserrat", ui-sans-serif, system-ui, sans-serif;
}
```

`:host, html {}` to avoid preflight specificity for font-size base.

## Visual Styling Mandate

Every visible HTML element MUST carry Tailwind utility classes covering AT LEAST:

- **Layout** (flex/grid/block, w-_, h-_, p-_, m-_, gap-\*)
- **Typography** (font-_, text-_, leading-\*)
- **Color** (bg-_, text-_ color variant, border-\*)

Forbidden: shipping `<button>X</button>` or `<p>text</p>` with no `class` attribute. A page that loads without visible styling — even if it builds — is a failed delivery.

Counter-example (FORBIDDEN):

```html
<button onclick="inc()">+</button> <span id="count">0</span>
```

Correct:

```html
<button
  onclick="inc()"
  class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
>
  +
</button>
<span id="count" class="text-3xl font-bold tabular-nums">0</span>
```

## Cross-Refs

Responsive + Tailwind → `tailwind.md`. Favicons/robots/og → `assets.md`. JS → `js.md`.
