# Add a Framework to the Vite Static Site

**Add-a-framework reference**: Use this when adding React or Vue on top of the vanilla Vite base scaffold. The vanilla scaffold is emitted by `shared/scaffold/static/scaffold.sh`; this recipe documents the framework additions only. Apply with deviations — the vanilla base already provides `index.html`, `vite.config.js`, `package.json`, `src/style.css`.

Starter files for Vite + React static apps. Merge/override into the vanilla base and customize.

## package.json

```json
{
  "type": "module",
  "scripts": {
    "build": "vite build",
    "dev": "vite",
    "serve": "npm run build && python3 -u -m http.server --directory public 0"
  },
  "dependencies": {
    "react": "^19",
    "react-dom": "^19"
  },
  "devDependencies": {
    "vite": "^8",
    "@vitejs/plugin-react": "^6",
    "tailwindcss": "^4",
    "@tailwindcss/vite": "^4"
  }
}
```

## vite.config.js (project root, REQUIRED)

```js
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    outDir: "public", // CRITICAL: must be public/, not dist/
  },
});
```

MUST use `import` (ESM), never `require()` — `@vitejs/plugin-react` is ESM-only. Requires `"type": "module"` in `package.json`.

## index.html (project root)

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>App Title</title>
    <meta name="description" content="App Title is a website." />
    <meta property="og:title" content="App Title" />
    <meta property="og:description" content="App Title is a website." />
    <meta property="og:type" content="website" />
    <meta
      property="og:image"
      content="https://SITE_URL_PLACEHOLDER/og-image.png"
    />
    <link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" />
    <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        "name": "App Title",
        "url": "https://SITE_URL_PLACEHOLDER/"
      }
    </script>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
```

SEO/AI-discoverability baseline (description, `og:*` tags, canonical, ld+json) carries over from the vanilla base — the `SITE_URL_PLACEHOLDER` token is planted by the scaffold and patched post-build by the platform (codegen cannot know the deploy host). See `shared/rules/stacks/static/assets.md` for the full convention.

## src/index.css

```css
@import "tailwindcss";

@theme {
  /* brand tokens — customize as needed */
}
```

## src/main.jsx

```jsx
import "./index.css";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App.jsx";

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
```

`import "./index.css"` MUST be the first import so Vite emits `<link rel=stylesheet>` in built `index.html`.

## .gitignore

```
node_modules/
public/
dist/
```
