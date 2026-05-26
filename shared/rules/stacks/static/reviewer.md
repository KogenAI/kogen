# Reviewer — Static Sites

Stack-specific rules: read `## Stack` in session log, load matching files on demand.

| Stack  | Read                                                                                           |
| ------ | ---------------------------------------------------------------------------------------------- |
| `html` | `stacks/static/html.md`, `stacks/static/tailwind.md`                                           |
| `hugo` | `stacks/static/hugo.md`, `stacks/static/tailwind.md`                                           |
| `vite` | `stacks/static/vite.md` + `stacks/static/tailwind.md` only if `package.json` has `tailwindcss` |

## Static-Specific Checks

- **Selectors**: `#id` or `data-test`. ❌ Tailwind class selectors. ❌ nth-child.
- **Accessibility**: alt text on `<img>`, semantic landmarks, focusable controls.
- **Tailwind v4 hygiene**: no `@tailwind` directive; no `tailwind.config.js`/`postcss.config.js`; `@theme` for tokens; `@utility` not `@layer utilities`.
- **Asset discipline**: `public/` not edited; favicons reference real files; `robots.txt` present.
- **JS**: no inline `onclick` fighting `app.js` handlers.
- **Responsive**: every CSS change applies at every screen size unless explicitly scoped.

## No Test Execution

Read-only. Never run builds.
