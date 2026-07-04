# Reviewer — Static Sites

## Static-Specific Checks

- **Selectors**: `#id` or `data-test`. ❌ Tailwind class selectors. ❌ nth-child.
- **Accessibility**: alt text on `<img>`, semantic landmarks, focusable controls.
- **Tailwind v4 hygiene**: no `@tailwind` directive; no `tailwind.config.js`/`postcss.config.js`; `@theme` for tokens; `@utility` not `@layer utilities`.
- **Asset discipline**: `public/` not edited; favicons reference real files.
- **SEO/AI-discoverability baseline**: every published `public/**/*.html` has a non-empty `<meta name="description">`, all 4 `og:*` tags (`og:title`, `og:description`, `og:type`, `og:image`), a `<link rel="canonical">`, and exactly one valid `<script type="application/ld+json">` block; `public/robots.txt` exists. Every absolute-URL field (canonical, og:image, ld+json `url`) is either the `SITE_URL_PLACEHOLDER` token or a real non-`example.com`-family URL — never an invented fake host or an unreplaced `%...%` template variable.
- **JS**: no inline `onclick` fighting `app.js` handlers.
- **Responsive**: every CSS change applies at every screen size unless explicitly scoped.

## No Test Execution

Read-only. Never run builds.
