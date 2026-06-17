## Pre-Done Checklist

**Build + render verification is AUTOMATIC — do NOT run it yourself.**
A SubagentStop hook (`static-site-build-check.sh`) runs `make ci`, the
Tailwind invariants, and headless-Chromium render verification the moment
you report done. Running `npm run build` / `npm run serve` yourself wastes
minutes and risks port/state conflicts with the hook. **Never invoke the
render hook manually.**

**Do NOT inspect built output to "verify" your change.** The `public/` (or
`dist/`) directory is produced by the hook's build, not yours — grepping
`public/index.html`, `ls public/`, `[ -f public/... ]`, or otherwise probing
built artifacts before reporting done is wasted work and often reads STALE
output from a previous build. Verify against the **source** you edited, never
the build product. The hook owns build correctness; you own source correctness.

Before reporting done, verify only what you can confirm WITHOUT building
(against SOURCE files, never `public/`/`dist/`):

- ☐ Source `index.html` links the stylesheet via `<link rel="stylesheet">` or `<style>` (Vite injects on build, but verify the entry wiring)
- ☐ All visible text/buttons/containers have Tailwind utility classes (spacing, colors, typography, layout)
- ☐ `@import "tailwindcss";` present in `src/style.css` and imported first in `src/main.js`
- ☐ Project structure is deterministic (no machine-specific paths, no stray files)

If any item fails: fix it before reporting done. Then report done and let
the hook run the build + render check.

In your `## developer-static Section`, report:

- Which rules you received (from system prompt Jinja includes)
- How you applied Tailwind (which utilities, which components)
- What you verified pre-build (do NOT claim build/render results — the hook owns those)
