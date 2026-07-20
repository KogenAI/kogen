# {{SITE_NAME}} — Project Context

## Overview

- **What**: [What this site is and its purpose]
- **URL**: https://[domain]
- **Location**: `[app root]`
- **Stack**: [Vite (vanilla or framework) + Tailwind v4]

## Required Platforms

```yaml
required_platforms: []
```

Fill in the platforms this project must run on (unique lowercase OS IDs, e.g. `darwin`, `linux`) — this list must be non-empty before pitches touching platform-sensitive premises can ship.

## Domain Context Files

Detailed context is split by domain. **Load this index always. Load every row whose trigger matches the user's prompt — files are intentionally small, loading 2-3 is cheap. Cost of a wrong-area read is one row; cost of a missing read is a stale plan. Hard cap: 5 rows — exceeding means the prompt is too broad, ask user to scope.**

| File                     | Domain                           | Load when prompt mentions...           | Update when changing...                      |
| ------------------------ | -------------------------------- | -------------------------------------- | -------------------------------------------- |
| `context/core.md`        | Site content, structure, styling | Pages, components, layout, theme, copy | `pages/`, components, layout, theme, content |
| `context/development.md` | Stack, build, conventions        | Build config, file structure, pitfalls | `package.json`, build config, env vars, CI   |

## Always Load

The following files are loaded unconditionally by the shape launcher at Tier 0 (foundational docs every shaping session needs, regardless of pitch topic):

- `context/development.md` — stack, build, conventions; always present
- `context/core.md` — site content, structure, styling; always present
- _(add your app's structural/repo-layout doc here when you create one)_

## File Structure

```
[Filled in after first build based on chosen stack]
```

## Integration Points

- **[Integration]**: [How it connects]
