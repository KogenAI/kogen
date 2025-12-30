---
description: Compare all Figma screens with implementation, create reports, then fix all issues
---

Batch workflow that compares all screens in a feature against Figma designs, documents differences, then fixes them all at the end.

**CRITICAL: This command runs FULLY AUTONOMOUSLY for hours. Do NOT stop, do NOT ask questions, do NOT wait for user input. Complete ALL screens in one session.**

## ALWAYS RECHECK FROM SCRATCH

**EVERY TIME this command is executed, you MUST:**

1. **Ignore ALL previous comparison results** - Previous sessions don't matter
2. **Ignore ALL RESOLVED context files** - They are historical records, not current state
3. **Re-run ALL seeds** - Fresh data every time
4. **Take NEW screenshots** - Implementation may have changed
5. **Compare FRESH screenshots to Figma** - Do the actual visual comparison

**NEVER:**

- Say "screens were already compared"
- Say "all work completed in previous session"
- Reference RESOLVED files as proof of current state
- Skip any screen because it was "done before"
- Assume previous fixes are still correct

## CRITICAL RULES

### Path Configuration - WORKSPACE CONTEXT FILES

**🚨 ALWAYS use RELATIVE paths for context files.** Never use absolute paths.

```bash
# ✅ CORRECT - relative paths (works in any workspace)
./codegen/context/PENDING-*.md
./codegen/context/RESOLVED-*.md

# ❌ WRONG - absolute paths (will write to wrong location!)
/Users/.../bemeda_personal/codegen/context/PENDING-*.md
```

**Why this matters:**

- Workspaces are git worktrees with their OWN `./codegen/context/` directory
- Using absolute paths writes to the MAIN project, not the workspace
- The orchestrator checks `./codegen/context/PENDING-*` in the workspace
- Files in the wrong location are INVISIBLE to other agents

**VERIFY your path before writing:**

```bash
pwd  # Should show workspace root, e.g., .../workspaces/figma-recheck
ls ./codegen/context/  # Should show workspace's context files
```

### Port Configuration

**NEVER hardcode ports.** Always use `$PORT` environment variable:

```bash
# ✅ CORRECT - use $PORT
curl http://localhost:$PORT/health
node ./playwright/auth/login.js --port $PORT

# ❌ WRONG - never hardcode
curl http://localhost:4007/health
node ./playwright/auth/login.js --port 4007
```

### Workspace Root

**ALL commands run from workspace root** (current directory), not project root:

- Design system: `./codegen/design-system/features/{feature}/`
- Seeds: `./codegen/design-system/features/{feature}/seeds/`
- Screenshots: `./codegen/design-system/features/{feature}/screenshots/`
- Specs: `./codegen/design-system/features/{feature}/specs/`

### Path Resolution for Symlinks

Workspaces use symlinks. Resolve actual paths for file reading:

```bash
DESIGN_SYSTEM_PATH=$(readlink -f ./codegen/design-system 2>/dev/null || readlink ./codegen/design-system)
```

## COMPLETE AUTONOMOUS WORKFLOW

### Phase 1: Environment Setup

```bash
# 1. Verify port
echo "Using PORT=$PORT"

# 2. Verify server responds
curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT/ || echo "Server not responding - BLOCKED"

# 3. Identify feature
cat ./codegen/plan/overview.md | head -20
# OR use workspace directory name as feature name
```

### Phase 2: Discover Screens (Integrated from /list-screens)

```bash
# 1. List available features
ls ./codegen/design-system/features/

# 2. List screenshots for the feature
ls ./codegen/design-system/features/{feature}/screenshots/

# 3. Read screenshot-content-verification for screen mapping
cat ./codegen/plan/screenshot-content-verification.md
```

Create todo list using TodoWrite with all screens found.

### Phase 3: Reset Database and Run ALL Seeds

**CRITICAL: Reset database BEFORE seeding to ensure consistent state.**

Seeds are grouped by scope, not per-screen. Reset DB then run ALL seed files:

```bash
# 1. RESET DATABASE (required for consistent screenshot state)
mix ecto.reset

# 2. List available seeds
ls ./codegen/design-system/features/{feature}/seeds/*.exs

# 3. Run each seed file
mix run ./codegen/design-system/features/{feature}/seeds/messages.exs
mix run ./codegen/design-system/features/{feature}/seeds/contracts.exs
mix run ./codegen/design-system/features/{feature}/seeds/settings.exs
mix run ./codegen/design-system/features/{feature}/seeds/s5-jobs.exs
mix run ./codegen/design-system/features/{feature}/seeds/s7-review-matched-candidates.exs
```

**CRITICAL**:

- `mix ecto.reset` drops, creates, migrates, and runs default seeds
- All seed users MUST have `locale: :en` for Figma comparison
- Without DB reset, seeds may create duplicate data causing inconsistent states

### Phase 4: Load Project Tailwind Config

