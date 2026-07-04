# Vite Static Site — Content Add-On (RSS, Tags, Post Listings)

**Opt-in content layer** for the Vite static stack. Adds RSS/Atom feeds, tag taxonomy pages, and paginated post listings on top of the React add-on from `static-vite-scaffold.md`. Apply after the React framework add-on; do NOT bake into the base scaffold.

## Problem

A Vite static site built for blog or content use needs:

- RSS and Atom feeds for subscribers and feed readers
- Tag/category taxonomy pages (`/tags/:tag` listing filtered posts)
- Paginated, date-sorted post listings with related-posts suggestions
- MDX authoring so posts carry JSX components inline

The vanilla Vite scaffold provides none of this. The `static-vite-scaffold.md` React add-on provides the React runtime but no content conventions. This recipe layers the full content stack as one opt-in add-on.

## Solution

1. **MDX wiring** via `@mdx-js/rollup` — posts authored as `.mdx` files with YAML front-matter
2. **Post collection** via `import.meta.glob` + `gray-matter` — one helper module, returns typed array
3. **RSS/Atom feeds** via a postbuild Node script — runs after `vite build`, writes `public/rss.xml` + `public/atom.xml`
4. **Tag pages** via React Router `/tags/:tag` route — derives tag set from front-matter at runtime
5. **Listing components** — pagination, sort-by-date, related-posts composed over the glob set

## Implementation

### 1 — Prerequisites

Apply `static-vite-scaffold.md` (React add-on) first. This recipe layers on top of it. The base scaffold must already be emitted (`index.html`, `vite.config.js`, `package.json`, `src/main.jsx`, `src/style.css`).

### 2 — package.json additions

Merge into the existing `package.json` produced by the React add-on:

```json
{
  "type": "module",
  "scripts": {
    "build": "vite build && node scripts/generate-feeds.js",
    "dev": "vite",
    "serve": "npm run build && python3 -u -m http.server --directory public 0"
  },
  "dependencies": {
    "react": "^19",
    "react-dom": "^19",
    "react-router-dom": "^7",
    "gray-matter": "^4"
  },
  "devDependencies": {
    "vite": "^8",
    "@vitejs/plugin-react": "^6",
    "@mdx-js/rollup": "^3",
    "tailwindcss": "^4",
    "@tailwindcss/vite": "^4"
  }
}
```

Key changes from the React add-on baseline:

- `build` script extended with `&& node scripts/generate-feeds.js` (postbuild, see § RSS/Atom below)
- Added `react-router-dom` for `/tags/:tag` routing
- Added `gray-matter` for front-matter parsing in the post helper
- Added `@mdx-js/rollup` devDependency for MDX compilation

### 3 — vite.config.js

Replace (or merge) the existing `vite.config.js`:

```js
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import mdx from "@mdx-js/rollup";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [{ enforce: "pre", ...mdx() }, react(), tailwindcss()],
  build: {
    outDir: "public", // CRITICAL: must be public/, not dist/
  },
});
```

`enforce: "pre"` on the MDX plugin runs it before React's transform — required for correct JSX handling when MDX and React coexist.

### 4 — Post directory convention

Place posts under `src/posts/`:

```
src/posts/
  hello-world.mdx
  getting-started.mdx
```

Each `.mdx` file MUST have YAML front-matter with at minimum `title` and `date`. Posts missing either field are silently excluded from feeds and listings (see Considerations):

```mdx
---
title: Hello World
date: 2024-01-15
tags: [intro, news]
description: First post on the new blog.
---

# Hello World

Post body goes here. JSX components work inline.
```

### 5 — src/posts.js (post collection helper)

```js
// src/posts.js
// Collects all MDX front-matter into a typed array sorted newest-first.
// Posts missing required fields (title, date) are excluded — boundary validation,
// not a defensive catch-all. See recipe Considerations.

const modules = import.meta.glob("./posts/*.mdx", { eager: true });

function isValidPost(mod) {
  const fm = mod.frontmatter ?? {};
  return (
    typeof fm.title === "string" && fm.title.length > 0 && Boolean(fm.date)
  );
}

export const posts = Object.entries(modules)
  .filter(([, mod]) => isValidPost(mod))
  .map(([path, mod]) => ({
    slug: path.replace("./posts/", "").replace(".mdx", ""),
    title: mod.frontmatter.title,
    date: new Date(mod.frontmatter.date),
    tags: mod.frontmatter.tags ?? [],
    description: mod.frontmatter.description ?? "",
    Component: mod.default,
  }))
  .sort((a, b) => b.date - a.date);

export function getPostBySlug(slug) {
  return posts.find((p) => p.slug === slug) ?? null;
}

export function getPostsByTag(tag) {
  return posts.filter((p) => p.tags.includes(tag));
}

export function getAllTags() {
  const counts = {};
  for (const post of posts) {
    for (const tag of post.tags) {
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
  }
  return Object.entries(counts)
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count);
}
```

