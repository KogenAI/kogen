# Static Stack — Vite (vanilla by default)

Static sites are Vite projects. Vanilla (no framework) by default; add React/Vue/Svelte ONLY when the plan calls for it.

Refs: https://vitejs.dev/guide/

## File Structure

```
index.html              ← Vite entry — MUST be at project root
vite.config.js          ← MUST be at project root
package.json
src/
  main.js               ← app entry (main.jsx for React, main.ts for Vue+TS)
  style.css
public/                 ← build output (gitignored)
.gitignore              ← node_modules/, public/, current, public-*
```

**Modern Vite (v6+) defaults**: Entry point at project root (`index.html`), not `public/`. Build output goes to `dist/` by default, but this stack overrides to `public/` in vite.config.js. When detecting built artifacts: check `public/` (custom outDir), then `dist/` (default).

## Mandatory Files

- `index.html` at project root. Missing → `Could not resolve entry module "index.html"`.
- `vite.config.js` at project root with `build: { outDir: "public" }` and `@tailwindcss/vite` plugin.
- `src/main.js` (or `src/main.jsx` for React) referenced from `index.html` via `<script type="module" src="/src/main.js"></script>`.
- `src/style.css` with `@import "tailwindcss";` imported in `src/main.js`.

Scaffold reference: `static-vite-scaffold.md` (framework add-on reference for adding React/Vue on top of vanilla base).

## Styling

Tailwind v4 mandatory via `@tailwindcss/vite` plugin. Component-local CSS modules allowed for one-off cases ONLY when Tailwind cannot express the pattern. Inline `style={{}}` for truly dynamic values only.

Wiring (vanilla):

1. `package.json` devDependencies: `tailwindcss`, `@tailwindcss/vite`
2. `vite.config.js`: `import tailwindcss from "@tailwindcss/vite"` → `plugins: [tailwindcss()]`
3. `src/style.css`: `@import "tailwindcss";`
4. `src/main.js`: `import "./style.css";` BEFORE any other imports

For React add: `import react from "@vitejs/plugin-react"` → `plugins: [react(), tailwindcss()]`

Omit any of these → built HTML has no stylesheet link → unstyled page → failure.

## Framework Opt-In

Add React/Vue/Svelte ONLY when the plan explicitly calls for it:

- React: add `react`, `react-dom`, `@vitejs/plugin-react`; entry is `src/main.jsx`; import React in JSX files
- Vue: add `vue`, `@vitejs/plugin-vue`; entry is `src/main.js`; components in `src/components/*.vue`
- Multi-page with routing: React Router (`react-router-dom`) — never Hugo for React apps

## Multi-Page (vanilla)

For vanilla multi-page sites, create additional HTML files at project root and add them to `vite.config.js` `build.rollupOptions.input`.

## What You Edit

`index.html` (shell, title, meta), `src/main.js` (entry), `src/style.css`, `vite.config.js`. ❌ `public/`.

## Common Mistakes

- `index.html` inside `src/` — must be at root
- `outDir: "dist"` — platform serves `public/`. Always `outDir: "public"`
- `require()` in `vite.config.js` — ESM only. Use `import`
- No `"type": "module"` in `package.json` — required for ESM imports
- `npm create vite` in non-empty directory hangs on interactive prompt when stdin is `/dev/null`. Fix: write Vite project files directly (heredoc/printf), never `npm create vite`.

## Reactive Initial Values

Every reactive value bound to a user-visible element MUST have a representative non-empty initial value. An empty string / zero / null produces a broken-looking first paint and forces the user to wait for an async fetch before any content renders.

❌ `const temperature = ref(null)` — page shows degree symbol with no digit on first paint
❌ `const items = ref([])` — empty list with no skeleton content
✅ `const temperature = ref(22)` — page shows "22°" immediately; updates when real data arrives
✅ `const items = ref([{ name: "Sample Item", price: 9.99 }])` — seeded list visible on load

This applies to Vue `ref()` / `reactive()` and React `useState()`. Choose sample values that are realistic for the domain (temperature in a plausible range, prices as numbers, not zeros).
