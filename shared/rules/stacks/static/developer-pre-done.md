## Pre-Done Checklist

Before reporting done, verify:

- ☐ npm run build succeeds without errors
- ☐ Tailwind compiles to CSS file in public/ or dist/
- ☐ Built index.html links stylesheet via <link rel="stylesheet"> or <style> tag
- ☐ All visible text/buttons/containers have Tailwind utility classes (spacing, colors, typography, layout)
- ☐ npm run serve works (test locally if possible)
- ☐ No console errors when served
- ☐ Project builds deterministically (same output on rebuild)

If any checkbox fails: fix it before reporting done.

In your `## developer-static Section`, report:

- Which rules you received (from system prompt Jinja includes)
- How you applied Tailwind (which utilities, which components)
- Build output validation (CSS file size, stylesheet link present)
