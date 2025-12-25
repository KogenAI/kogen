---
description: List all Figma screens available for comparison and create a todo list
---

List all Figma screenshots available for UI comparison and create a numbered todo list for systematic comparison.

## Path Resolution

**IMPORTANT**: Workspaces use symlinks. Always resolve the actual path:

```bash
# Get the real path to design-system (resolves symlinks)
DESIGN_SYSTEM_PATH=$(readlink -f ./codegen/design-system 2>/dev/null || readlink ./codegen/design-system)
echo "Design system path: $DESIGN_SYSTEM_PATH"
```

For file reading, use the resolved absolute path, not `./codegen/design-system/...`

## Steps

### 1. Read plan context

First, list the plan directory to find available files:

```bash
ls -la ./codegen/plan/
```

Then read the plan files using their full paths:

- Read the overview file to identify the feature name
- Read the screenshot-content-verification file for the screen inventory

### 2. Verify screenshots exist

List files in the design-system features directory (use resolved path):

```bash
# First find the feature directory
ls ./codegen/design-system/features/

# Then list screenshots for the specific feature
ls ./codegen/design-system/features/{feature}/screenshots/
```

### 3. Ensure script directories exist

Create directories if they don't exist:

```bash
mkdir -p ./codegen/design-system/features/{feature}/screenshot-scripts
mkdir -p ./codegen/design-system/features/{feature}/seeds
```

### 4. Create todo list

Parse the screenshot-content-verification.md to extract screens grouped by:

- Organization (Employer) - Mobile
- Organization (Employer) - Desktop
- Job Seeker - Mobile
- Job Seeker - Desktop
- Empty States
- Modals/Forms

Create todo items using TodoWrite:

```
Compare Screen 1: Employer Contracts List (Mobile)
Compare Screen 2: Employer Contracts List (Desktop)
Compare Screen 3: Job Seeker Contracts List (Mobile)
...
```

Each todo should have:

- `content`: "Compare Screen N: {User Type} {Screen Name} ({Viewport})"
- `status`: "pending"
- `activeForm`: "Comparing {User Type} {Screen Name} {Viewport}"

### 5. Check script status

For each screen, check if scripts exist and report status:

```bash
ls ./codegen/design-system/features/{feature}/seeds/screen-*.exs 2>/dev/null
ls ./codegen/design-system/features/{feature}/screenshot-scripts/screen-*.js 2>/dev/null
```

### 6. Output summary

```
## Screens Ready for Comparison

**Feature:** {feature name}
**Total screens:** {count}

### Script Status:
| Screen | Seed | Screenshot Script |
|--------|------|-------------------|
| 1 | ✅/❌ | ✅/❌ |
| 2 | ✅/❌ | ✅/❌ |
...

### Directories:
- Screenshots: ./codegen/design-system/features/{feature}/screenshots/
- Seeds: ./codegen/design-system/features/{feature}/seeds/
- Scripts: ./codegen/design-system/features/{feature}/screenshot-scripts/

Use `/compare-screen 1` to start comparing the first screen.
```

The todo list provides visual progress tracking as screens are compared.
