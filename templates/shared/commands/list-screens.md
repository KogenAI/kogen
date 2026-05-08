---
description: List all Figma screens available for comparison and create a todo list
---

List all Figma screenshots and create numbered todo list for systematic comparison.

## Path Resolution

Workspaces use symlinks — always resolve actual path:

```bash
DESIGN_SYSTEM_PATH=$(readlink -f ./codegen/design-system 2>/dev/null || readlink ./codegen/design-system)
```

## Steps

### 1. Read plan context

```bash
ls -la ./codegen/plan/
```

Read overview file to identify feature name and screenshot-content-verification for screen inventory.

### 2. Verify screenshots exist

```bash
ls ./codegen/design-system/features/
ls ./codegen/design-system/features/{feature}/screenshots/
```

### 3. Ensure script directories exist

```bash
mkdir -p ./codegen/design-system/features/{feature}/screenshot-scripts
mkdir -p ./codegen/design-system/features/{feature}/seeds
```

### 4. Create todo list

Parse screenshot-content-verification.md and create todo items:

```
Compare Screen 1: Employer Contracts List (Mobile)
Compare Screen 2: Employer Contracts List (Desktop)
...
```

Each todo:

- `content`: "Compare Screen N: {User Type} {Screen Name} ({Viewport})"
- `status`: "pending"

### 5. Show seed mapping convention

```
Screenshot                           →  Seed
─────────────────────────────────────────────────────────
message-*.png                        →  message.exs
s5---jobs-*.png                      →  s5-jobs.exs
s7---review-matched-*.png            →  s7-review-matched-candidates.exs
*-empty-*.png                        →  {prefix}-empty.exs
```

Check INDEX.md for full mapping:

```bash
cat ./codegen/design-system/features/{feature}/seeds/INDEX.md
```

### 6. Check script status

```bash
ls ./codegen/design-system/features/{feature}/seeds/*.exs 2>/dev/null
ls ./codegen/design-system/features/{feature}/screenshot-scripts/screen-*.js 2>/dev/null
```

### 7. Output summary

```
## Screens Ready for Comparison

**Feature:** {feature name}
**Total screens:** {count}

### Script Status:
| Screen | Seed | Screenshot Script |
|--------|------|-------------------|
| 1 | ✅/❌ | ✅/❌ |

Use `/compare-screen 1` to start.
```
