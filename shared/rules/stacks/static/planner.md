# Planner — Static Sites

## Stack Decision

All static sites use the **Vite** stack (`developer-static`). Planner decides **vanilla vs framework within Vite**:

| Signal                                                                          | Decision                                     |
| ------------------------------------------------------------------------------- | -------------------------------------------- |
| React/Vue/Svelte/component/SPA/dashboard-with-live-data                         | Vite + framework (name it: React/Vue/Svelte) |
| Visitors WRITE data (accounts, comments, bookings, e-commerce)                  | NOT static → Phoenix                         |
| Everything else (landing page, portfolio, multi-page informational, blog-style) | Vanilla Vite                                 |

Multi-page vanilla → use Vite `build.rollupOptions.input`. Multi-page React → Vite + React Router.

## Tailwind Mandatory (All Static Sites)

All static sites ship compiled Tailwind v4 — no `package.json` detection, no opt-out. `developer-static` bakes `tailwind.md`; plan the `Files to touch` below.

First-build Vite plans MUST include in `Files to touch`:

- `src/style.css` (NEW) — `@import "tailwindcss";`
- `src/main.js` (NEW|EXISTING) — `import "./style.css";` at top
- `vite.config.js` (NEW) — `tailwindcss()` plugin from `@tailwindcss/vite`
- `package.json` (NEW) — `tailwindcss` + `@tailwindcss/vite` in devDependencies

## Gate

Static sites use gate-json block with command "none" — no CI gate; build check runs via deploy hook.

```gate-json
{
  "command": "none",
  "mode": "short",
  "timeout": 0
}
```
