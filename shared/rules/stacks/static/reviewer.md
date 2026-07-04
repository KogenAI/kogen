# Reviewer — Static Sites

## Static-Specific Checks

- **Selectors**: `#id` or `data-test`. ❌ Tailwind class selectors. ❌ nth-child.
- **Accessibility**: alt text on `<img>`, semantic landmarks, focusable controls.
- **Tailwind v4 hygiene**: no `@tailwind` directive; no `tailwind.config.js`/`postcss.config.js`; `@theme` for tokens; `@utility` not `@layer utilities`.
- **Asset discipline**: `public/` not edited; favicons reference real files; `robots.txt` present.
- **JS**: no inline `onclick` fighting `app.js` handlers.
- **Responsive**: every CSS change applies at every screen size unless explicitly scoped.

## No Test Execution

Read-only. Never run builds.