**Before ANY comparison**, load the color palette:

```bash
cat ./assets/css/app.css | head -300
```

This gives you exact color variables (e.g., `violet-600`, `gray-50`) for accurate fixes.

### Phase 5: For EACH Screen (Loop Through Todo List)

For screen N in todo list:

#### 5A. Mark todo as in_progress

```
TodoWrite: Mark "Compare Screen N: ..." as in_progress
```

#### 5B. Determine screen details

From screenshot-content-verification.md, extract:

- **User type**: employer or job_seeker
- **Viewport**: Mobile (375x812) or Desktop (1280x720)
- **Route**: The Phoenix route to screenshot
- **Figma file**: The PNG filename

#### 5C. Login (if needed for this user type)

```bash
# For employer screens
node ./playwright/auth/login-employer.js --port $PORT --save-state --email "{seeded_email}"

# For job seeker screens
node ./playwright/auth/login-job-seeker.js --port $PORT --save-state --email "{seeded_email}"
```

#### 5D. Take implementation screenshot

```bash
node ./playwright/screenshots/take-authenticated.js \
  --url {route} \
  --output /tmp/impl-screen-{N}.png \
  --viewport {375x812|1280x720} \
  --port $PORT
```

#### 5E. Visual comparison (MULTIMODAL)

1. **Read Figma screenshot**: `./codegen/design-system/features/{feature}/screenshots/{figma-file}.png`
2. **Read implementation screenshot**: `/tmp/impl-screen-{N}.png`
3. **Use multimodal vision to identify ALL differences**

For each difference found, determine:

- **Element**: What UI element is wrong
- **Figma value**: What Figma shows (colors, spacing, typography)
- **Implementation value**: What implementation shows
- **In-scope**: YES if Tailwind class change can fix it, NO if structural/logic

#### 5F. Extract exact values from specs (RECOMMENDED)

For pixel-perfect accuracy:

```bash
# Get badge styling
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs badges

# Get specific element
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs style "View contract"

# List all text nodes
ocg query-figma-spec ./codegen/design-system/features/{feature}/specs text
```

Returns exact values:

