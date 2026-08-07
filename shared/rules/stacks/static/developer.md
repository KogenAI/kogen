# Developer — Static Sites

## Build Pipeline

Platform runs build after commit. **Never run yourself.** ❌ `npm run build`, `vite build`.

## Output Dir

`public/` = build output, ALWAYS gitignored. Edit source, never `public/`.

## Deps

After writing `package.json`: `mise exec -- npm install`. Platform needs deps installed before `npm run build`.

### REQUIRED devDeps — Never Drop

The following packages MUST appear in `devDependencies` in every `package.json` you write or modify:

- `tailwindcss` — omitting this causes `Cannot find module 'tailwindcss'` at build time
- `@tailwindcss/vite` — omitting this causes `vite build` / `npm run build` to fail with a missing plugin error

Do NOT remove these when adding or updating other deps. Run `mise exec -- npm install` after EVERY `package.json` write.

## package.json Invariants

- `"build"` and `"serve"` scripts required
- `"serve"` MUST end with `python3 -u -m http.server --directory public 0`

## Tailwind v4 Constraints

- Compiled Tailwind v4 only — **never CDN**, never v3
- No `tailwind.config.js`, no `postcss.config.js` (v4 config-file-free)
- No `@tailwind` directive (use `@import "tailwindcss"`)

## Visual Styling Mandate

Every visible HTML element MUST carry Tailwind utility classes covering AT LEAST:

- **Layout** (flex/grid/block, w-_, h-_, p-_, m-_, gap-\*)
- **Typography** (font-_, text-_, leading-\*)
- **Color** (bg-_, text-_ color variant, border-\*)

Forbidden: shipping `<button>X</button>` or `<div>text</div>` with no class attribute. A page that loads without visible styling — even if it builds — is a failed delivery.

Counter-example (FORBIDDEN):

```jsx
<button onClick={inc}>+</button>
<span>{count}</span>
```

Correct:

```jsx
<button onClick={inc} className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">+</button>
<span className="text-3xl font-bold tabular-nums">{count}</span>
```

CSS file MUST be imported in entry module so Vite emits `<link rel=stylesheet>` in built `index.html`.

## Goal-Driven Verification

Reload page, confirm element/text/behavior present. Reading source is not enough.

## Onboarding — Audit static/ for Stale Files

Check `static/images/` for leftover placeholders (Phoenix `logo.svg`, wrong-brand favicons). Delete + replace.

## Multi-Page Sites (vanilla Vite)

When transitioning from single-page to multi-page (e.g., adding an `/about.html` page), register all HTML entries in `vite.config.js` via `build.rollupOptions.input`. Without this, Vite drops the second (and subsequent) page(s) from the build.

Pattern (ESM-safe):

```js
import { defineConfig } from "vite";
import { fileURLToPath } from "url";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [tailwindcss()],
  build: {
    outDir: "public",
    rollupOptions: {
      input: {
        main: fileURLToPath(new URL("./index.html", import.meta.url)),
        about: fileURLToPath(new URL("./about.html", import.meta.url)),
      },
    },
  },
});
```

Omitting `rollupOptions.input` → Vite defaults to single entry (`index.html`) and silently excludes `about.html` from the build. The second page then 404s at deploy.

Links between pages: use absolute paths (`/about.html`, `/index.html`) — no pretty routes, as the static server has no URL rewrites. (Router-based frameworks can use pretty routes; vanilla Vite serves files by name.)

## Recovering Deleted Images

```bash
git log --all --oneline --follow -- "path/to/image.png"
git show <commit-sha>:path/to/image.png > static/images/image.png
```
