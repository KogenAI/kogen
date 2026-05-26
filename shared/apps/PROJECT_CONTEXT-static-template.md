# {{SITE_NAME}} — Project Context

## Overview

- **What**: [What this site is and its purpose]
- **URL**: https://[domain]
- **Location**: `/home/combobulate/apps/[slug]`
- **Stack**: [Plain HTML + Tailwind v4 | Hugo + Tailwind v4 | Vite + React + Tailwind v4]

## Domain Context Files

Detailed context is split by domain. **Load this index always. Load every row whose trigger matches the user's prompt — files are intentionally small, loading 2-3 is cheap. Cost of a wrong-area read is one row; cost of a missing read is a stale plan. Hard cap: 5 rows — exceeding means the prompt is too broad, ask user to scope.**

| File                     | Domain                           | Load when prompt mentions...           | Update when changing...                      |
| ------------------------ | -------------------------------- | -------------------------------------- | -------------------------------------------- |
| `context/core.md`        | Site content, structure, styling | Pages, components, layout, theme, copy | `pages/`, components, layout, theme, content |
| `context/development.md` | Stack, build, conventions        | Build config, file structure, pitfalls | `package.json`, build config, env vars, CI   |

## File Structure

```
[Filled in after first build based on chosen stack]
```

## Integration Points

- **[Integration]**: [How it connects]
