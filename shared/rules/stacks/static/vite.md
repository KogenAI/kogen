# Vite + React Stack

Component-based via Vite + React (default). Use when user requests React/Vue/Svelte.

Refs: https://vitejs.dev/guide/ | https://react.dev/

## File Structure

```
index.html              ← Vite entry — MUST be at project root
vite.config.js          ← MUST be at project root
package.json
src/
  main.jsx              ← app entry
  App.jsx
  components/
  assets/
public/                 ← build output (gitignored)
.gitignore              ← node_modules/, public/, dist/
```

## Mandatory Files

- `index.html` at project root. Missing → `Could not resolve entry module "index.html"`.
- `vite.config.js` at project root with `build: { outDir: "public" }`.
- `src/main.jsx` referenced from `index.html` via `<script type="module" src="/src/main.jsx"></script>`.

Scaffold recipe: `static-vite-scaffold.md`.

## Styling

Tailwind v4 mandatory via `@tailwindcss/vite` plugin. Component-local CSS modules allowed for one-off cases ONLY when Tailwind cannot express the pattern. Inline `style={{}}` for truly dynamic values only.

Wiring:

1. `package.json` devDependencies: `tailwindcss`, `@tailwindcss/vite`
2. `vite.config.js`: `import tailwindcss from "@tailwindcss/vite"` → `plugins: [react(), tailwindcss()]`
3. `src/index.css`: `@import "tailwindcss";` + `@theme` for brand tokens
4. `src/main.jsx`: `import "./index.css";` BEFORE component imports

Omit any of these → built HTML has no stylesheet link → unstyled page → failure.

## Multi-Page

React Router — don't switch to Hugo.

```json
"dependencies": { "react": "^18", "react-dom": "^18", "react-router-dom": "^6" }
```

## What You Edit

`index.html` (shell, title, meta), `src/App.jsx` (root, routing), `src/components/`, `src/assets/`, `vite.config.js`. ❌ `public/`.

## Common Mistakes

- `index.html` inside `src/` — must be at root
- `outDir: "dist"` — platform serves `public/`. Always `outDir: "public"`
- `require()` in `vite.config.js` — ESM only. Use `import`
- No `"type": "module"` — required for ESM imports

## Reactive Initial Values

Every reactive value bound to a user-visible element MUST have a representative non-empty initial value. An empty string / zero / null produces a broken-looking first paint and forces the user to wait for an async fetch before any content renders.

❌ `const temperature = ref(null)` — page shows degree symbol with no digit on first paint
❌ `const items = ref([])` — empty list with no skeleton content
✅ `const temperature = ref(22)` — page shows "22°" immediately; updates when real data arrives
✅ `const items = ref([{ name: "Sample Item", price: 9.99 }])` — seeded list visible on load

This applies to Vue `ref()` / `reactive()` and React `useState()`. Choose sample values that are realistic for the domain (temperature in a plausible range, prices as numbers, not zeros).