### 6 — scripts/generate-feeds.js (postbuild RSS + Atom)

Create `scripts/generate-feeds.js` at the project root. It runs after `vite build` via the extended `build` script. Reads front-matter from `src/posts/*.mdx`, skips invalid posts, writes `public/rss.xml` and `public/atom.xml`.

```js
// scripts/generate-feeds.js
// Postbuild script — run via: node scripts/generate-feeds.js
// Requires the vite build to have completed first (reads src/posts/, writes public/).

import { readdir, readFile, writeFile, mkdir } from "node:fs/promises";
import { join, basename } from "node:path";
import matter from "gray-matter";

const SITE_URL = process.env.SITE_URL ?? "https://SITE_URL_PLACEHOLDER";
const SITE_TITLE = process.env.SITE_TITLE ?? "My Blog";
const SITE_DESCRIPTION = process.env.SITE_DESCRIPTION ?? "";
const POSTS_DIR = join(process.cwd(), "src", "posts");
const OUT_DIR = join(process.cwd(), "public");

function escapeXml(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadPosts() {
  let files;
  try {
    files = await readdir(POSTS_DIR);
  } catch {
    // No posts directory — emit empty feeds, don't fail the build.
    return [];
  }

  const posts = [];
  for (const file of files) {
    if (!file.endsWith(".mdx") && !file.endsWith(".md")) continue;
    const raw = await readFile(join(POSTS_DIR, file), "utf8");
    const { data } = matter(raw);
    // Boundary validation: exclude posts missing required fields.
    if (!data.title || !data.date) continue;
    const date = new Date(data.date);
    if (isNaN(date.getTime())) continue;
    const slug = basename(file).replace(/\.(mdx?$)/, "");
    posts.push({
      slug,
      title: String(data.title),
      date,
      description: data.description ? String(data.description) : "",
      tags: Array.isArray(data.tags) ? data.tags : [],
      url: `${SITE_URL}/posts/${slug}`,
    });
  }
  return posts.sort((a, b) => b.date - a.date);
}

function buildRss(posts) {
  const items = posts
    .map(
      (p) => `
  <item>
    <title>${escapeXml(p.title)}</title>
    <link>${escapeXml(p.url)}</link>
    <guid isPermaLink="true">${escapeXml(p.url)}</guid>
    <pubDate>${p.date.toUTCString()}</pubDate>
    ${p.description ? `<description>${escapeXml(p.description)}</description>` : ""}
    ${p.tags.map((t) => `<category>${escapeXml(t)}</category>`).join("\n    ")}
  </item>`,
    )
    .join("\n");

  return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>${escapeXml(SITE_TITLE)}</title>
    <link>${escapeXml(SITE_URL)}</link>
    <description>${escapeXml(SITE_DESCRIPTION)}</description>
    <atom:link href="${escapeXml(SITE_URL)}/rss.xml" rel="self" type="application/rss+xml"/>
    <lastBuildDate>${new Date().toUTCString()}</lastBuildDate>
    ${items}
  </channel>
</rss>`;
}

function buildAtom(posts) {
  const entries = posts
    .map(
      (p) => `
  <entry>
    <title>${escapeXml(p.title)}</title>
    <link href="${escapeXml(p.url)}"/>
    <id>${escapeXml(p.url)}</id>
    <updated>${p.date.toISOString()}</updated>
    ${p.description ? `<summary>${escapeXml(p.description)}</summary>` : ""}
    ${p.tags.map((t) => `<category term="${escapeXml(t)}"/>`).join("\n    ")}
  </entry>`,
    )
    .join("\n");

  return `<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>${escapeXml(SITE_TITLE)}</title>
  <link href="${escapeXml(SITE_URL)}"/>
  <link href="${escapeXml(SITE_URL)}/atom.xml" rel="self"/>
  <id>${escapeXml(SITE_URL)}/</id>
  <updated>${new Date().toISOString()}</updated>
  ${entries}
</feed>`;
}

const posts = await loadPosts();
await mkdir(OUT_DIR, { recursive: true });
await writeFile(join(OUT_DIR, "rss.xml"), buildRss(posts), "utf8");
await writeFile(join(OUT_DIR, "atom.xml"), buildAtom(posts), "utf8");
console.log(`Feeds written: rss.xml, atom.xml (${posts.length} posts)`);
```

Configure via environment variables at build time:

| Variable           | Default                        | Purpose            |
| ------------------ | ------------------------------ | ------------------ |
| `SITE_URL`         | `https://SITE_URL_PLACEHOLDER` | Canonical site URL |
| `SITE_TITLE`       | `My Blog`                      | Feed title         |
| `SITE_DESCRIPTION` | _(empty)_                      | Feed description   |

