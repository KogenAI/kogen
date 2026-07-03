# Pitch Writing Guide

**Mandatory reading for anyone writing or shaping pitches.**

## What a pitch is

Atomic unit of work. One problem, one solution sketch, one appetite. Written by users directly or extracted from session logs via the `/document` skill. Not a spec — a shaped bet. Builder fills in implementation details; pitch sets boundaries.

## Where to write: always from repo root

**Rule: always write pitches from repo root. Use relative path `codegen/pitches/draft/<slug>.md`. Never absolute. Never doubled.**

```
# Correct — from repo root
codegen/pitches/draft/my-feature.md

# Wrong — absolute path
/Users/alice/Areas/Optimum/codegen/pitches/draft/my-feature.md

# Wrong — doubled path (when cwd is already codegen/)
codegen/codegen/pitches/draft/my-feature.md

# Wrong — missing prefix
draft/my-feature.md
pitches/draft/my-feature.md
```

## Why it matters

The write-surface hook (used by `shape`, `refactor`, and all launchers) strips cwd and matches `^codegen/pitches/`. Absolute paths are denied unless their prefix is exactly cwd — and that varies per machine, per user, per CI environment. Relative paths resolve consistently everywhere. Doubled paths (`codegen/codegen/...`) happen when cwd is already inside the repo — they fail the hook match and are denied.

Launchers like `shape` and `refactor` also auto-edit pitches via `codegen/pitches/draft/<name>.md`. If you used a different path, the launcher can't find your file.

## Slug conventions

- Lowercase, hyphens only: `fix-session-log-ordering.md`
- Descriptive but short (3–5 words)
- No dates in slug — file timestamps track that

## Cross-reference

Output Contract section in `harnesses/claude/tools-header/shape.txt` and `harnesses/pi/tools-header/shape.txt`. The `## Output Contract` section is identical in both; other sections may diverge (minor wording differences at HEAD):

> Produce pitch at `codegen/pitches/draft/<slug>.md` — RELATIVE to project cwd. NEVER absolute. The write-surface hook strips cwd and matches `^codegen/pitches/`; absolutes are denied unless their prefix is exactly cwd. Even when the project IS the codegen repo (root contains `codegen/pitches/`), the path stays `codegen/pitches/...` — not doubled.

## Trigger Keywords

pitch, proposal, async communication, why-focused, rule rationale, launcher review, pitch path resolution, codegen/pitches