- `textColor`: Hex color (#6561ce)
- `bgColor`: Background hex
- `fontSize`: Font size in px
- `fontWeight`: 400/500/600/700
- `cornerRadius`: Border radius px
- `padding`: {h: horizontal, v: vertical}

#### 5G. Document findings

For each screen, record:

```markdown
## Screen {N}: {Name} ({Viewport})

**Route**: {route}
**User**: {employer|job_seeker}
**Figma**: {filename}

### Differences Found:

| #   | Element      | Figma                       | Implementation  | In-Scope | Exact Fix                                                  |
| --- | ------------ | --------------------------- | --------------- | -------- | ---------------------------------------------------------- |
| 1   | Status badge | text-[#6561ce] bg-[#f2f2fe] | text-orange-500 | YES      | `text-[#6561ce] bg-[#f2f2fe] px-3 py-1 rounded-full`       |
| 2   | Card layout  | border-b dividers           | rounded cards   | YES      | Remove `rounded-xl shadow`, add `border-b border-gray-100` |
| 3   | Modal type   | slideover                   | bottom_sheet    | NO       | Needs JS viewport detection                                |

### Out of Scope (feature-developer):

- Modal should switch to slideover variant on desktop
```

#### 5H. Mark todo complete and CONTINUE IMMEDIATELY

```
TodoWrite: Mark "Compare Screen N: ..." as completed
```

**DO NOT STOP. Immediately proceed to Screen N+1.**

### Phase 6: Batch Fix All In-Scope Issues

After ALL screens compared:

#### 6A. Collect all in-scope issues

Review all documented differences where In-Scope = YES

#### 6B. Group fixes by file

```markdown
## Fixes by File

### lib/bemeda_personal_web/components/contracts/contract_components.ex

- Line 45: `rounded-xl shadow` → `border-b border-gray-100`
- Line 112: Add `text-[#6561ce]` to status badge

### lib/bemeda_personal_web/live/message_live/conversation_list_component.ex

- Line 78: `gap-4` → `gap-2`
```

#### 6C. Apply all fixes

Use Edit tool to make each change.

#### 6D. Re-screenshot affected screens to verify

```bash
# Re-run screenshot for each fixed screen
node ./playwright/screenshots/take-authenticated.js \
  --url {route} \
  --output /tmp/impl-screen-{N}-fixed.png \
  --viewport {viewport} \
  --port $PORT
```

### Phase 7: Final Report

Create report file based on outcome:

- **All styling fixed, no out-of-scope items**: `./codegen/context/RESOLVED-figma-comparison-{timestamp}.md`
- **Has out-of-scope items for other roles**: `./codegen/context/PENDING-figma-comparison-{timestamp}.md`

```markdown
# Figma Comparison Complete

**Date**: {timestamp}
**Feature**: {feature}
**Screens Compared**: {count}

## Fixes Applied (ui-specialist scope)

### File: contract_components.ex

- Line 45: `rounded-xl shadow` → `border-b border-gray-100`
- Line 112: `text-orange-500` → `text-[#6561ce] bg-[#f2f2fe]`

### File: conversation_list_component.ex

- Line 78: `gap-4` → `gap-2`

## Out of Scope (needs other roles)

### feature-developer

1. Desktop slideover: Modal should switch to slideover variant on desktop
   - File: offer_details_form_component.ex
   - Needs: JS hook for viewport detection

### test-engineer

1. [any test issues found]

## Key Learnings

- Figma list items use divider lines (`border-b`), not individual card boxes
- Status badges use exact hex colors from specs, not Tailwind approximations
- Contact buttons are outline-only without filled background
```

### Phase 7B: Create PENDING Reports for Structural Issues

**CRITICAL: For each structural/out-of-scope issue, create a separate PENDING report so it gets handled in the next iteration.**

For each out-of-scope issue found:

```bash
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
```

**Create individual PENDING files for feature-developer:**

```markdown
# File: ./codegen/context/PENDING-structural-{issue-slug}-{timestamp}.md

# Structural Issue: {Issue Title}

**Source**: ui-specialist (figma comparison)
**Target**: feature-developer
**Priority**: {HIGH|MEDIUM|LOW}
**Figma Screen**: {screenshot filename}

## Problem

{Detailed description of what Figma shows vs what implementation shows}

## Figma Design

- **Screen**: {Screen name and number}
- **Elements shown**:
  - {List all UI elements Figma displays}
  - {Include layout, components, data}

## Current Implementation

- **Route tested**: {route}
- **What it shows**: {description}
- **Gap**: {what's missing or different}

## Required Changes

1. {Specific change needed}
2. {Another change if applicable}

## Acceptance Criteria

- [ ] {Criterion 1 - what must be true when done}
- [ ] {Criterion 2}
- [ ] Screen matches Figma design

## Reference

- Figma screenshot: `./codegen/design-system/features/{feature}/screenshots/{filename}`
- Implementation screenshot: `/tmp/impl-screen-{N}.png`
```

**Example PENDING files to create:**

1. **Missing page/route**:

   ```
   ./codegen/context/PENDING-structural-job-alert-page-20251230-071500.md
   ```

2. **Wrong component structure**:

   ```
   ./codegen/context/PENDING-structural-candidate-profile-view-20251230-071500.md
   ```

3. **Missing feature**:
   ```
   ./codegen/context/PENDING-structural-empty-state-seeds-20251230-071500.md
   ```

**WHY**: These PENDING files ensure structural issues are:

- Not forgotten after the UI comparison session ends
- Picked up by the orchestrator in the next iteration
- Properly delegated to feature-developer with full context

### Phase 8: Final Summary for User

Display ALL screenshots side-by-side:

```markdown
## Screen 1: {Name} ({Viewport})

### Figma:

[Read and display figma screenshot]

### Implementation (After Fixes):

[Read and display /tmp/impl-screen-1-fixed.png]

### Status: ✅ MATCH | ⚠️ OUT OF SCOPE ITEMS | ❌ NEEDS MORE WORK

---

## Screen 2: {Name} ({Viewport})

...
(repeat for all screens)
```

## Error Handling

**Script fails:** Try once more, if still fails log error and continue to next screen.
**Seed fails:** Log error and continue.
**Server not responding:** Report BLOCKED immediately with full error.
**Login fails:** Check seed created user, retry once, then log error and continue.

**DO NOT STOP for errors. Log and continue to next screen.**

## In-Scope vs Out-of-Scope

**IN-SCOPE (fix immediately):**

- Tailwind class changes (colors, spacing, typography, borders)
- CSS styling adjustments
- Layout tweaks within existing structure
- Adding/removing wrapper divs for layout

**OUT-OF-SCOPE (document for other roles):**

- Component structure changes (modal → slideover)
- JavaScript hooks or LiveView logic
- Data/backend issues
- Missing routes or pages
- Test failures
- Form handling or validation

## Specification Requirements

**CRITICAL**: When documenting differences, provide EXACT Tailwind classes.

### ❌ BAD (Too Vague):

```
- Status color is wrong
- Needs more padding
- Font should be lighter
```

### ✅ GOOD (Exact Specifications):

```markdown
| Element      | Figma               | Implementation | Exact Fix                                                        |
| ------------ | ------------------- | -------------- | ---------------------------------------------------------------- |
| Status badge | Purple pill #6561ce | Orange text    | `text-[#6561ce] bg-[#f2f2fe] px-3 py-1 rounded-full font-normal` |
```

## Screenshot Preservation

- Implementation screenshots: `/tmp/impl-screen-{N}.png`
- Fixed screenshots: `/tmp/impl-screen-{N}-fixed.png`
- NEVER delete screenshots during session
- User reviews them at the end