### 7 — React Router setup (src/main.jsx)

Replace `src/main.jsx` to add React Router:

```jsx
import "./index.css";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App.jsx";

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </StrictMode>,
);
```

### 8 — App.jsx with routes

```jsx
import { Routes, Route } from "react-router-dom";
import PostList from "./components/PostList.jsx";
import PostPage from "./components/PostPage.jsx";
import TagPage from "./components/TagPage.jsx";

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<PostList />} />
      <Route path="/posts/:slug" element={<PostPage />} />
      <Route path="/tags/:tag" element={<TagPage />} />
    </Routes>
  );
}
```

### 9 — src/components/PostList.jsx (pagination + sort-by-date)

```jsx
import { useState } from "react";
import { Link } from "react-router-dom";
import { posts } from "../posts.js";

const PAGE_SIZE = 10;

export default function PostList() {
  const [page, setPage] = useState(1);
  const totalPages = Math.max(1, Math.ceil(posts.length / PAGE_SIZE));
  const visible = posts.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);

  return (
    <main className="mx-auto max-w-2xl px-4 py-12">
      <h1 className="mb-8 text-3xl font-bold text-gray-900">Posts</h1>
      <ul className="space-y-6">
        {visible.map((post) => (
          <li key={post.slug} className="border-b border-gray-200 pb-6">
            <Link
              to={`/posts/${post.slug}`}
              className="text-xl font-semibold text-blue-700 hover:underline"
            >
              {post.title}
            </Link>
            <p className="mt-1 text-sm text-gray-500">
              {post.date.toLocaleDateString()}
            </p>
            {post.description && (
              <p className="mt-2 text-gray-700">{post.description}</p>
            )}
            <div className="mt-2 flex flex-wrap gap-2">
              {post.tags.map((tag) => (
                <Link
                  key={tag}
                  to={`/tags/${tag}`}
                  className="rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-600 hover:bg-gray-200"
                >
                  {tag}
                </Link>
              ))}
            </div>
          </li>
        ))}
      </ul>

      {totalPages > 1 && (
        <nav className="mt-8 flex justify-center gap-2">
          <button
            onClick={() => setPage((p) => Math.max(1, p - 1))}
            disabled={page === 1}
            className="rounded border px-3 py-1 text-sm disabled:opacity-40"
          >
            Previous
          </button>
          <span className="px-3 py-1 text-sm text-gray-600">
            {page} / {totalPages}
          </span>
          <button
            onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
            disabled={page === totalPages}
            className="rounded border px-3 py-1 text-sm disabled:opacity-40"
          >
            Next
          </button>
        </nav>
      )}
    </main>
  );
}
```

### 10 — src/components/PostPage.jsx (post + related-posts)

```jsx
import { useParams, Link, Navigate } from "react-router-dom";
import { getPostBySlug, getPostsByTag } from "../posts.js";

export default function PostPage() {
  const { slug } = useParams();
  const post = getPostBySlug(slug);

  if (!post) return <Navigate to="/" replace />;

  // Related posts: share at least one tag, exclude current post, cap at 3.
  const related = post.tags
    .flatMap((tag) => getPostsByTag(tag))
    .filter((p) => p.slug !== post.slug)
    .filter((p, i, arr) => arr.findIndex((x) => x.slug === p.slug) === i)
    .slice(0, 3);

  const { Component } = post;

  return (
    <article className="mx-auto max-w-2xl px-4 py-12">
      <Link to="/" className="text-sm text-blue-600 hover:underline">
        ← All posts
      </Link>
      <h1 className="mb-2 mt-6 text-3xl font-bold text-gray-900">
        {post.title}
      </h1>
      <p className="mb-6 text-sm text-gray-500">
        {post.date.toLocaleDateString()}
      </p>
      <div className="prose prose-gray max-w-none">
        <Component />
      </div>

      {related.length > 0 && (
        <section className="mt-12 border-t border-gray-200 pt-8">
          <h2 className="mb-4 text-lg font-semibold text-gray-900">
            Related Posts
          </h2>
          <ul className="space-y-2">
            {related.map((p) => (
              <li key={p.slug}>
                <Link
                  to={`/posts/${p.slug}`}
                  className="text-blue-700 hover:underline"
                >
                  {p.title}
                </Link>
              </li>
            ))}
          </ul>
        </section>
      )}
    </article>
  );
}
```

### 11 — src/components/TagPage.jsx

