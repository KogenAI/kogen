# Hugo Stack

Multi-page: Hugo + Tailwind v4. Ref: https://gohugo.io/documentation/

## File Structure

```
hugo.toml
content/              ← Markdown
  _index.md           ← homepage
  blog/_index.md, my-post.md
layouts/
  _default/{baseof,home,list,single}.html
  partials/{head,nav,footer}.html
assets/css/app.css    ← Tailwind source
static/               ← copied to public/
public/               ← build output (gitignored)
```

## Build

```
npx tailwindcss -i ./assets/css/app.css -o ./static/css/app.css --minify && hugo
```

## hugo.toml — No Hugo Modules

**NEVER `[module]`, `[module.imports]`, `theme = "..."`** — requires `go.mod` (NOT set up). Use layouts directly.

## What You Edit

- `content/*.md` — front matter + body
- `layouts/**/*.html`
- `hugo.toml` — config, menus, params (NO module/theme)
- `assets/css/app.css`
- `static/js/*.js`, `static/images/`

## Essentials

- `_index.md` = list/section; other `.md` = single
- `{{ .Title }}`, `{{ .Content }}`, `{{ range .Pages }}`, `{{ partial "nav.html" . }}`, `{{ with .Params.description }}`
- Lookup: blog post → `layouts/blog/single.html` → `layouts/_default/single.html`
- ALWAYS `{{ define "main" }}` in single/list/home or content won't render
- `$.` not `.` inside `{{ range }}` for site-level vars

## SVG Logos

Inline in `layouts/partials/logo.html`, call `{{ partial "logo.html" . }}`.

## First Build — Required Files

Write `hugo.toml` FIRST. Without it Hugo builds nothing.

Required: `hugo.toml`, `package.json`, `assets/css/app.css`, `content/_index.md` + 1 more, `layouts/_default/{baseof,home,list,single}.html`, `layouts/partials/{nav,footer}.html`.

Verify: `ls hugo.toml content/_index.md package.json layouts/_default/baseof.html`

## package.json

```json
{
  "scripts": {
    "build": "npx @tailwindcss/cli -i ./assets/css/app.css -o ./static/css/app.css --minify && hugo",
    "watch:css": "npx @tailwindcss/cli -i ./assets/css/app.css -o ./static/css/app.css --watch",
    "serve": "npm run build && python3 -u -m http.server --directory public 0"
  },
  "devDependencies": {
    "@tailwindcss/cli": "^4.0.0",
    "concurrently": "^9.0.0",
    "tailwindcss": "^4.0.0"
  }
}
```

`.gitignore`: `node_modules/`, `public/`, `static/css/app.css`, `resources/_gen/`, `.hugo_build.lock`.

## CSS

Partials render once per item — extract ALL multi-class patterns in `{{ range }}` bodies into CSS classes. `@apply` only accepts Tailwind utilities, not custom CSS. Markdown prose: wrap in `.prose`, style `h2`/`p`/`a`/`ul`/`code` via CSS.

## hugo.toml Example

```toml
baseURL = "https://example.com"
languageCode = "en-us"
title = "My Site"

[params]
description = "Site description"

[menu]
[[menu.main]]
name = "Home"
url = "/"
weight = 1
```

## Visual Styling Mandate

Every visible HTML element in layouts MUST carry Tailwind utility classes covering AT LEAST:

- **Layout** (flex/grid/block, w-_, h-_, p-_, m-_, gap-\*)
- **Typography** (font-_, text-_, leading-\*)
- **Color** (bg-_, text-_ color variant, border-\*)

Forbidden: shipping `<button>X</button>` or `<p>{{ .Title }}</p>` with no `class` attribute. A page that loads without visible styling — even if it builds — is a failed delivery.

Counter-example (FORBIDDEN):

```html
<nav>
  {{ range .Site.Menus.main }}<a href="{{ .URL }}">{{ .Name }}</a>{{ end }}
</nav>
```

Correct:

```html
<nav class="flex gap-6 px-8 py-4 bg-white border-b border-gray-200">
  {{ range .Site.Menus.main }}<a
    href="{{ .URL }}"
    class="text-sm font-medium text-gray-700 hover:text-blue-600"
    >{{ .Name }}</a
  >{{ end }}
</nav>
```

Advanced Hugo (config, vars, fns, taxonomies, pagination) → `stacks/static/hugo-deep.md`.
