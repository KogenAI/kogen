# Hugo Deep Reference

Conditional load. Refs: https://gohugo.io/documentation/ | /variables/ | /functions/ | /configuration/

## Common Config

```toml
baseURL = 'https://example.com/'
languageCode = 'en-us'
title = 'My Site'
buildDrafts = false
summaryLength = 70

[markup.goldmark.renderer]
unsafe = true   # raw HTML in content

[params]
description = 'Site description'

[pagination]
pagerSize = 10

[taxonomies]
tag = 'tags'
category = 'categories'
```

## Front Matter

Fields: `title`, `date`, `draft`, `description`, `slug`, `url`, `weight`, `layout`, `type`, `tags`, `categories`, `aliases`, `menus`, `params`. Custom under `params:`. Date formats: `2024-03-15T09:30:00Z`, `2024-03-15`, `15 Mar 2024`.

## Template Lookup

Blog post → `layouts/blog/single.html` → `layouts/_default/single.html`. Blog section → `list.html`. Home → `layouts/index.html` → `_default/list.html`.

## Variables

Page: `.Title`, `.Content`, `.Summary`, `.Date`, `.Permalink`, `.RelPermalink`, `.Params`, `.Pages`, `.RegularPages`, `.Site`, `.IsHome`, `.Kind` (`page`/`section`/`home`/`taxonomy`/`term`).

Date format (Go ref `Mon Jan 2 15:04:05 MST 2006`): `{{ .Date.Format "January 2, 2006" }}`.

Site: `.Site.Title`, `.Site.BaseURL`, `.Site.Params`, `.Site.Pages`, `.Site.RegularPages`, `.Site.Menus`, `.Site.Data`.

## Functions

```
{{ range first 5 .Pages }}
{{ $posts := where .Site.RegularPages "Section" "blog" }}
{{ $featured := where .Site.RegularPages "Params.featured" true }}
{{ range .Pages.ByDate.Reverse }}
{{ strings.ToLower .Title }}
{{ urlize .Title }}
{{ default "Fallback" .Params.value }}
{{ humanize "my-slug" }}
{{ now.Year }}
```

## Taxonomies

`[taxonomies] singular = 'plural'`. Templates: `layouts/taxonomy/list.html`, `taxonomy/term.html`.

```
{{ range .GetTerms "tags" }}<a href="{{ .RelPermalink }}">{{ .LinkTitle }}</a>{{ end }}
```

## Pagination

`{{ range .Paginator.Pages }}...{{ end }}`. `[pagination] pagerSize = 10` — auto `/blog/page/2/`.

## Data Files

YAML/TOML/JSON in `data/`. Access: `.Site.Data.filename`.

## Partials — Advanced

Custom data: `{{ partial "card.html" (dict "Title" .Title "URL" .RelPermalink) }}`. Cached: `{{ partialCached "sidebar.html" . }}`.

## Build

```bash
hugo server --buildDrafts   # dev
hugo --minify               # production
hugo new content content/blog/my-post.md
```