```jsx
import { useParams, Link } from "react-router-dom";
import { getPostsByTag, getAllTags } from "../posts.js";

export default function TagPage() {
  const { tag } = useParams();
  const tagged = getPostsByTag(tag);
  const allTags = getAllTags();

  return (
    <main className="mx-auto max-w-2xl px-4 py-12">
      <Link to="/" className="text-sm text-blue-600 hover:underline">
        ← All posts
      </Link>
      <h1 className="mb-8 mt-6 text-3xl font-bold text-gray-900">
        Posts tagged <span className="text-blue-700">{tag}</span>
      </h1>

      {tagged.length === 0 ? (
        <p className="text-gray-500">No posts with this tag.</p>
      ) : (
        <ul className="space-y-4">
          {tagged.map((post) => (
            <li key={post.slug}>
              <Link
                to={`/posts/${post.slug}`}
                className="text-lg font-medium text-blue-700 hover:underline"
              >
                {post.title}
              </Link>
              <p className="text-sm text-gray-500">
                {post.date.toLocaleDateString()}
              </p>
            </li>
          ))}
        </ul>
      )}

      <section className="mt-12 border-t border-gray-200 pt-8">
        <h2 className="mb-4 text-lg font-semibold text-gray-900">All Tags</h2>
        <div className="flex flex-wrap gap-2">
          {allTags.map(({ name, count }) => (
            <Link
              key={name}
              to={`/tags/${name}`}
              className={`rounded px-3 py-1 text-sm ${
                name === tag
                  ? "bg-blue-700 text-white"
                  : "bg-gray-100 text-gray-700 hover:bg-gray-200"
              }`}
            >
              {name} ({count})
            </Link>
          ))}
        </div>
      </section>
    </main>
  );
}
```

## Considerations

### Postbuild Node script, not a Vite plugin

RSS and Atom feeds are static XML files — they need no access to the Vite module graph or HMR. A postbuild Node script (`node scripts/generate-feeds.js` after `vite build`) keeps `vite.config.js` clean and makes the feed generation independently testable. A Vite plugin for RSS couples static output to the build graph and adds no benefit — rejected by design (pitch No-go #2).

### Front-matter-missing posts are excluded, not errored

`src/posts.js` and `scripts/generate-feeds.js` both filter out posts that lack required `title` or `date` fields. This is **boundary validation on filesystem-supplied content** — each `.mdx` file is authored externally and may be incomplete during drafting. Filtering by required field at the boundary (No-Defensive-Code carve-out 4) ensures the build succeeds regardless of draft posts. It is NOT a silent catch-all: the filter is explicit (`isValidPost` / `!data.title || !data.date`) and applies only to the required-field contract. A post that is validly structured but has wrong content is NOT filtered.

### React is required

MDX compilation (`@mdx-js/rollup`) produces JSX. React Router powers `/tags/:tag` routing. Both require React. Apply `static-vite-scaffold.md` first to wire React into the vanilla base before applying this recipe.

### Opt-in only

A plain landing page or portfolio site carries none of this. The base scaffold stays lean. Inject this recipe only when the request explicitly involves blog/content authoring, RSS, tag pages, or paginated post listings.

### Environment variables for feed metadata

`SITE_URL`, `SITE_TITLE`, `SITE_DESCRIPTION` configure the feed. Set them in the build environment (CI secrets or `.env` file). When `SITE_URL` is unset the script falls back to the literal `https://SITE_URL_PLACEHOLDER` token — an intentionally obvious, unpatched-looking value (never a plausible fake domain) so an unreplaced deploy is trivially detectable rather than silently wrong. The platform patches this token post-build with the real deploy host; codegen cannot know that host (one-way boundary).

### React Router and static hosting

React Router v6 uses client-side routing. On static hosts that do not support URL rewriting, direct navigation to `/posts/slug` or `/tags/tag` returns a 404. Solutions: configure the host to serve `index.html` for all routes (Netlify `_redirects`, Vercel `vercel.json`), or use hash routing (`createHashRouter`). The recipe uses `BrowserRouter` — document the chosen host's rewrite rule in the project README.

## Example Usage

**Request**: "Build a blog with RSS feed, tag pages, and paginated post listings using Vite and React."

**Planner injects**: `static-vite-scaffold.md` (React add-on baseline) + `static-vite-content.md` (this recipe, opt-in).

**Developer applies**:

1. Run scaffold → vanilla Vite base
2. Merge React add-on (`static-vite-scaffold.md`)
3. Merge this recipe (MDX, post helper, feed script, router, components)
4. Author `.mdx` posts under `src/posts/`
5. Set `SITE_URL`, `SITE_TITLE` in build env
6. Build: `npm run build` → `vite build && node scripts/generate-feeds.js`

Output: `public/` contains built React SPA + `rss.xml` + `atom.xml`.

## Related Recipes

- `static-vite-scaffold.md` — React (and Vue) framework add-on for the vanilla Vite base. **Apply this first** before the content layer.
