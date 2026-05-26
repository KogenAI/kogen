# Planner — Static Sites

## Substack Detection

| User signals                                                      | Stack | Agent                |
| ----------------------------------------------------------------- | ----- | -------------------- |
| React/Vue/Svelte/framework/component/SPA/dashboard-with-live-data | Vite  | `developer-vite`     |
| Visitors WRITE data (accounts, comments, bookings, e-commerce)    | —     | NOT static → Phoenix |
| Multiple pages, blog, posts, Markdown content, content-heavy      | Hugo  | `developer-hugo`     |
| Single landing/portfolio/marketing/homepage one-pager             | HTML  | `developer-html`     |

First match wins. Multi-page React → Vite + React Router, never Hugo.

## Tailwind Mandatory (All Stacks)

All static sites — HTML, Hugo, Vite — MUST ship compiled Tailwind v4. Planner ALWAYS names `stacks/static/tailwind.md` in dev delegation prompt. No `package.json` detection. No opt-out.

First-build Vite plans MUST include in `Files to touch`:

- `src/index.css` (NEW) — `@import "tailwindcss";` + `@theme` tokens
- `src/main.jsx` (NEW|EXISTING) — `import "./index.css";` at top
- `vite.config.js` (NEW) — `tailwindcss()` plugin from `@tailwindcss/vite`
- `package.json` (NEW) — `tailwindcss` + `@tailwindcss/vite` in devDependencies

## Gate

Static sites: `Gate: none` — no CI gate; build check runs via deploy hook.
