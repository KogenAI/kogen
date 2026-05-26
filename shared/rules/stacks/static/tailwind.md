# Tailwind v4 — Static Sites

Shared for all static sites. Ref: https://tailwindcss.com/docs

## Basics

- Compiled Tailwind v4 only — **never CDN**, never v3
- No `tailwind.config.js`, no `postcss.config.js` (v4 config-file-free)
- Entry: `@import "tailwindcss";` at top of `assets/css/app.css`
- Theme: `@theme {}` in `assets/css/app.css`
- Utilities: `@utility name { ... }` (NOT `@layer utilities`)

## `@theme {}`

Only way to add design tokens mapping to utility classes. Regular `:root` does NOT generate utilities.

```css
/* ✅ inside @theme — utilities generated */
@theme {
  --color-brand: oklch(0.62 0.19 250);
  --font-family-display: "Satoshi", sans-serif;
  --spacing-18: 4.5rem;
}

/* ❌ :root variables don't create utilities */
:root {
  --color-brand: ...;
}
```

Namespaces: `--color-*` → `bg-*`/`text-*`/`border-*`; `--font-family-*` → `font-*`; `--spacing-*` → spacing; `--breakpoint-*` → responsive variants; `--radius-*` → `rounded-*`; `--shadow-*` → `shadow-*`.

Full: https://tailwindcss.com/docs/theme

## `@utility` — Name Rules

Lowercase letters/digits/hyphens only. No colons, no `&`.

```css
/* ❌ colon in name */
@utility card-hover:hover { ... }

/* ✅ pseudo-class inside body with & */
@utility card-hover {
  transition: transform 0.2s ease;
  &:hover { transform: translateY(-4px); }
}
```

`@apply` inside `@utility` works but only references Tailwind utilities.

## `@apply` — Gotchas

- Only Tailwind utilities (built-in or `@utility`/`@theme`). Custom CSS classes → fails
- Non-existent utilities throw build errors
- **Never `@apply group`** / `@apply peer` — HTML marker classes, emit no CSS
- Must be inside CSS rule (not top-level)

```css
/* ❌ card-border is custom CSS class */
.goodness-card {
  @apply flex px-12 card-border;
}
/* ✅ */
.goodness-card {
  @apply flex px-12;
}
```

```css
/* ❌ font-playfair not declared */
.heading {
  @apply font-playfair;
}
/* ✅ declare first */
@theme {
  --font-family-playfair: "Playfair Display", Georgia, serif;
}
.heading {
  @apply font-playfair;
}
```

## Responsive by Default

Every CSS change MUST apply at every screen size unless user explicitly scopes.

Mistakes: (1) breakpoint-scoped accidentally — `md:backdrop-blur-md` only at md+; (2) duplicate nav — desktop (`hidden md:flex`) + mobile (`md:hidden`), style one → style both; (3) sticky vs static header both need change.

Breakpoints (mobile-first): `sm:` 40rem, `md:` 48rem, `lg:` 64rem, `xl:` 80rem, `2xl:` 96rem.

## CSS Organization

Extract repeated patterns when pattern repeats 3+. `@layer components` for reusable classes utilities can override.

```css
.section {
  @apply py-20 px-6;
}
.container {
  @apply max-w-5xl mx-auto;
}
```

## Common Build Errors

| Error                                      | Fix                                                                          |
| ------------------------------------------ | ---------------------------------------------------------------------------- |
| `@utility X defines invalid utility name`  | Colon/`&` in name. Move pseudo-classes inside body with `&`                  |
| `Cannot apply unknown utility class X`     | Check name; add to `@theme` first                                            |
| `@apply can only be used within CSS rules` | Wrap in selector                                                             |
| Dynamic class names not generated          | Tailwind scans plain text; `text-${color}-600` won't work — use static names |
| `bg-gradient-to-r` not found               | v4 renamed: `bg-gradient-*` → `bg-linear-*`                                  |
| `font-X` utility not found                 | Declare `--font-family-X` in `@theme` first                                  |
