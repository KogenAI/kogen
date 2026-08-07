# {{PROJECT_NAME}} — Project Context

<!-- Fill in this file before it is read as authoritative — an unfilled field
     below is left blank rather than as a bracketed placeholder, so a session
     reading this sees "not yet filled in" rather than a claim. -->

## Overview

- **What**:
- **URL**:
- **Location**: `{{PROJECT_NAME}}`

## Required Platforms

```yaml
required_platforms: []
```

Fill in the platforms this project must run on (unique lowercase OS IDs, e.g. `darwin`, `linux`) — this list must be non-empty before pitches touching platform-sensitive premises can ship.

## Domain Context Files

Detailed context is split by business domain. **Load this index always. Load every row whose trigger matches the user's prompt — files are intentionally small, loading 2-3 is cheap. Cost of a wrong-area read is one row; cost of a missing read is a stale plan. Hard cap: 6 rows — exceeding means the prompt is too broad, ask user to scope.**

Split by distinct business domains — not just core + development. Each domain file should cover a cohesive area of functionality. `development.md` is always present; add as many domain files as the app needs.

<!-- Add one row per business domain, following the shape of the development.md
     row below: File | Domain | Load when prompt mentions... | Update when changing... -->

| File                     | Domain                        | Load when prompt mentions...  | Update when changing...                      |
| ------------------------ | ----------------------------- | ----------------------------- | -------------------------------------------- |
| `context/development.md` | Tech stack, testing, env vars | Testing, CI, config, pitfalls | `config/`, `mix.exs`, env vars, CI workflows |

Examples of domain splits for larger apps:

- A code snippets app: `core.md` (snippets CRUD, search; update when `lib/<app>/snippets/` or schemas change), `auth.md` (GitHub OAuth; update when auth modules change), `screenshots.md` (Chromium, og:image; update when image-generation modules change), `development.md`
- A podcast research app: `core.md` (episodes, claims, verdicts), `scraping.md` (feed parsing, yt-dlp), `ai.md` (transcription, LLM analysis), `development.md`
- A simple CRUD app: `core.md`, `development.md` (two files is fine when there aren't distinct domains)

### Loading examples

- **Adding a feature**: the relevant domain file(s)
- **Fixing tests or CI**: `context/development.md`
- **Cross-cutting change**: multiple domain files

## Always Load

The following files are loaded unconditionally by the shape launcher at Tier 0 (foundational docs every shaping session needs, regardless of pitch topic). Basenames only, one per line — the launcher resolves each to `context/<name>`.

- development.md
<!-- add your app's structural/repo-layout doc basename here when you create one -->

## Module Directory

<!-- Add one row per module: Module | Purpose -->

### Core Modules

| Module | Purpose |
| ------ | ------- |

### Web Layer

| Module | Purpose |
| ------ | ------- |

## Integration Points

<!-- Add one bullet per external integration: **Name**: how it connects -->
