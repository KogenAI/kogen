# {{PROJECT_NAME}} — Project Context

## Overview

- **What**: [What this app does and its purpose]
- **URL**: https://[domain]
- **Location**: `/home/combobulate/apps/[slug]`

## Domain Context Files

Detailed context is split by business domain. **Load this index always. Load every row whose trigger matches the user's prompt — files are intentionally small, loading 2-3 is cheap. Cost of a wrong-area read is one row; cost of a missing read is a stale plan. Hard cap: 6 rows — exceeding means the prompt is too broad, ask user to scope.**

Split by distinct business domains — not just core + development. Each domain file should cover a cohesive area of functionality. `development.md` is always present; add as many domain files as the app needs.

| File                     | Domain                        | Load when prompt mentions...   | Update when changing...                                 |
| ------------------------ | ----------------------------- | ------------------------------ | ------------------------------------------------------- |
| `context/[domain].md`    | [Business domain description] | [Prompt keywords or path glob] | [Module paths or file globs that belong to this domain] |
| `context/development.md` | Tech stack, testing, env vars | Testing, CI, config, pitfalls  | `config/`, `mix.exs`, env vars, CI workflows            |

Examples of domain splits for larger apps:

- A code snippets app: `core.md` (snippets CRUD, search; update when `lib/<app>/snippets/` or schemas change), `auth.md` (GitHub OAuth; update when auth modules change), `screenshots.md` (Chromium, og:image; update when image-generation modules change), `development.md`
- A podcast research app: `core.md` (episodes, claims, verdicts), `scraping.md` (feed parsing, yt-dlp), `ai.md` (transcription, LLM analysis), `development.md`
- A simple CRUD app: `core.md`, `development.md` (two files is fine when there aren't distinct domains)

### Loading examples

- **Adding a feature**: the relevant domain file(s)
- **Fixing tests or CI**: `context/development.md`
- **Cross-cutting change**: multiple domain files

## Module Directory

### Core Modules

| Module        | Purpose             |
| ------------- | ------------------- |
| [Module Name] | [Brief description] |

### Web Layer

| Module        | Purpose             |
| ------------- | ------------------- |
| [Module Name] | [Brief description] |

## Integration Points

- **[Integration]**: [How it connects]
