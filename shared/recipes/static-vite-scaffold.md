# Vite + React Static Site Scaffold

Starter files for Vite + React static apps. Copy into project root and customize.

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
    "react": "^18",
    "react-dom": "^18"
  },
  "devDependencies": {
    "vite": "^5",
    "@vitejs/plugin-react": "^4",
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
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>App Title</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
```

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
